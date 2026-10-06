''
  #!/usr/bin/env bash
  # Shared direct-delivery renderer; the equivalent Alertmanager Go template
  # is checked against the same format contract. Epoch arguments keep persisted
  # incident timestamps independent of the host's local timezone.
  alert_time() {
    TZ=America/New_York date -d "@$1" '+%Y-%m-%d %H:%M %Z'
  }

  render_alert() {
    local status="$1" alertname="$2" target="$3" started="$4" ended="$5" summary="$6" hint="$7"
    if [[ "$status" == resolved ]]; then
      printf '✅ RESOLVED: %s\n' "$alertname"
    else
      printf '🔴 FIRING: %s\n' "$alertname"
    fi
    printf '%s — since %s\n' "$target" "$(alert_time "$started")"
    if [[ "$status" == resolved ]]; then
      printf 'Ended: %s\n' "$(alert_time "$ended")"
    else
      printf '%s\nHint: %s\n' "$summary" "$hint"
    fi
  }
''
