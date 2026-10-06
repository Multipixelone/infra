''
  shopt -s nullglob
  policies=(/sys/devices/system/cpu/cpufreq/policy*)
  if (( ''${#policies[@]} == 0 )); then
    echo 'No CPU frequency policies; check BIOS CPPC and amd_pstate=active' >&2
    exit 1
  fi
  # Validate every policy before writing any. A performance governor rejects
  # non-performance EPP: GameMode must restore powersave before calling us.
  for policy in "''${policies[@]}"; do
    if [[ ! -r "$policy/scaling_driver" || ! -r "$policy/scaling_governor" \
       || ! -r "$policy/energy_performance_available_preferences" \
       || ! -w "$policy/energy_performance_preference" ]]; then
      echo "Missing AMD EPP controls in $policy; check BIOS CPPC" >&2
      exit 1
    fi
    if [[ "$(< "$policy/scaling_driver")" != amd-pstate-epp \
       || "$(< "$policy/scaling_governor")" != powersave \
       || " $(< "$policy/energy_performance_available_preferences") " != *' balance_performance '* ]]; then
      echo "Expected amd-pstate-epp, powersave and balance_performance in $policy" >&2
      exit 1
    fi
  done
  for policy in "''${policies[@]}"; do
    echo balance_performance > "$policy/energy_performance_preference"
  done
''
