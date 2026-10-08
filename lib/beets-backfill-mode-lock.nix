{ pkgs }:
pkgs.writeShellApplication {
  name = "beets-backfill-mode-lock";
  runtimeInputs = [ pkgs.util-linux ];
  text = ''
    # shellcheck shell=bash
    # Arguments: stable lock directory, nightly|now, command [args...].
    lock_directory=$1
    mode=$2
    shift 2
    case "$mode" in
    nightly) opposite=now ;;
    now) opposite=nightly ;;
    *)
      echo "Unknown backfill mode: $mode" >&2
      exit 2
      ;;
    esac

    # Serialize admission so opposite modes cannot both pass their checks. These
    # files must never be unlinked while workers run: locks belong to their inodes.
    exec {coordination_fd}>"$lock_directory/admission.lock"
    flock --exclusive "$coordination_fd"
    exec {opposite_fd}>"$lock_directory/$opposite.lock"
    if flock --exclusive --nonblock "$opposite_fd"; then
      :
    else
      status=$?
      if [[ "$status" == 1 ]]; then
        echo "Beets $opposite backfill already running; skipping $mode run"
        exit 0
      fi
      exit "$status"
    fi
    exec {mode_fd}>"$lock_directory/$mode.lock"
    flock --shared "$mode_fd"
    flock --unlock "$opposite_fd"
    exec {opposite_fd}>&-
    flock --unlock "$coordination_fd"
    exec {coordination_fd}>&-
    # Only the shared mode descriptor survives exec, including worker descendants
    # and cleanup. Both backfills in this mode can run concurrently.
    exec "$@"
  '';
}
