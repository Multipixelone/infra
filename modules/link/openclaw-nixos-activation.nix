{ lib, ... }:
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      stateDir = "/var/lib/openclaw-nixos-activate";
      approvedDir = "${stateDir}/approved";
      lockFile = "${stateDir}/lock";
      watchdogState = "${stateDir}/watchdog.json";
      watchdogFailedBefore = "${stateDir}/failed-before";

      # The watchdog is armed twice for a `switch`: once to cover the activation
      # itself (bootloader install, initrd regeneration), then re-armed once
      # activation returns so verification and confirm get the full window. Arming
      # only once, before activation, spent the verification budget on the switch
      # and rolled back healthy systems for confirming late.
      activationWindowSeconds = 1800;
      verifyWindowSeconds = 300;

      bash = "${pkgs.bash}/bin/bash";
      coreutils = "${pkgs.coreutils}/bin";
      gawk = "${pkgs.gawk}/bin/awk";
      gnugrep = "${pkgs.gnugrep}/bin/grep";
      jq = "${pkgs.jq}/bin/jq";
      nh = lib.getExe config.programs.nh.package;
      nix = lib.getExe' config.nix.package "nix";
      nixStore = lib.getExe' config.nix.package "nix-store";
      nvd = lib.getExe pkgs.nvd;
      systemctl = lib.getExe' pkgs.systemd "systemctl";
      systemdCat = lib.getExe' pkgs.systemd "systemd-cat";
      systemdRun = lib.getExe' pkgs.systemd "systemd-run";
      flock = lib.getExe' pkgs.util-linux "flock";
      nc = lib.getExe' pkgs.netcat-openbsd "nc";
      ip = lib.getExe' pkgs.iproute2 "ip";

      # nh launches nix and systemd helpers internally. Its PATH is restricted to
      # immutable store directories even though this module invokes every helper
      # it controls directly by absolute path.
      cleanPath = lib.makeBinPath [
        config.programs.nh.package
        config.nix.package
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.nvd
        pkgs.systemd
        pkgs.util-linux
      ];

      validationLibrary = pkgs.writeText "openclaw-nixos-validation.sh" ''
        journal() {
          local message="$1"
          ${coreutils}/printf '%s\n' "$message" >&2
          ${coreutils}/printf '%s\n' "$message" | ${systemdCat} -t "$JOURNAL_TAG" || true
        }

        refuse() {
          local code="$1"
          shift
          journal "$*"
          exit "$code"
        }

        lock_holder() {
          local inode
          inode="$(${coreutils}/stat -Lc %i "$1")" || return 1
          ${gawk} -v inode="$inode" '$6 ~ (":" inode "$") { print $5; exit }' /proc/locks
        }

        parse_target_and_mode() {
          if (( $# != 1 && $# != 3 )); then
            refuse 64 "refused reason=bad_argument_shape"
          fi

          TARGET="$1"
          MODE="test"
          if (( $# == 3 )); then
            if [[ "$2" != "--mode" || ( "$3" != "test" && "$3" != "switch" ) ]]; then
              refuse 64 "refused reason=bad_mode_argument"
            fi
            MODE="$3"
          fi
        }

        target_nar_hash() {
          local target="$1"
          local info
          info="$(${nix} path-info --json -- "$target")" || return 1
          ${coreutils}/printf '%s' "$info" | ${jq} -r --arg path "$target" '
            if type == "object" then
              .[$path].narHash // empty
            elif type == "array" then
              (map(select(.path == $path))[0].narHash // empty)
            else
              empty
            end
          '
        }

        validate_target() {
          local target="$1"
          local resolved system hostname

          if [[ "$target" == *$'\n'* || "$target" == *$'\r'* || "$target" == *$'\t'* || "$target" == *' '* ]]; then
            refuse 64 "refused reason=noncanonical_target"
          fi
          if [[ ! "$target" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-link-[^/]+$ ]]; then
            refuse 64 "refused reason=noncanonical_target"
          fi
          if [[ -L "$target" ]]; then
            refuse 64 "refused reason=symlink_target"
          fi
          resolved="$(${coreutils}/realpath -e -- "$target" 2>/dev/null)" ||
            refuse 65 "refused reason=missing_store_target"
          if [[ "$resolved" != "$target" ]]; then
            refuse 64 "refused reason=noncanonical_target"
          fi

          ${nix} path-info -- "$target" >/dev/null 2>&1 ||
            refuse 65 "refused reason=unregistered_store_target"
          ${nixStore} --query --hash "$target" >/dev/null 2>&1 ||
            refuse 65 "refused reason=unregistered_store_target"

          [[ -f "$target/system" ]] || refuse 65 "refused reason=missing_system_marker"
          system="$(${coreutils}/tr -d '\r\n' < "$target/system")"
          [[ "$system" == "x86_64-linux" ]] || refuse 65 "refused reason=wrong_system"

          [[ -f "$target/etc/hostname" ]] || refuse 65 "refused reason=missing_hostname"
          hostname="$(${coreutils}/tr -d '\r\n' < "$target/etc/hostname")"
          [[ "$hostname" == "link" ]] || refuse 65 "refused reason=wrong_hostname"

          [[ -x "$target/activate" ]] || refuse 65 "refused reason=missing_activate"
          [[ -x "$target/bin/switch-to-configuration" ]] ||
            refuse 65 "refused reason=missing_switch_to_configuration"
        }
      '';

      watchdogLogic = pkgs.writeShellScript "openclaw-nixos-rollback-watchdog" ''
        set -euo pipefail
        export PATH=${cleanPath}
        export LANG=C LC_ALL=C
        JOURNAL_TAG=openclaw-nixos-rollback-watchdog
        source ${validationLibrary}

        if (( EUID != 0 )); then
          refuse 78 "refused reason=not_root"
        fi

        exec 9> ${lockFile}
        if ! ${flock} -w 300 9; then
          holder="$(lock_holder ${lockFile} 2>/dev/null || true)"
          [[ -n "$holder" ]] || holder=unknown
          refuse 75 "refused reason=lock_timeout holder_pid=$holder"
        fi

        [[ -f ${watchdogState} ]] || exit 0
        old_path="$(${jq} -r '.oldPath // empty' ${watchdogState})"
        requested_path="$(${jq} -r '.requestedPath // empty' ${watchdogState})"
        approval_id="$(${jq} -r '.approvalId // empty' ${watchdogState})"

        reasons=()
        current_failed="$(${coreutils}/mktemp ${stateDir}/failed-now.XXXXXX)"
        cleanup() { ${coreutils}/rm -f -- "$current_failed"; }
        trap cleanup EXIT

        ${systemctl} list-units --failed --no-legend --plain --no-pager |
          ${gawk} '{ print $1 }' | ${coreutils}/sort -u > "$current_failed"
        if [[ ! -f ${watchdogFailedBefore} ]]; then
          reasons+=(missing_failed_snapshot)
        elif [[ -n "$(${coreutils}/comm -13 ${watchdogFailedBefore} "$current_failed")" ]]; then
          reasons+=(new_failed_units)
        fi
        if ! ${nc} -z -w 5 127.0.0.1 18789; then
          reasons+=(gateway_port)
        fi
        if ! ${ip} route show default | ${gnugrep} -q '^default'; then
          reasons+=(default_route)
        fi

        if (( ''${#reasons[@]} == 0 )); then
          journal "watchdog healthy requested=$requested_path approval_id=$approval_id"
          ${coreutils}/rm -f -- ${watchdogState} ${watchdogFailedBefore}
          exit 0
        fi

        journal "watchdog unhealthy requested=$requested_path approval_id=$approval_id reasons=''${reasons[*]} rollback=$old_path"
        if [[ ! "$old_path" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-link-[^/]+$ || ! -x "$old_path/bin/switch-to-configuration" ]]; then
          refuse 65 "rollback refused reason=invalid_previous_closure"
        fi

        if "$old_path/bin/switch-to-configuration" switch; then
          journal "rollback success restored=$old_path from=$requested_path approval_id=$approval_id"
          ${coreutils}/rm -f -- ${watchdogState} ${watchdogFailedBefore}
        else
          status=$?
          journal "rollback failure status=$status target=$old_path from=$requested_path approval_id=$approval_id"
          exit "$status"
        fi
      '';

      approveLogic = pkgs.writeShellScript "openclaw-nixos-approve-logic" ''
        set -euo pipefail
        export PATH=${cleanPath}
        export LANG=C LC_ALL=C
        JOURNAL_TAG=openclaw-nixos-approve
        source ${validationLibrary}

        if (( EUID != 0 )); then
          refuse 78 "refused reason=not_root"
        fi
        parse_target_and_mode "$@"
        validate_target "$TARGET"
        nar_hash="$(target_nar_hash "$TARGET")" ||
          refuse 65 "refused reason=nar_hash_unavailable"
        [[ -n "$nar_hash" ]] || refuse 65 "refused reason=nar_hash_unavailable"

        now="$(${coreutils}/date +%s)"
        expiry=$((now + 1800))
        issuer="''${SUDO_UID:-0}"
        [[ "$issuer" =~ ^[0-9]+$ ]] || issuer=0

        ${coreutils}/printf 'Target:  %s\nMode:    %s\nExpires: %s\n\n' \
          "$TARGET" "$MODE" "$(${coreutils}/date --date="@$expiry" --iso-8601=seconds)"
        ${nvd} diff /run/current-system "$TARGET"
        ${coreutils}/printf '\nThis approval is single-use. Type approve to authorize this exact closure: '
        if ! IFS= read -r confirmation || [[ "$confirmation" != "approve" ]]; then
          refuse 77 "approval cancelled target=$TARGET mode=$MODE"
        fi

        umask 077
        temp="$(${coreutils}/mktemp ${approvedDir}/.approval.XXXXXXXXXX)"
        cleanup() { ${coreutils}/rm -f -- "$temp"; }
        trap cleanup EXIT
        random_id="''${temp##*.approval.}"
        record_id="approval-$random_id"
        ${jq} -n \
          --arg path "$TARGET" \
          --arg mode "$MODE" \
          --arg narHash "$nar_hash" \
          --argjson issuingUid "$issuer" \
          --argjson issuedAt "$now" \
          --argjson expiresAt "$expiry" \
          '{ path: $path, mode: $mode, narHash: $narHash, issuingUid: $issuingUid, issuedAt: $issuedAt, expiresAt: $expiresAt }' \
          > "$temp"
        ${coreutils}/chmod 0600 "$temp"
        record="${approvedDir}/$record_id.json"
        ${coreutils}/mv -- "$temp" "$record"
        trap - EXIT
        journal "approval issued id=$record_id path=$TARGET mode=$MODE nar_hash=$nar_hash issuing_uid=$issuer expires_at=$expiry"
      '';

      activateLogic = pkgs.writeShellScript "openclaw-nixos-activate-logic" ''
        set -euo pipefail
        export PATH=${cleanPath}
        export LANG=C LC_ALL=C
        unset BASH_ENV ENV CDPATH GLOBIGNORE
        JOURNAL_TAG=openclaw-nixos-activate
        source ${validationLibrary}

        if (( EUID != 0 )); then
          refuse 78 "refused reason=not_root"
        fi
        parse_target_and_mode "$@"
        validate_target "$TARGET"

        exec 9> ${lockFile}
        if ! ${flock} -w 300 9; then
          holder="$(lock_holder ${lockFile} 2>/dev/null || true)"
          [[ -n "$holder" ]] || holder=unknown
          refuse 75 "refused reason=lock_timeout holder_pid=$holder"
        fi

        now="$(${coreutils}/date +%s)"
        current_hash="$(target_nar_hash "$TARGET")" ||
          refuse 65 "refused reason=nar_hash_unavailable"
        [[ -n "$current_hash" ]] || refuse 65 "refused reason=nar_hash_unavailable"

        matching_record=""
        refusal_reason=no_matching_approval
        shopt -s nullglob
        for record in ${approvedDir}/*.json; do
          record_path="$(${jq} -r '.path // empty' "$record" 2>/dev/null || true)"
          record_mode="$(${jq} -r '.mode // empty' "$record" 2>/dev/null || true)"
          record_expiry="$(${jq} -r '.expiresAt // 0' "$record" 2>/dev/null || true)"
          record_hash="$(${jq} -r '.narHash // empty' "$record" 2>/dev/null || true)"

          if [[ "$record_path" != "$TARGET" ]]; then
            continue
          fi
          if [[ "$record_mode" != "$MODE" ]]; then
            refusal_reason=approval_mode_mismatch
            continue
          fi
          if [[ ! "$record_expiry" =~ ^[0-9]+$ ]] || (( record_expiry < now )); then
            refusal_reason=approval_expired
            continue
          fi
          if [[ "$record_hash" != "$current_hash" ]]; then
            refusal_reason=approval_nar_hash_mismatch
            continue
          fi
          matching_record="$record"
          break
        done

        if [[ -z "$matching_record" ]]; then
          refuse 77 "refused reason=$refusal_reason path=$TARGET mode=$MODE"
        fi

        approval_id="$(${coreutils}/basename "$matching_record" .json)"

        # The rollback baseline is the BOOT DEFAULT, not the running system. Under a
        # live `test` generation /run/current-system is a closure the human approved
        # for this boot only; rolling that back with `switch-to-configuration switch`
        # would promote it to the boot default, turning a test-only approval into
        # persistence. Refuse the switch outright, and snapshot the profile besides.
        boot_default="$(${coreutils}/readlink -f /nix/var/nix/profiles/system)"
        running="$(${coreutils}/readlink -f /run/current-system)"
        if [[ "$MODE" == "switch" && "$running" != "$boot_default" ]]; then
          refuse 65 "refused reason=test_generation_live running=$running boot_default=$boot_default"
        fi

        ${coreutils}/rm -f -- "$matching_record"
        old_path="$boot_default"
        journal "activation starting running=$running old=$old_path requested=$TARGET mode=$MODE approval_id=$approval_id"

        arm_watchdog() {
          local delay="$1"
          # Replace any older pending watchdog while holding the activation lock.
          ${systemctl} stop openclaw-nixos-rollback-watchdog.timer openclaw-nixos-rollback-watchdog.service >/dev/null 2>&1 || true
          ${systemctl} reset-failed openclaw-nixos-rollback-watchdog.service openclaw-nixos-rollback-watchdog.timer >/dev/null 2>&1 || true
          ${systemdRun} \
            --unit=openclaw-nixos-rollback-watchdog \
            --description='Rollback an unhealthy OpenClaw NixOS switch' \
            --on-active="''${delay}s" \
            --timer-property=AccuracySec=1s \
            --property=Type=oneshot \
            --collect \
            ${watchdogLogic}
        }

        if [[ "$MODE" == "switch" ]]; then
          failed_temp="$(${coreutils}/mktemp ${stateDir}/.failed-before.XXXXXX)"
          state_temp="$(${coreutils}/mktemp ${stateDir}/.watchdog.XXXXXX)"
          cleanup_arm() { ${coreutils}/rm -f -- "$failed_temp" "$state_temp"; }
          trap cleanup_arm EXIT

          ${systemctl} list-units --failed --no-legend --plain --no-pager |
            ${gawk} '{ print $1 }' | ${coreutils}/sort -u > "$failed_temp"
          ${jq} -n \
            --arg oldPath "$old_path" \
            --arg requestedPath "$TARGET" \
            --arg approvalId "$approval_id" \
            '{ oldPath: $oldPath, requestedPath: $requestedPath, approvalId: $approvalId }' \
            > "$state_temp"
          ${coreutils}/chmod 0600 "$failed_temp" "$state_temp"
          ${coreutils}/mv -f -- "$failed_temp" ${watchdogFailedBefore}
          ${coreutils}/mv -f -- "$state_temp" ${watchdogState}
          trap - EXIT

          if ! arm_watchdog ${toString activationWindowSeconds}; then
            ${coreutils}/rm -f -- ${watchdogState} ${watchdogFailedBefore}
            refuse 75 "activation refused reason=watchdog_arm_failed requested=$TARGET approval_id=$approval_id"
          fi
          journal "watchdog armed phase=activation requested=$TARGET previous=$old_path approval_id=$approval_id delay_seconds=${toString activationWindowSeconds}"
        fi

        set +e
        ${nh} os "$MODE" --elevation-strategy none --diff never --no-nom -R "$TARGET"
        status=$?
        set -e
        if (( status == 0 )); then
          journal "activation success old=$old_path requested=$TARGET mode=$MODE approval_id=$approval_id"
        else
          journal "activation failure status=$status old=$old_path requested=$TARGET mode=$MODE approval_id=$approval_id"
        fi

        # Re-arm so the verification window starts when activation RETURNS, not when
        # it began. A re-arm failure leaves no rollback timer pending, so it fails
        # loudly rather than silently open.
        if [[ "$MODE" == "switch" ]]; then
          if arm_watchdog ${toString verifyWindowSeconds}; then
            journal "watchdog armed phase=verify requested=$TARGET previous=$old_path approval_id=$approval_id delay_seconds=${toString verifyWindowSeconds}"
          else
            journal "refused reason=watchdog_rearm_failed requested=$TARGET approval_id=$approval_id no_rollback_timer_pending=true"
            exit 75
          fi
        fi

        exit "$status"
      '';

      confirmLogic = pkgs.writeShellScript "openclaw-nixos-confirm-logic" ''
        set -euo pipefail
        export PATH=${cleanPath}
        export LANG=C LC_ALL=C
        JOURNAL_TAG=openclaw-nixos-confirm
        source ${validationLibrary}

        if (( EUID != 0 )); then
          refuse 78 "refused reason=not_root"
        fi
        (( $# == 0 )) || refuse 64 "refused reason=unexpected_arguments"

        exec 9> ${lockFile}
        if ! ${flock} -w 300 9; then
          holder="$(lock_holder ${lockFile} 2>/dev/null || true)"
          [[ -n "$holder" ]] || holder=unknown
          refuse 75 "refused reason=lock_timeout holder_pid=$holder"
        fi

        ${systemctl} stop openclaw-nixos-rollback-watchdog.timer >/dev/null 2>&1 || true
        if [[ -f ${watchdogState} ]]; then
          requested_path="$(${jq} -r '.requestedPath // empty' ${watchdogState})"
          approval_id="$(${jq} -r '.approvalId // empty' ${watchdogState})"
          ${coreutils}/rm -f -- ${watchdogState} ${watchdogFailedBefore}
          journal "watchdog confirmed requested=$requested_path approval_id=$approval_id"
        else
          journal "watchdog confirm no_pending_switch"
        fi
      '';

      # The public commands are deliberately tiny. In particular, activate
      # always replaces its inherited environment before entering any logic.
      openclawNixosApprove = pkgs.writeShellScriptBin "openclaw-nixos-approve" ''
        exec ${coreutils}/env -i PATH=${cleanPath} LANG=C LC_ALL=C SUDO_UID="''${SUDO_UID:-0}" \
          ${bash} --noprofile --norc ${approveLogic} "$@"
      '';
      openclawNixosActivate = pkgs.writeShellScriptBin "openclaw-nixos-activate" ''
        exec ${coreutils}/env -i PATH=${cleanPath} LANG=C LC_ALL=C \
          ${bash} --noprofile --norc ${activateLogic} "$@"
      '';
      openclawNixosConfirm = pkgs.writeShellScriptBin "openclaw-nixos-confirm" ''
        exec ${coreutils}/env -i PATH=${cleanPath} LANG=C LC_ALL=C \
          ${bash} --noprofile --norc ${confirmLogic} "$@"
      '';
    in
    {
      environment.systemPackages = [
        openclawNixosApprove
        openclawNixosActivate
        openclawNixosConfirm
      ];

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 root root -"
        "d ${approvedDir} 0700 root root -"
        "f ${lockFile} 0600 root root -"
      ];

      # Deliberately no sudo argument pattern: sudo uses fnmatch across the
      # space-joined argv, where '*' also spans slashes and spaces. The root
      # wrappers above are the sole argument authority. Approval is omitted and
      # therefore continues to require the human's normal sudo authentication.
      security.sudo.extraRules = [
        {
          users = [ "tunnel" ];
          runAs = "root:root";
          commands = [
            {
              command = "/run/current-system/sw/bin/openclaw-nixos-activate";
              options = [ "NOPASSWD" ];
            }
            {
              command = "/run/current-system/sw/bin/openclaw-nixos-confirm";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
    };
}
