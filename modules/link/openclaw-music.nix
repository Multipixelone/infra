{
  inputs,
  lib,
  rootPath,
  withSystem,
  ...
}:
let
  streamrip-master-config = "/home/tunnel/.config/streamrip/config.toml";
  streamrip-runtime-root = "/volume1/Media/ImportMusic/Streamrip";
  streamrip-launcher-name = "openclaw-streamrip";
  makeStreamripLauncher =
    {
      pkgs,
      runtimeRoot,
      payload,
      name ? streamrip-launcher-name,
    }:
    let
      runtimeParents = lib.tail (
        lib.foldl' (parents: component: parents ++ [ "${lib.last parents}/${component}" ]) [ "" ] (
          lib.tail (lib.splitString "/" runtimeRoot)
        )
      );
      runtimeDirArgs = lib.concatMapStringsSep " " (
        path: "--dir ${lib.escapeShellArg path}"
      ) runtimeParents;
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.bubblewrap
        pkgs.coreutils
      ];
      text = ''
        set -euo pipefail
        runtime_root=${lib.escapeShellArg runtimeRoot}
        config=""
        operation=""
        case "$#:''${1-}" in
          10:--config-path)
            config=$2
            [[ $3 == search && $4 == --output-file && $6 == --num-results && $7 == 20 && $8 == qobuz && $9 == album ]]
            operation=search
            ;;
          11:--config-path)
            config=$2
            [[ $3 == --folder && $5 == --quality && $6 == 3 && $7 == --no-progress && $8 == id && $9 == qobuz && ''${10} == album ]]
            operation=download
            ;;
          *)
            exit 64
            ;;
        esac

        die() { exit 64; }
        uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        [[ $config =~ ^"$runtime_root"/($uuid)/config\.toml$ ]] || die
        job_id=''${BASH_REMATCH[1]}
        job_root="$runtime_root/$job_id"
        [[ $config == "$job_root/config.toml" ]] || die
        [[ -d $runtime_root && ! -L $runtime_root ]] || die
        [[ $(${pkgs.coreutils}/bin/realpath -e -- "$runtime_root") == "$runtime_root" ]] || die
        [[ -d $job_root && ! -L $job_root ]] || die
        [[ $(${pkgs.coreutils}/bin/realpath -e -- "$job_root") == "$job_root" ]] || die
        [[ -f $config && ! -L $config ]] || die
        [[ $(${pkgs.coreutils}/bin/realpath -e -- "$config") == "$config" ]] || die
        case "$operation" in
          search) [[ $5 == "$job_root/search.json" ]] || die ;;
          download) [[ $4 == "$job_root/output" ]] || die ;;
          *) die ;;
        esac

        dns_args=()
        for dns_file in /etc/resolv.conf /etc/hosts /etc/nsswitch.conf; do
          if [[ -e $dns_file ]]; then
            dns_args+=(--ro-bind "$dns_file" "$dns_file")
          fi
        done

        exec ${lib.getExe pkgs.bubblewrap} \
          --die-with-parent \
          --unshare-all --share-net \
          --ro-bind /nix/store /nix/store \
          --dir /home --dir /home/tunnel \
          --tmpfs /tmp \
          ${runtimeDirArgs} \
          --bind "$job_root" "$job_root" \
          --dir /etc \
          "''${dns_args[@]}" \
          --dev /dev --proc /proc \
          --setenv SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
          --chdir "$job_root" \
          -- ${lib.escapeShellArg payload} "$@"
      '';
    };
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        streamrip-launcher = makeStreamripLauncher {
          inherit pkgs;
          runtimeRoot = streamrip-runtime-root;
          payload = lib.getExe pkgs.streamrip;
        };
        probe-root = "/tmp/openclaw-music-streamrip-probe";
        probe-runtime-root = "${probe-root}/runtime";
        probe-job-id = "11111111-1111-1111-1111-111111111111";
        probe-sibling-id = "22222222-2222-2222-2222-222222222222";
        probe-symlink-id = "33333333-3333-3333-3333-333333333333";
        probe-config-symlink-id = "44444444-4444-4444-4444-444444444444";
        probe-payload = pkgs.writeShellScript "openclaw-music-streamrip-probe-payload" ''
          set -euo pipefail
          runtime_root=${lib.escapeShellArg probe-runtime-root}
          job_id=${lib.escapeShellArg probe-job-id}
          sibling_id=${lib.escapeShellArg probe-sibling-id}
          job_root="$runtime_root/$job_id"
          case "$#:''${1-}" in
            10:--config-path)
              [[ $2 == "$job_root/config.toml" && $3 == search && $4 == --output-file && $5 == "$job_root/search.json" && $6 == --num-results && $7 == 20 && $8 == qobuz && $9 == album ]]
              marker=''${10}
              printf '%s\n' '[]' > "$job_root/search.json"
              ;;
            11:--config-path)
              [[ $2 == "$job_root/config.toml" && $3 == --folder && $4 == "$job_root/output" && $5 == --quality && $6 == 3 && $7 == --no-progress && $8 == id && $9 == qobuz && ''${10} == album ]]
              marker=''${11}
              touch "$job_root/output/payload-output"
              ;;
            *) exit 97 ;;
          esac
          [[ $PWD == "$job_root" && -f "$job_root/config.toml" && ! -L "$job_root/config.toml" ]]
          touch "$job_root/payload-writable"
          for absent in \
            "$runtime_root/$sibling_id" \
            ${lib.escapeShellArg "${probe-root}/master"} \
            ${lib.escapeShellArg "${probe-root}/library"} \
            ${lib.escapeShellArg "${probe-root}/beets"} \
            ${lib.escapeShellArg "${probe-root}/ledger"} \
            ${lib.escapeShellArg "${probe-root}/host-fixture"} \
            /home/tunnel/.ssh \
            /unrelated-host-fixture; do
            [[ ! -e $absent ]]
          done
          if [[ $marker == complete ]]; then
            touch "$job_root/success"
            exit 0
          fi
          ${pkgs.bash}/bin/bash -c 'while :; do ${pkgs.coreutils}/bin/sleep 1; done' "$marker" &
          child=$!
          printf '%s\n' "$child" > "$job_root/payload.pid"
          touch "$job_root/ready"
          wait "$child"
        '';
        probe-launcher = makeStreamripLauncher {
          inherit pkgs;
          runtimeRoot = probe-runtime-root;
          payload = probe-payload;
          name = "openclaw-streamrip-probe-launcher";
        };
      in
      {
        packages.openclaw-music = pkgs.python3Packages.callPackage "${rootPath}/pkgs/openclaw-music" { };
        packages.openclaw-music-streamrip-launcher = streamrip-launcher;
        packages.openclaw-music-streamrip-confinement-probe = pkgs.writeShellApplication {
          name = "openclaw-music-streamrip-confinement-probe";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.procps
            pkgs.util-linux
          ];
          text = ''
            set -euo pipefail
            root=${lib.escapeShellArg probe-root}
            runtime_root=${lib.escapeShellArg probe-runtime-root}
            job_id=${lib.escapeShellArg probe-job-id}
            sibling_id=${lib.escapeShellArg probe-sibling-id}
            symlink_id=${lib.escapeShellArg probe-symlink-id}
            config_symlink_id=${lib.escapeShellArg probe-config-symlink-id}
            job_root="$runtime_root/$job_id"
            sibling_root="$runtime_root/$sibling_id"
            config_symlink_root="$runtime_root/$config_symlink_id"
            launcher=${lib.getExe probe-launcher}
            mode="''${1-}"
            owned_root=0
            group=""
            parent_group=""
            wrapper=""
            cleanup_marker=""
            terminate_active() {
              signal=$1
              for handle in "$group" "$parent_group"; do
                [[ -n $handle ]] && kill -"$signal" -- "-$handle" 2>/dev/null || :
              done
              [[ -n $wrapper ]] && kill -"$signal" "$wrapper" 2>/dev/null || :
            }
            cleanup() {
              status=$?
              trap - EXIT INT TERM
              terminate_active TERM
              if [[ -n $cleanup_marker ]] && ! no_marker_survivor "$cleanup_marker"; then
                terminate_active KILL
                if ! no_marker_survivor "$cleanup_marker"; then
                  printf '%s\n' "emergency cleanup left a probe survivor" >&2
                fi
              fi
              if (( owned_root )); then rm -rf -- "$root"; fi
              exit "$status"
            }
            acquire_root() {
              [[ ! -e $root && ! -L $root ]] || return 1
              mkdir -m 0700 "$root" || return 1
              owned_root=1
              trap cleanup EXIT INT TERM
            }
            await_file() {
              path=$1
              for _ in $(seq 1 100); do
                [[ -e $path ]] && return 0
                ${pkgs.coreutils}/bin/sleep 0.02
              done
              return 1
            }
            await_marker() {
              marker=$1
              for _ in $(seq 1 100); do
                ${pkgs.procps}/bin/pgrep -f -- "$marker" >/dev/null && return 0
                ${pkgs.coreutils}/bin/sleep 0.02
              done
              return 1
            }
            no_marker_survivor() {
              marker=$1
              for _ in $(seq 1 100); do
                ! ${pkgs.procps}/bin/pgrep -f -- "$marker" >/dev/null && return 0
                ${pkgs.coreutils}/bin/sleep 0.02
              done
              return 1
            }
            expect_signal_exit() {
              pid=$1
              if wait "$pid"; then
                return 1
              else
                status=$?
              fi
              [[ $status -ge 128 && $status -le 192 ]]
            }
            reject() {
              if "$@"; then
                return 1
              else
                status=$?
              fi
              [[ $status == 64 ]]
            }

            case "$mode" in
              ""|--ownership-regression|--cleanup-regression) ;;
              *) exit 64 ;;
            esac
            acquire_root || exit 64
            if [[ $mode == --ownership-regression ]]; then
              printf '%s\n' sentinel > "$root/ownership-sentinel"
              if "$0"; then
                exit 1
              else
                status=$?
              fi
              [[ $status == 64 && $(<"$root/ownership-sentinel") == sentinel ]]
              exit 0
            fi
            if [[ $mode == --cleanup-regression ]]; then
              cleanup_marker="openclaw-streamrip-emergency-$$"
              ${pkgs.util-linux}/bin/setsid ${pkgs.bash}/bin/bash -c 'while :; do ${pkgs.coreutils}/bin/sleep 1; done' "$cleanup_marker" &
              group=$!
              await_marker "$cleanup_marker"
              false
            fi

            mkdir -p "$job_root/output" "$sibling_root" "$config_symlink_root/output" "$root/master" "$root/library" "$root/beets" "$root/ledger" "$root/host-fixture"
            chmod 0700 "$runtime_root" "$job_root" "$job_root/output" "$sibling_root" "$config_symlink_root" "$config_symlink_root/output" "$root/master" "$root/library" "$root/beets" "$root/ledger" "$root/host-fixture"
            printf '%s\n' '[qobuz]' > "$job_root/config.toml"
            chmod 0600 "$job_root/config.toml"
            ln -s "$job_root" "$runtime_root/$symlink_id"
            ln -s "$job_root/config.toml" "$config_symlink_root/config.toml"

            "$launcher" --config-path "$job_root/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album complete
            [[ -e "$job_root/success" && -e "$job_root/payload-writable" && -f "$job_root/search.json" ]]
            "$launcher" --config-path "$job_root/config.toml" --folder "$job_root/output" --quality 3 --no-progress id qobuz album complete
            [[ -e "$job_root/output/payload-output" ]]
            reject "$launcher" --config-path "" search --output-file "$job_root/search.json" --num-results 20 qobuz album rejected-empty
            reject "$launcher" --config-path "$runtime_root/./$job_id/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album rejected-dot
            reject "$launcher" --config-path "$runtime_root//$job_id/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album rejected-double
            reject "$launcher" --config-path "$runtime_root/$job_id/nested/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album rejected-nested
            reject "$launcher" --config-path "$runtime_root/11111111-1111-1111-1111-11111111111A/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album rejected-uppercase
            reject "$launcher" --config-path "$runtime_root/$symlink_id/config.toml" search --output-file "$runtime_root/$symlink_id/search.json" --num-results 20 qobuz album rejected-symlink
            reject "$launcher" --config-path "$config_symlink_root/config.toml" search --output-file "$config_symlink_root/search.json" --num-results 20 qobuz album rejected-config-symlink
            reject "$launcher" --config-path "$job_root/config.toml" search --output-file "$sibling_root/search.json" --num-results 20 qobuz album rejected-mixed

            marker="openclaw-streamrip-group-$$"
            cleanup_marker=$marker
            rm -f "$job_root/ready" "$job_root/payload.pid"
            ${pkgs.util-linux}/bin/setsid "$launcher" --config-path "$job_root/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album "$marker" &
            group=$!
            await_file "$job_root/ready"
            kill -TERM -- "-$group"
            expect_signal_exit "$group"
            no_marker_survivor "$marker"
            group=""
            cleanup_marker=""

            marker="openclaw-streamrip-parent-$$"
            cleanup_marker=$marker
            rm -f "$job_root/ready" "$job_root/payload.pid"
            # shellcheck disable=SC2016
            ${pkgs.util-linux}/bin/setsid ${pkgs.bash}/bin/bash -c 'set -euo pipefail; "$@" & child=$!; wait "$child"' -- "$launcher" --config-path "$job_root/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album "$marker" &
            wrapper=$!
            parent_group=$wrapper
            await_file "$job_root/ready"
            kill -TERM "$wrapper"
            expect_signal_exit "$wrapper"
            no_marker_survivor "$marker"
            wrapper=""
            parent_group=""
            cleanup_marker=""

            mv "$runtime_root" "$root/runtime-real"
            ln -s "$root/runtime-real" "$runtime_root"
            reject "$launcher" --config-path "$job_root/config.toml" search --output-file "$job_root/search.json" --num-results 20 qobuz album rejected-runtime-symlink
          '';
        };

        checks.openclaw-music-streamrip-loader = pkgs.runCommand "openclaw-music-streamrip-loader" { } ''
          work="$TMPDIR/streamrip"
          mkdir -p "$work"
          cat > "$work/master.toml" <<'EOF'
          [qobuz]
          use_auth_token = true
          email_or_userid = "dummy"
          password_or_token = "dummy-token"
          EOF
          HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" ${pkgs.python3}/bin/python - "${pkgs.streamrip}/bin/.rip-wrapped" "$work" <<'PY'
          import pathlib
          import sys

          wrapper, root = map(pathlib.Path, sys.argv[1:])
          prefix = wrapper.read_text().split("import re\n", 1)[0]
          exec(compile(prefix, str(wrapper), "exec"), {"__name__": "streamrip_loader"})
          sys.path.insert(0, "${rootPath}/pkgs/openclaw-music")
          from openclaw_music.streamrip import StreamripAdapter
          from streamrip.config import Config

          master = root / "master.toml"
          before = master.read_bytes()
          adapter = StreamripAdapter("/nix/store/launcher", str(master), str(root / "runtime"))
          runtime = adapter.runtime("00000000-0000-0000-0000-000000000001")
          adapter.write_config(runtime)
          parsed = Config(runtime["config"]).file
          assert parsed.qobuz.use_auth_token and parsed.qobuz.quality == 3
          assert parsed.qobuz.download_booklets is False and parsed.qobuz.secrets == []
          assert parsed.conversion.enabled is False and parsed.downloads.verify_ssl is True
          assert parsed.database.downloads_enabled and parsed.database.failed_downloads_enabled
          assert parsed.database.downloads_path == runtime["downloads_db"]
          assert parsed.database.failed_downloads_path == runtime["failed_downloads_db"]
          assert parsed.downloads.concurrency is True and parsed.downloads.max_connections == 2
          assert parsed.downloads.requests_per_minute == 30
          assert parsed.cli.progress_bars is False and parsed.cli.text_output is False
          assert parsed.artwork.embed is False and parsed.artwork.save_artwork is False
          assert parsed.misc.check_for_updates is False
          assert not parsed.tidal.access_token and not parsed.deezer.arl and not parsed.soundcloud.client_id
          assert not parsed.youtube.video_downloads_folder and parsed.lastfm.source == "qobuz"
          assert master.read_bytes() == before
          PY
          touch "$out"
        '';

        checks.openclaw-music-streamrip-launcher-contract =
          pkgs.runCommand "openclaw-music-streamrip-launcher-contract" { }
            ''
              launcher=${streamrip-launcher}/bin/${streamrip-launcher-name}
              grep -F -- "uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'" "$launcher"
              grep -F -- 'job_root="$runtime_root/$job_id"' "$launcher"
              grep -F -- '[[ $config == "$job_root/config.toml" ]] || die' "$launcher"
              grep -F -- '[[ $5 == "$job_root/search.json" ]] || die' "$launcher"
              grep -F -- '[[ $4 == "$job_root/output" ]] || die' "$launcher"
              grep -F -- '${pkgs.coreutils}/bin/realpath -e -- "$runtime_root"' "$launcher"
              grep -F -- '${pkgs.coreutils}/bin/realpath -e -- "$job_root"' "$launcher"
              grep -F -- '--bind "$job_root" "$job_root"' "$launcher"
              ! grep -F -- '--bind "$runtime_root" "$runtime_root"' "$launcher"
              touch "$out"
            '';
      }
    );

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      ledger-root = "/home/tunnel/.local/state/openclaw-music";
      staging-root = "/volume1/Media/ImportMusic/OpenClaw";
      download-root = "/volume1/Media/ImportMusic/slskd";
      batch-root = "${download-root}/openclaw";
      library-root = "/volume1/Media/Music";
      beets-dir = "/home/tunnel/.config/beets";
      beets-config = "${beets-dir}/config.yaml";
      beets-lock = "${beets-dir}/.import.lock";
      beets-cache = "/home/tunnel/.cache/openclaw-music-beets";
      streamrip-launcher = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.openclaw-music-streamrip-launcher
      );
      slskd-url = "http://127.0.0.1:5030";
      package = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.openclaw-music
      );
      beets-plugins = inputs.beets-plugins.packages.${pkgs.stdenv.hostPlatform.system}.default;
      beets-path =
        lib.makeBinPath [
          beets-plugins
          pkgs.ffmpeg-full
          pkgs.coreutils
          pkgs.findutils
          pkgs.util-linux
        ]
        + ":/etc/profiles/per-user/tunnel/bin:/run/current-system/sw/bin";
      nonOverlapping = a: b: a != b && !(lib.hasPrefix "${a}/" b) && !(lib.hasPrefix "${b}/" a);
      openclaw-music = pkgs.writeShellApplication {
        name = "openclaw-music";
        text = ''
          # TRANSPORT_ISOLATED also relies on pinned Explo moving only transfers it queued.
          exec ${pkgs.coreutils}/bin/env -i \
            HOME=/home/tunnel PATH=${beets-path} LANG=C LC_ALL=C \
            BEETSDIR=${beets-dir} XDG_CONFIG_HOME=/home/tunnel/.config XDG_CACHE_HOME=${beets-cache} \
            OPENCLAW_MUSIC_LEDGER=${ledger-root} \
            OPENCLAW_MUSIC_STAGING=${staging-root} \
            OPENCLAW_MUSIC_DOWNLOAD_ROOT=${download-root} \
            OPENCLAW_MUSIC_MB_USER_AGENT='openclaw-music/1.0 (https://github.com/Multipixelone/infra)' \
            OPENCLAW_MUSIC_SLSKD_URL=${slskd-url} \
            OPENCLAW_MUSIC_SLSKD_SECRET=${config.age.secrets.slskd.path} \
            OPENCLAW_MUSIC_FFPROBE=${lib.getExe' pkgs.ffmpeg-full "ffprobe"} \
            OPENCLAW_MUSIC_FFMPEG=${lib.getExe' pkgs.ffmpeg-full "ffmpeg"} \
            OPENCLAW_MUSIC_TRANSPORT_ISOLATED=1 OPENCLAW_MUSIC_QUALITY_DEFAULT=lossless-preferred \
            OPENCLAW_MUSIC_LIBRARY_ROOT=${library-root} OPENCLAW_MUSIC_BEETS=${lib.getExe beets-plugins} \
            OPENCLAW_MUSIC_BEETS_CONFIG=${beets-config} OPENCLAW_MUSIC_BEETS_LOCK=${beets-lock} \
            OPENCLAW_MUSIC_BEETS_HOME=/home/tunnel OPENCLAW_MUSIC_BEETS_PATH=${beets-path} \
            OPENCLAW_MUSIC_BEETS_CACHE=${beets-cache} OPENCLAW_MUSIC_INDEX_ADAPTER=beets-mpdupdate \
            OPENCLAW_MUSIC_STREAMRIP_LAUNCHER=${lib.getExe streamrip-launcher} \
            OPENCLAW_MUSIC_STREAMRIP_MASTER_CONFIG=${streamrip-master-config} \
            OPENCLAW_MUSIC_STREAMRIP_RUNTIME_ROOT=${streamrip-runtime-root} \
            ${lib.getExe package} "$@"
        '';
      };
      worker = pkgs.writeShellScript "openclaw-music-worker" ''
        printf '%s\n' '{"schema":1}' | ${lib.getExe openclaw-music} worker
      '';
    in
    {
      assertions = [
        {
          assertion =
            nonOverlapping staging-root download-root
            && nonOverlapping staging-root library-root
            && nonOverlapping download-root library-root;
          message = "openclaw-music staging, slskd download, and library paths must not overlap";
        }
        {
          assertion = slskd-url == "http://127.0.0.1:5030";
          message = "openclaw-music slskd URL must remain loopback";
        }
        {
          assertion = lib.hasPrefix "${download-root}/" batch-root;
          message = "openclaw-music batch subtree must stay under the slskd download root";
        }
        {
          assertion = beets-lock != ledger-root && beets-lock != staging-root;
          message = "openclaw-music beets lock must not overlap worker state or staging";
        }
        {
          assertion =
            lib.all (path: lib.hasPrefix "/" path) [
              (lib.getExe streamrip-launcher)
              streamrip-master-config
              streamrip-runtime-root
            ]
            && lib.all (path: nonOverlapping streamrip-runtime-root path) [
              ledger-root
              staging-root
              library-root
              download-root
              streamrip-master-config
            ];
          message = "openclaw-music Streamrip launcher, master config, and private runtime must be absolute and isolated";
        }
      ];

      systemd.tmpfiles.rules = [
        "d ${ledger-root} 0700 tunnel users -"
        "d ${staging-root} 0700 tunnel users -"
        "d ${batch-root} 0700 tunnel users -"
        "d ${beets-cache} 0700 tunnel users -"
        "d ${streamrip-runtime-root} 0700 tunnel users -"
      ];

      home-manager.users.tunnel = {
        home.packages = [ openclaw-music ];
        systemd.user = {
          services.openclaw-music-worker = {
            Unit = {
              Description = "Process one serialized OpenClaw music job";
              After = [ "network-online.target" ];
            };
            Service = {
              Type = "oneshot";
              ExecStart = worker;
              UMask = "0077";
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = "read-only";
              ReadOnlyPaths = [
                download-root
                config.age.secrets.slskd.path
                "-${streamrip-master-config}"
              ];
              ReadWritePaths = [
                ledger-root
                staging-root
                library-root
                beets-dir
                beets-cache
                streamrip-runtime-root
              ];
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
              StandardOutput = "journal";
              StandardError = "journal";
            };
          };
          timers.openclaw-music-worker = {
            Unit.Description = "Schedule serialized OpenClaw music work";
            Timer = {
              OnBootSec = "1m";
              OnUnitInactiveSec = "12s";
              Persistent = true;
            };
            Install.WantedBy = [ "timers.target" ];
          };
        };
      };
    };
}
