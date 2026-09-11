{
  bash,
  coreutils,
  gnused,
  writeShellApplication,
}:
writeShellApplication {
  name = "agent-run-long";
  meta.description = "Run one command with a bounded lifetime and durable private log";
  runtimeInputs = [
    bash
    coreutils
    gnused
  ];
  text = ''
    usage() {
      printf '%s\n' 'usage: agent-run-long --label LABEL --timeout DURATION [--excerpt-lines N] -- COMMAND [ARG...]' >&2
    }

    cli_error() {
      printf 'agent-run-long: %s\n' "$1" >&2
      usage
      exit 2
    }

    setup_error() {
      printf 'agent-run-long: %s\n' "$1" >&2
      exit 125
    }

    label=""
    timeout_spec=""
    excerpt_lines=20
    saw_separator=0

    while (( $# > 0 )); do
      case "$1" in
        --label)
          (( $# >= 2 )) || cli_error '--label requires a value'
          label="$2"
          shift 2
          ;;
        --timeout)
          (( $# >= 2 )) || cli_error '--timeout requires a value'
          timeout_spec="$2"
          shift 2
          ;;
        --excerpt-lines)
          (( $# >= 2 )) || cli_error '--excerpt-lines requires a value'
          excerpt_lines="$2"
          shift 2
          ;;
        --)
          saw_separator=1
          shift
          break
          ;;
        -h | --help)
          usage
          exit 0
          ;;
        *)
          cli_error "expected an option or --, got: $1"
          ;;
      esac
    done

    (( saw_separator == 1 )) || cli_error 'missing -- before COMMAND'
    (( $# > 0 )) || cli_error 'missing COMMAND'
    [[ -n "$timeout_spec" ]] || cli_error '--timeout is required'
    [[ "$timeout_spec" =~ ^([1-9][0-9]{0,4})([smh])$ ]] \
      || cli_error '--timeout must be a positive integer followed by s, m, or h'

    timeout_amount="''${BASH_REMATCH[1]}"
    timeout_unit="''${BASH_REMATCH[2]}"
    case "$timeout_unit" in
      s)
        (( timeout_amount <= 86400 )) || cli_error '--timeout must not exceed 24h'
        limit_s=$timeout_amount
        ;;
      m)
        (( timeout_amount <= 1440 )) || cli_error '--timeout must not exceed 24h'
        limit_s=$((timeout_amount * 60))
        ;;
      h)
        (( timeout_amount <= 24 )) || cli_error '--timeout must not exceed 24h'
        limit_s=$((timeout_amount * 3600))
        ;;
    esac

    if [[ ! "$excerpt_lines" =~ ^[0-9]{1,2}$ ]] || (( 10#$excerpt_lines > 80 )); then
      cli_error '--excerpt-lines must be an integer from 0 to 80'
    fi

    # Keep run-directory names portable and harmless even when labels originate
    # from untrusted issue titles or task descriptions.
    label=$(LC_ALL=C printf '%s' "$label" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)
    [[ -n "$label" ]] || label=run

    umask 077
    base=/tmp/opencode
    uid=$(id -u)

    if [[ -L "$base" ]]; then
      setup_error "$base must not be a symlink"
    fi
    if [[ ! -e "$base" ]]; then
      mkdir -p -- "$base" || setup_error "cannot create $base"
    fi
    if [[ -L "$base" || ! -d "$base" ]]; then
      setup_error "$base must be a directory, not a symlink"
    fi

    base_owner=$(stat -c '%u' -- "$base") || setup_error "cannot inspect $base"
    base_mode=$(stat -c '%a' -- "$base") || setup_error "cannot inspect $base"
    [[ "$base_owner" == "$uid" ]] || setup_error "$base has foreign owner $base_owner"
    (( (8#$base_mode & 0022) == 0 )) || setup_error "$base is group- or other-writable"

    run_dir=$(mktemp -d -- "$base/agent-run-long.$label.XXXXXXXXXX") \
      || setup_error "cannot create a private run directory under $base"
    [[ ! -L "$run_dir" && -d "$run_dir" ]] \
      || setup_error "private run directory is invalid"
    run_owner=$(stat -c '%u' -- "$run_dir") || setup_error "cannot inspect private run directory"
    run_mode=$(stat -c '%a' -- "$run_dir") || setup_error "cannot inspect private run directory"
    [[ "$run_owner" == "$uid" ]] || setup_error "private run directory has foreign owner"
    (( (8#$run_mode & 0022) == 0 )) || setup_error "private run directory is group- or other-writable"

    log_file="$run_dir/output.log"
    status_file="$run_dir/status"
    started_epoch_s=$(date +%s)

    write_status() {
      local state="$1"
      local exit_code="$2"
      local elapsed_s="$3"
      local temporary

      if ! temporary=$(mktemp "$run_dir/.status.XXXXXXXXXX"); then
        return 1
      fi
      if ! {
        printf 'state=%s\n' "$state"
        printf 'label=%s\n' "$label"
        printf 'limit_s=%s\n' "$limit_s"
        printf 'log=%s\n' "$log_file"
        printf 'started_epoch_s=%s\n' "$started_epoch_s"
        printf 'elapsed_s=%s\n' "$elapsed_s"
        if [[ -n "$exit_code" ]]; then
          printf 'exit_code=%s\n' "$exit_code"
        fi
      } > "$temporary"; then
        rm -f -- "$temporary"
        return 1
      fi
      mv -f -- "$temporary" "$status_file"
    }

    emit_summary() {
      printf 'state=%s exit_code=%s elapsed_s=%s limit_s=%s log=%s\n' \
        "$1" "$2" "$3" "$limit_s" "$log_file"
    }

    emit_excerpt() {
      local raw_suffix raw_preview bounded_preview rendered_preview preview_bytes preview_truncated=0

      (( excerpt_lines > 0 )) || return 0
      raw_suffix="$run_dir/.preview.suffix"
      raw_preview="$run_dir/.preview.raw"
      bounded_preview="$run_dir/.preview.bounded"
      rendered_preview="$run_dir/.preview.rendered"
      # Bound intermediates before line selection: a log with one enormous
      # final line must not make preview rendering proportional to log size.
      tail -c 65536 -- "$log_file" > "$raw_suffix" || return 1
      tail -n "$excerpt_lines" -- "$raw_suffix" > "$raw_preview" || return 1
      preview_bytes=$(wc -c < "$raw_preview") || return 1
      if (( preview_bytes > 8192 )); then
        tail -c 8192 -- "$raw_preview" > "$bounded_preview" || return 1
        preview_truncated=1
      else
        cat "$raw_preview" > "$bounded_preview" || return 1
      fi

      # The log stays byte-for-byte intact. Only the terminal preview loses
      # escape sequences and other C0 controls that could alter the caller's UI.
      LC_ALL=C sed -E \
        -e 's/\x1B\[[0-?]*[ -/]*[@-~]//g' \
        -e 's/\x1B\][^\x07\x1B]*(\x07|\x1B\\)//g' \
        -e 's/[^[:print:]\t]/?/g' \
        < "$bounded_preview" > "$rendered_preview" || return 1

      printf '%s\n' "--- last $excerpt_lines log lines ---" >&2
      cat "$rendered_preview" >&2
      if (( preview_truncated )); then
        printf '\n[excerpt truncated at 8192 bytes]\n' >&2
      fi
    }

    process_group() {
      local stat_line remainder pgrp

      [[ -r "/proc/$1/stat" ]] || return 1
      stat_line=$(< "/proc/$1/stat") || return 1
      remainder="''${stat_line##*) }"
      read -r _ _ pgrp _ <<< "$remainder"
      [[ "$pgrp" =~ ^[0-9]+$ ]] || return 1
      printf '%s\n' "$pgrp"
    }

    timeout_pid=""
    command_pgid=""
    caller_pgid=$(process_group "$$") || setup_error 'cannot determine caller process group'
    command_cleanup_started=0
    interrupted=0

    establish_command_group() {
      # GNU coreutils timeout without --foreground creates a new process group
      # whose PGID is its own PID; its command inherits that group.
      if [[ "$timeout_pid" =~ ^[1-9][0-9]*$ && "$timeout_pid" != "$caller_pgid" ]]; then
        command_pgid="$timeout_pid"
      fi
    }

    command_group_has_members() {
      [[ "$command_pgid" =~ ^[1-9][0-9]*$ ]] || return 1
      [[ "$command_pgid" != "$caller_pgid" ]] || return 1
      # A stored PGID can theoretically be reused after the original process
      # group exits. Cleanup happens immediately and only targets a live group
      # confirmed by kill -0, which bounds (but cannot eliminate) that PID-reuse
      # race without a cgroup or pidfd.
      kill -0 -- "-$command_pgid" 2>/dev/null
    }

    signal_command_group() {
      local signal="$1"

      if command_group_has_members; then
        kill "-$signal" -- "-$command_pgid" 2>/dev/null || true
      fi
    }

    begin_command_group_cleanup() {
      (( command_cleanup_started == 0 )) || return 0
      command_cleanup_started=1
      signal_command_group TERM
    }

    finish_command_group_cleanup() {
      local grace_started_s=$SECONDS

      begin_command_group_cleanup
      # Check against a deadline rather than five scan+sleep iterations: /proc
      # scans themselves take measurable time, and must not stretch the fixed
      # five-second grace into a second timeout window.
      while (( SECONDS - grace_started_s < 5 )); do
        command_group_has_members || return 0
        sleep 1
      done
      if command_group_has_members; then
        signal_command_group KILL
      fi
    }

    cleanup_command_group() {
      begin_command_group_cleanup
      finish_command_group_cleanup
    }

    # This monitor is owned by the wrapper. It is deliberately killed rather
    # than TERM'd during wrapper interruption so GNU timeout cannot begin a
    # second --kill-after grace while this wrapper owns the one bounded grace.
    # shellcheck disable=SC2329
    terminate_timeout_monitor() {
      if [[ -n "$timeout_pid" ]]; then
        kill -KILL -- "$timeout_pid" 2>/dev/null || true
        wait "$timeout_pid" 2>/dev/null || true
        timeout_pid=""
      fi
    }

    # shellcheck disable=SC2329
    on_signal() {
      local signal_name="$1"
      local signal_exit_code="$2"
      local elapsed_s

      (( interrupted == 0 )) || return 0
      interrupted=1
      trap "" HUP INT TERM
      if command_group_has_members; then
        begin_command_group_cleanup
        finish_command_group_cleanup
        terminate_timeout_monitor
      else
        # Without the verified distinct group, leave timeout running so its
        # original deadline remains the bounded cleanup mechanism.
        timeout_pid=""
      fi
      elapsed_s=$SECONDS
      if ! write_status interrupted "$signal_exit_code" "$elapsed_s"; then
        printf 'agent-run-long: failed to finalize status after %s\n' "$signal_name" >&2
      fi
      emit_summary interrupted "$signal_exit_code" "$elapsed_s"
      emit_excerpt || printf '%s\n' 'agent-run-long: could not render log excerpt' >&2
      exit "$signal_exit_code"
    }

    if ! write_status running "" 0; then
      setup_error "cannot write initial status in $run_dir"
    fi

    # This is deliberately emitted before the command starts so an interrupted
    # caller can recover the durable log and status location.
    printf '%s\n' "$log_file"

    trap 'on_signal HUP 129' HUP
    trap 'on_signal INT 130' INT
    trap 'on_signal TERM 143' TERM

    SECONDS=0
    set +e
    env \
      --default-signal=HUP \
      --default-signal=INT \
      --default-signal=TERM \
      timeout --verbose --signal=TERM --kill-after=5s -- "$timeout_spec" "$@" \
      < /dev/null > "$log_file" 2>&1 &
    timeout_pid=$!
    establish_command_group
    wait "$timeout_pid"
    exit_code=$?
    timeout_pid=""
    cleanup_command_group
    set -e

    elapsed_s=$SECONDS
    # GNU timeout's 124 is also a legal child exit code, so ordinary completion
    # is intentionally not labelled "timed out" without an unambiguous signal.
    if ! write_status exited "$exit_code" "$elapsed_s"; then
      printf 'agent-run-long: failed to finalize status in %s\n' "$run_dir" >&2
      exit 125
    fi
    emit_summary exited "$exit_code" "$elapsed_s"
    emit_excerpt || printf '%s\n' 'agent-run-long: could not render log excerpt' >&2
    exit "$exit_code"
  '';
}
