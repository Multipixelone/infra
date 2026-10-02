#!/usr/bin/env bash
# Runs independently of OpenClaw, Prometheus and Alertmanager. Credentials
# arrive only through the optional systemd EnvironmentFile.
THRESHOLD=3
STATE="${STATE_DIRECTORY:-/tmp/openclaw-deadman}"
mkdir -p "$STATE/pending"

read_count() {
	local value=0
	if [[ -f "$1" ]]; then
		read -r value <"$1" || true
	fi
	[[ "$value" =~ ^[0-9]+$ ]] || value=0
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

observe() {
	local count_file="$1" alerted="$2" healthy="$3" failure="$4" recovery="$5" count
	count=$(read_count "$count_file")
	if [[ "$healthy" == true ]]; then
		if [[ -f "$alerted" ]]; then
			queue_notice "$recovery"
			rm -f "$alerted"
		fi
		count=0
	else
		count=$((count + 1))
		if [[ "$count" -ge "$THRESHOLD" && ! -f "$alerted" ]]; then
			queue_notice "$failure"
			touch "$alerted"
		fi
	fi
	printf '%s\n' "$count" >"$count_file.tmp"
	mv "$count_file.tmp" "$count_file"
}

pipeline_check() {
	observe "$STATE/$1.count" "$STATE/$1.alerted" "$2" \
		"🚨 $3 on link. Grafana alerts will NOT reach Telegram until fixed" \
		"✅ $4 on link ($(date '+%H:%M'))."
}

# Keep the gateway's existing state names, health predicate and messages.
count=$(read_count "$STATE/fail_count")
healthy=false
if resp=$(curl -fsS -m 5 'http://localhost:18789/health' 2>/dev/null) &&
	printf '%s' "$resp" | grep -q '"ok":true'; then
	healthy=true
fi
observe "$STATE/fail_count" "$STATE/alerted" "$healthy" \
	"🚨 openclaw-gateway DOWN on link — health check failed $((count + 1))× (≥${THRESHOLD}/2min). Telegram delivery is offline." \
	"✅ openclaw-gateway recovered on link ($(date '+%H:%M'))."

# This is a user timer checking SYSTEM units. A skipped ConditionPathExists
# leaves a unit inactive, and therefore fails this check too.
for unit in alertmanager prometheus; do
	healthy=false
	if systemctl --system is-active --quiet "$unit.service"; then healthy=true; fi
	pipeline_check "$unit-unit" "$healthy" "$unit.service is not active (including skipped startup conditions)" "$unit.service is active again"
done

healthy=false
if curl -fsS -m 5 'http://127.0.0.1:9093/-/healthy' >/dev/null 2>&1; then healthy=true; fi
pipeline_check alertmanager-health "$healthy" 'Alertmanager /-/healthy is unreachable or unhealthy' 'Alertmanager /-/healthy responds successfully again'

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
pipeline_check prometheus-discovery "$healthy" "$discovery_failure" 'Prometheus reports a discovered Alertmanager again'

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
pipeline_check telegram-failures "$healthy" "$telegram_failure" 'Alertmanager Telegram failure metrics are readable and no longer increasing (this alone does not confirm delivery)'

# Check everything before attempting delivery. Preserve FIFO pending notices
# across timer runs, outages and recovery; acknowledge only API-confirmed sends.
shopt -s nullglob
sent=0
for notice in "$STATE"/pending/*.txt; do
	if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || ! "${TELEGRAM_CHAT_ID:-}" =~ ^-?[1-9][0-9]*$ ]]; then
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
		if [[ "$sent" -ge 10 ]]; then break; fi
	else
		echo 'Dead-man Telegram delivery failed; pending notices retained' >&2
		break
	fi
done
