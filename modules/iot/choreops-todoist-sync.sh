#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
HA_URL="http://localhost:8123"
TD_API="https://api.todoist.com/api/v1"
PROJECT_NAME="Chores"
SECTION_NAME="🏠 Household"
LABEL="choreops"
PERSON="Finn"
PREFIX="sensor.finn_choreops_chore_status_"
HORIZON_DAYS=3
COMPLETED_LOOKBACK_DAYS=7
STATE_DIR="${STATE_DIRECTORY:-/var/lib/choreops-todoist-sync}"
STATE_FILE="$STATE_DIR/state.json"
DRY="${CHOREOPS_SYNC_DRY_RUN:-0}"

export TZ="America/New_York"

ha_token="$(<"${HA_TOKEN_FILE:?HA_TOKEN_FILE not set}")"
td_token="$(<"${TODOIST_TOKEN_FILE:?TODOIST_TOKEN_FILE not set}")"

log() { printf '%s\n' "choreops-sync: $*" >&2; }

# ── HTTP helpers (api() mirrors modules/iot/todoist.nix) ────────────────────
tapi() {
  local stage="$1"
  shift
  local out status body
  out="$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $td_token" "$@")"
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    log "todoist $stage http $status: $body"
    return 22
  fi
  printf '%s' "$body"
}

hget() {
  curl -sS -H "Authorization: Bearer $ha_token" "$HA_URL$1"
}

hpost() {
  local path="$1" json="$2"
  local out status body
  out="$(curl -sS -w $'\n%{http_code}' \
    -H "Authorization: Bearer $ha_token" -H 'Content-Type: application/json' \
    -d "$json" "$HA_URL$path")"
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    log "ha POST $path http $status: $body"
    return 22
  fi
}

# Resolve a project name → id (paginated; handles array or {results,next_cursor}).
resolve_project() {
  local target="$1" cursor="" resp id
  while :; do
    if [ -n "$cursor" ]; then
      resp="$(tapi list-projects "$TD_API/projects?cursor=$cursor")"
    else
      resp="$(tapi list-projects "$TD_API/projects")"
    fi
    id="$(printf '%s' "$resp" | jq -r --arg n "$target" \
      '(if type=="array" then . else .results end)|.[]|select(.name==$n)|.id')"
    if [ -n "$id" ] && [ "$id" != "null" ]; then
      printf '%s' "$id"
      return 0
    fi
    cursor="$(printf '%s' "$resp" | jq -r 'if type=="array" then "" else (.next_cursor // "") end')"
    if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then break; fi
  done
  log "project not found: $target"
  return 22
}

ensure_section() {
  local pid="$1" resp sid payload
  resp="$(tapi list-sections "$TD_API/sections?project_id=$pid")"
  sid="$(printf '%s' "$resp" | jq -r --arg n "$SECTION_NAME" \
    '(if type=="array" then . else .results end)|map(select(.name==$n))|.[0].id // ""')"
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    printf '%s' "$sid"
    return 0
  fi
  if [ "$DRY" = "1" ]; then
    log "[dry] would create section: $SECTION_NAME"
    printf ''
    return 0
  fi
  payload="$(jq -nc --arg n "$SECTION_NAME" --arg p "$pid" '{name:$n,project_id:$p}')"
  resp="$(tapi create-section -X POST -H 'Content-Type: application/json' -d "$payload" "$TD_API/sections")"
  printf '%s' "$resp" | jq -r '.id'
}

ensure_label() {
  local resp have payload
  resp="$(tapi list-labels "$TD_API/labels")"
  have="$(printf '%s' "$resp" | jq -r --arg n "$LABEL" \
    '(if type=="array" then . else .results end)|map(select(.name==$n))|.[0].id // ""')"
  if [ -n "$have" ] && [ "$have" != "null" ]; then return 0; fi
  if [ "$DRY" = "1" ]; then
    log "[dry] would create label: $LABEL"
    return 0
  fi
  payload="$(jq -nc --arg n "$LABEL" '{name:$n}')"
  tapi create-label -X POST -H 'Content-Type: application/json' -d "$payload" "$TD_API/labels" >/dev/null
}

# ── Resolve Todoist containers ──────────────────────────────────────────────
mkdir -p "$STATE_DIR"
pid="$(resolve_project "$PROJECT_NAME")"
sid="$(ensure_section "$pid")"
ensure_label

# ── Read prior state ────────────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then prev="$(cat "$STATE_FILE")"; else prev='{"last_run":0,"open":{}}'; fi
prev_open="$(printf '%s' "$prev" | jq -c '.open // {}')"

