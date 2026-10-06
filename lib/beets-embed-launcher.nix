''
  export TZ=America/New_York
  mode="''${1:-nightly}"
  budget=$((BEETS_EMBED_BUDGET_SECONDS - 60))
  remaining=$budget
  case "$mode" in
    nightly)
      now=$(date +%s)
      # Midnight plus one hour selects the first 01:00 on the autumn DST fold,
      # regardless of GNU date's resolution of the ambiguous local 01:00.
      midnight=$(date --date='today 00:00:00' +%s)
      start=$((midnight + 3600))
      stop=$(date --date='today 08:59:00' +%s)
      if (( now < start || now >= stop )); then
        echo "Outside the nightly embed backfill window; skipping"
        exit 0
      fi
      # Include escalation in both the elapsed budget and wall-clock cutoff.
      # Epochs handle DST; the calendar stop also handles suspend, during which
      # GNU timeout's relative clock pauses.
      wall_remaining=$((stop - now))
      if (( wall_remaining < remaining )); then
        remaining=$wall_remaining
      fi
      ;;
    now) ;;
    *) echo "Unknown backfill mode: $mode" >&2; exit 2 ;;
  esac
  echo "Embed budget: $remaining seconds, then up to 60 seconds for shutdown"
  exec timeout --signal=TERM --kill-after=60s "''${remaining}s" \
    "$BEETS_EMBED_RUNNER" --config "$BEETS_EMBED_CONFIG" --threads "$BEETS_EMBED_THREADS"
''
