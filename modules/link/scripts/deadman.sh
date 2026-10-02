#!/usr/bin/env bash
# Runs independently of OpenClaw, Prometheus and Alertmanager. Credentials
# arrive only through the optional systemd EnvironmentFile.
THRESHOLD=3
STATE="${STATE_DIRECTORY:-/tmp/openclaw-deadman}"
mkdir -p "$STATE"
# One-time retirement of the old gateway/per-check incident queues. Current
# pipeline failures are observed afresh; never replay obsolete gateway pages.
if [[ ! -f "$STATE/pipeline-v2" ]]; then
  rm -rf "$STATE/pending"
  rm -f "$STATE/fail_count" "$STATE/alerted" "$STATE"/*.count "$STATE"/*.alerted "$STATE/telegram-failures.previous" "$STATE/sequence"
  touch "$STATE/pipeline-v2"
fi
mkdir -p "$STATE/pending"
broken=()
threshold_reached=false
hint='On link, inspect systemctl status alertmanager.service prometheus.service, the loopback health/discovery APIs, and journalctl -u alertmanager -u prometheus -n 50. Flat failure counters alone do not confirm delivery.'

read_count() {
  local value=0
  if [[ -f $1 ]]; then
    read -r value <"$1" || true
  fi
  [[ $value =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}

queue_notice() {
  local sequence
  sequence=$(($(read_count "$STATE/sequence") + 1))
  printf '%s\n' "$sequence" >"$STATE/sequence.tmp"
  mv "$STATE/sequence.tmp" "$STATE/sequence"
  printf '%s\n' "$1" >"$STATE/pending/$(printf '%020d' "$sequence").tmp"
  mv "$STATE/pending/$(printf '%020d' "$sequence").tmp" "$STATE/pending/$(printf '%020d' "$sequence").txt"
  printf '%s\n' "$1" >&2
}

pipeline_check() {
  local count_file="$STATE/$1.count" count
  count=$(read_count "$count_file")
  if [[ $2 == true ]]; then
    count=0
  else
    count=$((count + 1))
    broken+=("$3")
    if [[ $count -ge $THRESHOLD ]]; then threshold_reached=true; fi
  fi
  printf '%s\n' "$count" >"$count_file.tmp"
  mv "$count_file.tmp" "$count_file"
}

# This is a user timer checking SYSTEM units. A skipped ConditionPathExists
# leaves a unit inactive, and therefore fails this check too.
for unit in alertmanager prometheus; do
  healthy=false
  if systemctl --system is-active --quiet "$unit.service"; then healthy=true; fi
  pipeline_check "$unit-unit" "$healthy" "$unit.service is not active (including skipped startup conditions)"
done

healthy=false
if curl -fsS -m 5 'http://127.0.0.1:9093/-/healthy' >/dev/null 2>&1; then healthy=true; fi
pipeline_check alertmanager-health "$healthy" 'Alertmanager /-/healthy is unreachable or unhealthy'

healthy=false
discovery_failure='Prometheus loopback Alertmanager discovery API is unreachable'
if resp=$(curl -fsS -m 5 --get 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=prometheus_notifications_alertmanagers_discovered' 2>/dev/null); then
  discovery_failure='Prometheus Alertmanager discovery metric is missing or invalid'
  if printf '%s' "$resp" | jq -e '
      .status == "success" and .data.resultType == "vector" and
      (.data.result | length > 0) and
      all(.data.result[]; .value[1] | test("^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$"))
    ' >/dev/null 2>&1; then
    discovery_failure='Prometheus reports zero discovered Alertmanagers'
    if printf '%s' "$resp" | jq -e 'any(.data.result[]; (.value[1] | tonumber) >= 1)' >/dev/null 2>&1; then
      healthy=true
    fi
  fi
fi
pipeline_check prometheus-discovery "$healthy" "$discovery_failure"

# Sum all Telegram failure reasons. Missing/malformed metrics are failures;
# the first valid sample and counter resets establish a fresh baseline.
healthy=false
telegram_failure='Alertmanager Telegram failure metrics cannot be read (unreachable endpoint, missing or malformed series)'
if metrics=$(curl -fsS -m 5 'http://127.0.0.1:9093/metrics' 2>/dev/null) &&
  total=$(printf '%s\n' "$metrics" | awk '
    /^alertmanager_notifications_failed_total\{/ {
      if ($1 !~ /[,{]integration="telegram"[,}]/) next
      if ($2 !~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) invalid=1
      total += $2; found=1
    }
    END { if (!found || invalid) exit 1; printf "%.17g", total }
  '); then
  healthy=true
  if [[ -f "$STATE/telegram-failures.previous" ]]; then
    previous=$(cat "$STATE/telegram-failures.previous")
    if awk -v current="$total" -v previous="$previous" 'BEGIN { exit !(current > previous) }'; then
      healthy=false
      telegram_failure="Alertmanager Telegram notification failures increased from $previous to $total since the previous successful metrics check"
    fi
  fi
  printf '%s\n' "$total" >"$STATE/telegram-failures.previous.tmp"
  mv "$STATE/telegram-failures.previous.tmp" "$STATE/telegram-failures.previous"
fi
pipeline_check telegram-failures "$healthy" "$telegram_failure"

# Keep one incident open across overlapping and changing pipeline failures.
# Resolve only when ALL checks are healthy, including checks still debouncing.
now=$(date +%s)
if [[ ${#broken[@]} -gt 0 ]]; then
  printf 'Pipeline check failed: %s\n' "${broken[@]}" >&2
  if [[ $threshold_reached == true && ! -f "$STATE/pipeline.started" ]]; then
    printf '%s\n' "$now" >"$STATE/pipeline.started"
    summary=$(printf '%s; ' "${broken[@]}")
    queue_notice "$(render_alert firing AlertingPipelineDown 'alerting pipeline on link' "$now" '' "${summary%; }" "$hint")"
  fi
elif [[ -f "$STATE/pipeline.started" ]]; then
  started=$(read_count "$STATE/pipeline.started")
  queue_notice "$(render_alert resolved AlertingPipelineDown 'alerting pipeline on link' "$started" "$now" 'All independent alerting pipeline checks are healthy again' "$hint")"
  rm -f "$STATE/pipeline.started"
fi

# Check everything before attempting delivery. Preserve FIFO pending notices
# across timer runs, outages and recovery; acknowledge only API-confirmed sends.
shopt -s nullglob
sent=0
for notice in "$STATE"/pending/*.txt; do
  if [[ -z ${TELEGRAM_BOT_TOKEN:-} || ! ${TELEGRAM_CHAT_ID:-} =~ ^-?[1-9][0-9]*$ ]]; then
    echo 'Dead-man Telegram credentials unavailable; pending notices retained' >&2
    break
  fi
  if response=$(curl -fsS -m 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$(cat "$notice")" 2>/dev/null) &&
    printf '%s' "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    rm -f "$notice"
    sent=$((sent + 1))
    # Bound each timer run even if a long outage accumulated many transitions.
    if [[ $sent -ge 10 ]]; then break; fi
  else
    echo 'Dead-man Telegram delivery failed; pending notices retained' >&2
    break
  fi
done