# ── Read Home Assistant ChoreOps sensors ────────────────────────────────────
states="$(hget /api/states)"
now_epoch="$(date +%s)"
horizon_epoch=$((now_epoch + HORIZON_DAYS * 86400))

# slug -> {name, can_claim, state} for ALL of Finn's chores (reverse lookups)
allmap="$(printf '%s' "$states" | jq -c --arg p "$PREFIX" '
  [ .[] | select(.entity_id | startswith($p)) | {
      key: (.entity_id | ltrimstr($p)),
      value: { name: .attributes.chore_name,
               can_claim: (.attributes.can_claim // false),
               state: .state }
  } ] | from_entries')"

# Actionable subset: Finn's turn (pending/overdue), overdue OR due within horizon.
actionable="$(printf '%s' "$states" | jq -c --arg p "$PREFIX" --argjson h "$horizon_epoch" '
  [ .[] | select(.entity_id | startswith($p))
    | { slug:(.entity_id | ltrimstr($p)),
        name:.attributes.chore_name,
        desc:(.attributes.description // ""),
        state:.state,
        due_epoch:(if (.attributes.due_date // null)==null then null
                   else (.attributes.due_date | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601) end) }
    | select( (.state=="pending" or .state=="overdue")
              and (.state=="overdue" or (.due_epoch!=null and .due_epoch<=$h)) )
  ]')"

# ── Read open managed Todoist tasks (label=choreops) → slug -> task_id ───────
openmap='{}'
cursor=""
while :; do
  if [ -n "$cursor" ]; then
    url="$TD_API/tasks?project_id=$pid&cursor=$cursor"
  else
    url="$TD_API/tasks?project_id=$pid"
  fi
  resp="$(tapi list-tasks "$url")"
  page="$(printf '%s' "$resp" | jq -c --arg lbl "$LABEL" '
    [ (if type=="array" then . else .results end)[]
      | select((.labels // []) | index($lbl))
      | { key: ((.description // "")
                 | [ match("\\[choreops:([a-z0-9_]+)\\]").captures[0].string ]
                 | (.[0] // "")),
          value: (.id | tostring) } ]
    | map(select(.key != "")) | from_entries')"
  openmap="$(jq -c -n --argjson a "$openmap" --argjson b "$page" '$a + $b')"
  cursor="$(printf '%s' "$resp" | jq -r 'if type=="array" then "" else (.next_cursor // "") end')"
  if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then break; fi
done

# ── Read recently completed task ids (for sync-back confirmation) ────────────
since="$(date -u -d "@$((now_epoch - COMPLETED_LOOKBACK_DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)"
until_ts="$(date -u -d "@$now_epoch" +%Y-%m-%dT%H:%M:%SZ)"
completed_ids='[]'
cursor=""
while :; do
  if [ -n "$cursor" ]; then
    url="$TD_API/tasks/completed/by_completion_date?since=$since&until=$until_ts&cursor=$cursor"
  else
    url="$TD_API/tasks/completed/by_completion_date?since=$since&until=$until_ts"
  fi
  if ! resp="$(tapi list-completed "$url")"; then break; fi
  ids="$(printf '%s' "$resp" | jq -c '
    [ (.items // .results // (if type=="array" then . else [] end))[]
      | (.task_id // .id) | tostring ]')"
  completed_ids="$(jq -c -n --argjson a "$completed_ids" --argjson b "$ids" '$a + $b')"
  cursor="$(printf '%s' "$resp" | jq -r '.next_cursor // ""')"
  if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then break; fi
done

# ── REVERSE: Todoist completion → ChoreOps claim+approve ────────────────────
claims=0
removed='[]'
while IFS=$'\t' read -r slug tid; do
  [ -z "$slug" ] && continue
  hit="$(jq -r --argjson ids "$completed_ids" --arg t "$tid" '$ids|index($t)|if .==null then 0 else 1 end')"
  if [ "$hit" != "1" ]; then
    log "tracked task gone but not in completed feed (deleted?): $slug"
    continue
  fi
  can="$(jq -r --argjson m "$allmap" --arg s "$slug" '$m[$s].can_claim // false')"
  name="$(jq -r --argjson m "$allmap" --arg s "$slug" '$m[$s].name // ""')"
  if [ "$can" != "true" ] || [ -z "$name" ]; then
    log "completed in Todoist but not claimable in HA, skipping sync-back: $slug"
    continue
  fi
  if [ "$DRY" = "1" ]; then
    log "[dry] would claim+approve: $name ($slug)"
  else
    if ! hpost /api/services/choreops/claim_chore \
      "$(jq -nc --arg u "$PERSON" --arg c "$name" '{user_name:$u,chore_name:$c}')"; then
      log "claim failed: $name"
      continue
    fi
    if ! hpost /api/services/choreops/approve_chore \
      "$(jq -nc --arg u "$PERSON" --arg c "$name" '{approver_name:$u,user_name:$u,chore_name:$c}')"; then
      log "approve failed: $name"
    fi
    log "synced completion → ChoreOps: $name"
  fi
  removed="$(jq -c -n --argjson a "$removed" --arg s "$slug" '$a + [$s]')"
  claims=$((claims + 1))
done < <(jq -r --argjson om "$openmap" \
  'to_entries[] | select(($om[.key] // null) == null) | [.key, .value.task_id] | @tsv' <<<"$prev_open")

# Drop claimed slugs from actionable so forward does not re-create them this run.
actionable="$(jq -c --argjson rm "$removed" 'map(select((.slug) as $s | ($rm|index($s))|not))' <<<"$actionable")"

# ── FORWARD: ChoreOps actionable → Todoist upsert ───────────────────────────
newopen='{}'
while read -r obj; do
  [ -z "$obj" ] && continue
  slug="$(jq -r '.slug' <<<"$obj")"
  name="$(jq -r '.name' <<<"$obj")"
  desc="$(jq -r '.desc' <<<"$obj")"
  state="$(jq -r '.state' <<<"$obj")"
  due_epoch="$(jq -r '.due_epoch // empty' <<<"$obj")"
  if [ -n "$due_epoch" ]; then due_local="$(date -d "@$due_epoch" +%F)"; else due_local=""; fi
  if [ "$state" = "overdue" ]; then prio=3; else prio=1; fi
  full_desc="$desc"$'\n\n'"[choreops:$slug]"
  existing="$(jq -r --arg s "$slug" '.[$s] // empty' <<<"$openmap")"
  if [ -n "$existing" ]; then
    tid="$existing"
    prev_due="$(jq -r --arg s "$slug" '.[$s].due // ""' <<<"$prev_open")"
    if [ -n "$due_local" ] && [ "$prev_due" != "$due_local" ]; then
      if [ "$DRY" = "1" ]; then
        log "[dry] would update due: $name → $due_local"
      else
        tapi update-task -X POST -H 'Content-Type: application/json' \
          -d "$(jq -nc --arg d "$due_local" '{due_date:$d}')" "$TD_API/tasks/$tid" >/dev/null
        log "updated due: $name → $due_local"
      fi
    fi
  else
    if [ "$DRY" = "1" ]; then
      log "[dry] would create task: $name (due ${due_local:-none})"
      tid="dry-$slug"
    else
      payload="$(jq -nc --arg c "$name" --arg de "$full_desc" --arg p "$pid" \
        --arg se "$sid" --arg lbl "$LABEL" --argjson pr "$prio" --arg dd "$due_local" '
        {content:$c, description:$de, project_id:$p, labels:[$lbl], priority:$pr}
        + (if $se=="" then {} else {section_id:$se} end)
        + (if $dd=="" then {} else {due_date:$dd} end)')"
      resp="$(tapi create-task -X POST -H 'Content-Type: application/json' -d "$payload" "$TD_API/tasks")"
      tid="$(printf '%s' "$resp" | jq -r '.id')"
      log "created task: $name (due ${due_local:-none})"
    fi
  fi
  newopen="$(jq -c -n --argjson o "$newopen" --arg s "$slug" --arg t "$tid" --arg d "$due_local" \
    '$o + {($s):{task_id:$t,due:$d}}')"
done < <(jq -c '.[]' <<<"$actionable")

# ── CLEANUP: open managed tasks whose chore is no longer actionable → close ─
actionable_slugs="$(jq -c '[.[].slug]' <<<"$actionable")"
while IFS=$'\t' read -r slug tid; do
  [ -z "$slug" ] && continue
  keep="$(jq -r --argjson a "$actionable_slugs" --arg s "$slug" '$a|index($s)|if .==null then 0 else 1 end')"
  if [ "$keep" = "1" ]; then continue; fi
  if [ "$DRY" = "1" ]; then
    log "[dry] would close stale task: $slug"
    continue
  fi
  if tapi close-task -X POST "$TD_API/tasks/$tid/close" >/dev/null; then
    log "closed stale task: $slug"
  fi
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$openmap")

# ── Persist state ───────────────────────────────────────────────────────────
if [ "$DRY" != "1" ]; then
  jq -n --argjson o "$newopen" --argjson t "$now_epoch" '{last_run:$t, open:$o}' >"$STATE_FILE"
fi
log "done (claims=$claims, open=$(jq 'length' <<<"$newopen"))"
