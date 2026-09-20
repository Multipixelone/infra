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
  flake-file.inputs.streamrip = {
    url = "github:mikelandzelo173/streamrip/feat/qobuz-login-fix";
    flake = false;
  };
  nixpkgs.overlays = [
    (_final: prev: {
      streamrip = prev.streamrip.overrideAttrs {
        src = inputs.streamrip;
        version = inputs.streamrip.rev;

        propagatedBuildInputs = prev.streamrip.propagatedBuildInputs ++ [
          prev.python3Packages.playwright
        ];
      };
    })
  ];

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
    { pkgs, ... }:
    let
      launcher = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.openclaw-music-streamrip-launcher
      );
      masterConfig = streamrip-master-config;
      runtimeRoot = streamrip-runtime-root;
    in
    {
      _module.args.openclawMusicStreamrip = {
        inherit launcher masterConfig runtimeRoot;
      };
      systemd.tmpfiles.rules = [
        "d ${runtimeRoot} 0700 tunnel users -"
      ];
      assertions = [
        {
          assertion = lib.all (path: lib.hasPrefix "/" path) [
            (lib.getExe launcher)
            masterConfig
            runtimeRoot
          ];
          message = "openclaw-music Streamrip launcher, master config, and private runtime must be absolute";
        }
      ];
    };

  flake.modules.homeManager.media =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      # Keys we want to enforce; everything else (auth tokens, etc.) is left
      # alone so streamrip can keep writing to the same file.
      managedConfig = {
        downloads = {
          folder = "${config.xdg.userDirs.music}/StreamripDownloads";
          source_subdirectories = false;
          disc_subdirectories = true;
          concurrency = true;
          max_connections = 2;
          requests_per_minute = 30;
          verify_ssl = true;
        };
        qobuz = {
          quality = 3;
        };
        database = {
          failed_downloads_enabled = true;
          failed_downloads_path = "${config.xdg.configHome}/streamrip/failed_downloads.db";
        };
        misc = {
          version = "2.2.0";
        };
      };

      mergeConfig =
        pkgs.writers.writePython3Bin "streamrip-merge-config"
          {
            flakeIgnore = [ "E501" ];
            libraries = [ pkgs.python3Packages.tomlkit ];
          }
          ''
            import json
            import pathlib
            import sys

            import tomlkit


            def deep_merge(dst, src):
                for key, value in src.items():
                    if isinstance(value, dict):
                        cur = dst.get(key)
                        if cur is None or not hasattr(cur, "items"):
                            dst[key] = tomlkit.table()
                            cur = dst[key]
                        deep_merge(cur, value)
                    else:
                        dst[key] = value


            managed = json.loads(sys.argv[1])
            cfg = pathlib.Path(sys.argv[2])

            if cfg.is_symlink():
                cfg.unlink()

            if cfg.exists():
                old = cfg.read_text(encoding="utf-8")
                doc = tomlkit.parse(old)
            else:
                old = None
                doc = tomlkit.document()

            deep_merge(doc, managed)
            new = tomlkit.dumps(doc)

            if new != old:
                cfg.parent.mkdir(parents=True, exist_ok=True)
                tmp = cfg.with_suffix(cfg.suffix + ".tmp")
                tmp.write_text(new, encoding="utf-8")
                tmp.replace(cfg)
          '';
      streamrip-qobuz-preflight-script = pkgs.writeText "streamrip-qobuz-preflight.py" ''
        import argparse
        import asyncio
        import inspect
        import json
        import os
        import re
        import sqlite3
        import sys
        import tempfile
        from pathlib import Path

        from streamrip.client.qobuz import QobuzClient
        from streamrip.config import Config
        from streamrip.exceptions import NonStreamableError


        STALE_MARKER = "No result matching given argument"


        def parse_args():
            parser = argparse.ArgumentParser()
            parser.add_argument("--config", required=True)
            parser.add_argument("--input", required=True)
            parser.add_argument("--valid", required=True)
            parser.add_argument("--rejected", required=True)
            parser.add_argument("--pending", required=True)
            parser.add_argument("--status", required=True)
            # Test-only dependency injection for the offline behavior check.
            parser.add_argument("--test-outcomes")
            parser.add_argument("--test-db")
            parser.add_argument("--test-downloads-enabled", choices=("true", "false"))
            return parser.parse_args()


        def load_manifest(path):
            try:
                records = json.loads(Path(path).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValueError("input manifest is not valid JSON") from exc
            if not isinstance(records, list) or not records:
                raise ValueError("input manifest must be a nonempty array")
            ids = set()
            for record in records:
                if (
                    not isinstance(record, dict)
                    or set(record) != {"source", "media_type", "id"}
                    or record["source"] != "qobuz"
                    or record["media_type"] != "album"
                    or not isinstance(record["id"], str)
                    or not record["id"]
                    or record["id"] in ids
                ):
                    raise ValueError("input manifest has an invalid or duplicate album record")
                ids.add(record["id"])
            return records


        def write_json_atomic(path, value):
            target = Path(path)
            fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as output:
                    json.dump(value, output, separators=(",", ":"))
                    output.write("\n")
                os.replace(tmp, target)
            except BaseException:
                try:
                    os.unlink(tmp)
                except FileNotFoundError:
                    pass
                raise


        def diagnostic(album_id, exc):
            reason = re.sub(r"[\x00-\x1f\x7f]+", " ", str(exc)).strip()[:200]
            print(
                f"streamrip-qobuz-preflight: album {album_id}: {type(exc).__name__}: {reason}",
                file=sys.stderr,
            )


        class TestClient:
            def __init__(self, outcomes):
                self.outcomes = outcomes
                self.session = None

            async def login(self):
                return True

            async def get_metadata(self, album_id, media_type):
                values = self.outcomes.get(album_id)
                if not isinstance(values, list) or not values:
                    raise RuntimeError("missing test outcome")
                outcome = values.pop(0)
                if isinstance(outcome, dict):
                    return outcome
                if outcome == "stale":
                    raise NonStreamableError(f"Error fetching metadata. Message: {STALE_MARKER!r}")
                if outcome == "other-nonstreamable":
                    raise NonStreamableError("Error fetching metadata. Message: 'temporary provider error'")
                if outcome == "malformed":
                    return []
                raise RuntimeError(str(outcome))


        async def close_client(client):
            session = getattr(client, "session", None)
            if session is not None and not getattr(session, "closed", True):
                result = session.close()
                if inspect.isawaitable(result):
                    await result


        async def preflight(records, args):
            if args.test_outcomes:
                try:
                    outcomes = json.loads(Path(args.test_outcomes).read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as exc:
                    raise ValueError("test outcomes are not valid JSON") from exc
                client = TestClient(outcomes)
                downloads_enabled = args.test_downloads_enabled != "false"
                downloads_path = args.test_db
            else:
                config = Config(args.config)
                client = QobuzClient(config)
                downloads_enabled = config.session.database.downloads_enabled
                downloads_path = config.session.database.downloads_path

            try:
                logged_in = await client.login()
                if logged_in is False:
                    raise RuntimeError("Qobuz login failed")
                valid = []
                rejected = []
                for record in records:
                    album_id = record["id"]
                    try:
                        metadata = await client.get_metadata(album_id, "album")
                    except NonStreamableError as first_error:
                        if STALE_MARKER not in str(first_error):
                            diagnostic(album_id, first_error)
                            raise RuntimeError("metadata request was not safely classifiable") from first_error
                        await asyncio.sleep(1)
                        try:
                            metadata = await client.get_metadata(album_id, "album")
                        except NonStreamableError as second_error:
                            if STALE_MARKER in str(second_error):
                                rejected.append({
                                    **record,
                                    "reason": "No result matching given argument",
                                    "attempts": 2,
                                })
                                continue
                            diagnostic(album_id, second_error)
                            raise RuntimeError("metadata retry was not safely classifiable") from second_error
                        except Exception as exc:
                            diagnostic(album_id, exc)
                            raise RuntimeError("metadata retry failed") from exc
                    except Exception as exc:
                        diagnostic(album_id, exc)
                        raise RuntimeError("metadata request failed") from exc
                    if not isinstance(metadata, dict):
                        raise RuntimeError(f"album {album_id}: malformed metadata response")
                    tracks = metadata.get("tracks")
                    if not isinstance(tracks, dict) or not isinstance(tracks.get("items"), list) or not tracks["items"]:
                        raise RuntimeError(f"album {album_id}: malformed track metadata")
                    track_ids = []
                    for track in tracks["items"]:
                        if not isinstance(track, dict) or "id" not in track or isinstance(track["id"], bool):
                            raise RuntimeError(f"album {album_id}: malformed track ID")
                        track_id = str(track["id"])
                        if not track_id or track_id in track_ids:
                            raise RuntimeError(f"album {album_id}: invalid or duplicate track ID")
                        track_ids.append(track_id)
                    tracks_count = metadata.get("tracks_count")
                    if tracks_count is not None:
                        if isinstance(tracks_count, bool) or not isinstance(tracks_count, (int, str)):
                            raise RuntimeError(f"album {album_id}: malformed tracks_count")
                        try:
                            expected_count = int(tracks_count)
                        except ValueError as exc:
                            raise RuntimeError(f"album {album_id}: malformed tracks_count") from exc
                        if expected_count != len(track_ids):
                            raise RuntimeError(f"album {album_id}: incomplete track metadata")
                    valid.append((record, metadata, track_ids))
                return valid, rejected, downloads_enabled, downloads_path
            finally:
                await close_client(client)


        def main():
            args = parse_args()
            try:
                records = load_manifest(args.input)
                valid_with_metadata, rejected, downloads_enabled, downloads_path = asyncio.run(preflight(records, args))
                downloaded = set()
                if downloads_enabled and downloads_path and Path(downloads_path).exists():
                    connection = sqlite3.connect(f"file:{Path(downloads_path).resolve()}?mode=ro", uri=True)
                    try:
                        columns = {row[1] for row in connection.execute("PRAGMA table_info(downloads)")}
                        if columns != {"id"}:
                            raise RuntimeError("downloads database has an unexpected schema")
                        downloaded = {str(row[0]) for row in connection.execute("SELECT id FROM downloads")}
                    finally:
                        connection.close()
                valid = []
                pending = []
                status = []
                for record, metadata, track_ids in valid_with_metadata:
                    missing = track_ids if not downloads_enabled else [track_id for track_id in track_ids if track_id not in downloaded]
                    complete = downloads_enabled and not missing
                    artist = metadata.get("artist", {}).get("name", "Unknown artist") if isinstance(metadata.get("artist"), dict) else "Unknown artist"
                    title = metadata.get("title", "Unknown album")
                    status.append({
                        "id": record["id"], "artist": re.sub(r"[\x00-\x1f\x7f]+", " ", str(artist)).strip(),
                        "title": re.sub(r"[\x00-\x1f\x7f]+", " ", str(title)).strip(),
                        "total_tracks": len(track_ids), "downloaded_tracks": len(track_ids) - len(missing),
                        "missing_tracks": len(missing), "missing_track_ids": missing,
                        "complete": complete,
                        "state": "complete" if complete else ("unknown" if not downloads_enabled else "incomplete"),
                        "reason": None if downloads_enabled else "Streamrip downloads database is disabled",
                    })
                    valid.append(record)
                    if not complete:
                        pending.append(record)
            except Exception as exc:
                print(f"streamrip-qobuz-preflight: {type(exc).__name__}: {exc}", file=sys.stderr)
                return 1
            write_json_atomic(args.valid, valid)
            write_json_atomic(args.rejected, rejected)
            write_json_atomic(args.pending, pending)
            write_json_atomic(args.status, status)
            return 0


        if __name__ == "__main__":
            raise SystemExit(main())
      '';
      streamrip-qobuz-preflight = pkgs.writeShellApplication {
        name = "streamrip-qobuz-preflight";
        text = ''
          exec ${lib.getExe pkgs.python3} - ${pkgs.streamrip}/bin/.rip-wrapped ${streamrip-qobuz-preflight-script} "$@" <<'PY'
          import pathlib
          import runpy
          import sys

          wrapper, helper = map(pathlib.Path, sys.argv[1:3])
          prefix = wrapper.read_text().split("import re\n", 1)[0]
          exec(compile(prefix, str(wrapper), "exec"), {"__name__": "streamrip_loader"})
          sys.argv = [str(helper), *sys.argv[3:]]
          runpy.run_path(str(helper), run_name="__main__")
          PY
        '';
      };
      beets-library-inventory-script = pkgs.writeText "beets-library-inventory.py" ''
        import argparse, json, os, re, subprocess, sys, tempfile, unicodedata
        from pathlib import Path

        def norm(value):
            value = unicodedata.normalize("NFKD", value)
            value = "".join(char for char in value if not unicodedata.combining(char)).casefold()
            value = value.replace("&", " and ")
            return " ".join(re.sub(r"[\W_]+", " ", value).split())

        def artist_equal(left, right):
            def no_the(value):
                return value[4:] if value.startswith("the ") else value
            return norm(left) == norm(right) or no_the(norm(left)) == no_the(norm(right))

        def stage(path, value):
            target = Path(path)
            fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as output:
                    json.dump(value, output, separators=(",", ":")); output.write("\n")
                return tmp, target
            except BaseException:
                try: os.unlink(tmp)
                except FileNotFoundError: pass
                raise

        parser = argparse.ArgumentParser()
        parser.add_argument("--beet", required=True)
        parser.add_argument("--config", required=True)
        parser.add_argument("--database", required=True)
        parser.add_argument("--input", required=True)
        parser.add_argument("--missing", required=True)
        parser.add_argument("--owned", required=True)
        args = parser.parse_args()
        try:
            records = json.loads(Path(args.input).read_text(encoding="utf-8"))
            if not isinstance(records, list): raise ValueError("input must be an array")
            seen = set()
            for record in records:
                if not isinstance(record, dict) or set(record) != {"spotify_id", "artist", "name", "spotify_url"} or not all(isinstance(record[key], str) and record[key] for key in record) or record["spotify_id"] in seen:
                    raise ValueError("input has an invalid or duplicate Spotify album")
                seen.add(record["spotify_id"])
            environment = os.environ.copy()
            environment.update({"HOME": "/home/tunnel", "LANG": "C", "LC_ALL": "C", "BEETSDIR": "/home/tunnel/.config/beets", "XDG_CONFIG_HOME": "/home/tunnel/.config", "XDG_CACHE_HOME": "/home/tunnel/.cache/beets"})
            result = subprocess.run([args.beet, "-c", args.config, "-l", args.database, "list", "-a", "-f", "$albumartist\x1f$album\x1f$id"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, check=False)
            if result.returncode:
                detail = re.sub(r"[\x00-\x1f\x7f]+", " ", result.stderr).strip()[:240]
                raise RuntimeError(f"beet list failed: {detail or 'no diagnostic'}")
            inventory = []
            for line in result.stdout.splitlines():
                if not line:
                    continue
                fields = line.split("\x1f")
                if len(fields) != 3 or not all(fields):
                    raise RuntimeError("beet list returned malformed inventory output")
                inventory.append((fields[2], fields[0], fields[1]))
            inventory.sort(key=lambda row: row[0])
            missing, owned = [], []
            for record in records:
                candidates = [row for row in inventory if norm(record["name"]) == norm(row[2] or "") and artist_equal(record["artist"], row[1] or "")]
                if not candidates:
                    missing.append(record); continue
                album_id, albumartist, album = candidates[0]
                owned.append({"spotify_id": record["spotify_id"], "artist": record["artist"], "album": record["name"], "spotify_url": record["spotify_url"], "beets_album_id": str(album_id), "beets_albumartist": albumartist, "beets_album": album, "candidate_count": len(candidates), "match_method": "normalized_albumartist_album"})
            missing_tmp, missing_target = stage(args.missing, missing)
            owned_tmp, owned_target = stage(args.owned, owned)
            try:
                os.replace(missing_tmp, missing_target)
                os.replace(owned_tmp, owned_target)
            except BaseException:
                for tmp in (missing_tmp, owned_tmp):
                    try: os.unlink(tmp)
                    except FileNotFoundError: pass
                raise
        except Exception as exc:
            print(f"beets-library-inventory: {type(exc).__name__}: {exc}", file=sys.stderr)
            raise SystemExit(1)
      '';
      beets-library-inventory = pkgs.writeShellApplication {
        name = "beets-library-inventory";
        text = ''
          exec ${lib.getExe pkgs.python3} ${beets-library-inventory-script} "$@"
        '';
      };
      spotify-qobuz-albums-inner = pkgs.writers.writeFishBin "spotify-qobuz-albums-inner" ''
        set -l curl ${lib.getExe pkgs.curl}
        set -l jq ${lib.getExe pkgs.jq}
        set -l mktemp ${lib.getExe' pkgs.coreutils "mktemp"}
        set -l chmod ${lib.getExe' pkgs.coreutils "chmod"}
        set -l rm ${lib.getExe' pkgs.coreutils "rm"}
        set -l mv ${lib.getExe' pkgs.coreutils "mv"}
        set -l rip ${lib.getExe pkgs.streamrip}
        set -l preflight ${lib.getExe streamrip-qobuz-preflight}
        set -l beets_inventory ${lib.getExe beets-library-inventory}
        set -l beet ${lib.getExe config.programs.beets.package}
        set -l beets_config /home/tunnel/.config/beets/config.yaml
        set -l beets_database /home/tunnel/.config/beets/library.db
        set -l streamrip_config ${lib.escapeShellArg "${config.xdg.configHome}/streamrip/config.toml"}

        function usage
          printf '%s\n' 'Usage: spotify-qobuz-albums [--output FILE] [--no-download] [--retry-existing] [--yes] SPOTIFY_PLAYLIST_URL'
          printf '%s\n' '  --retry-existing  Process all metadata-valid current albums; Streamrip still skips downloaded tracks.'
        end

        function die
          printf 'spotify-qobuz-albums: %s\n' "$argv" >&2
          exit 1
        end

        function warn
          printf 'spotify-qobuz-albums: warning: %s\n' "$argv" >&2
        end

        function normalize_desc
          set -l lowercase (string lower -- "$argv[1]")
          string replace -ra '[^[:alnum:]]+' "" -- "$lowercase"
        end

        function display_desc
          set -l without_controls (string replace -ra '[[:cntrl:]]+' ' ' -- "$argv[1]")
          set -l collapsed (string replace -ra '[[:space:]]+' ' ' -- "$without_controls")
          string trim -- "$collapsed"
        end

        function record_unmatched
          set -l spotify "$argv[1]"
          set -l reason "$argv[2]"
          set -l qobuz_id ""
          if test (count $argv) -ge 3
            set qobuz_id "$argv[3]"
          end
          printf '%s\n' "$spotify" | ${lib.getExe pkgs.jq} -c --arg reason "$reason" --arg qobuz_id "$qobuz_id" '
            {spotify_id, artist, album: .name, spotify_url, reason: $reason, qobuz_id: (if $qobuz_id == "" then null else $qobuz_id end)}
          ' >> "$__spotify_qobuz_unmatched_jsonl"
        end

        function record_selected
          printf '%s\n' "$argv[1]" | ${lib.getExe pkgs.jq} -c --arg qobuz_id "$argv[2]" '
            {spotify_id, artist, album: .name, spotify_url, qobuz_id: $qobuz_id}
          ' >> "$__spotify_qobuz_selected_jsonl"
        end

        function publish_unmatched
          ${lib.getExe pkgs.jq} -n --slurpfile immediate "$__spotify_qobuz_unmatched_jsonl" --slurpfile selected "$__spotify_qobuz_selected_jsonl" --slurpfile rejected "$__spotify_qobuz_rejected_manifest" '
            ($immediate | map({spotify_id, artist, album, spotify_url, reason, qobuz_id: (.qobuz_id // null)})) as $immediate_records
            | $selected as $selected
            | ($rejected[0] | if type == "array" then . else error("invalid rejected report") end) as $rejected
            | ($rejected | map(.id)) as $rejected_ids
            | ($selected | map(select(.qobuz_id as $id | ($rejected_ids | index($id))) | {
                spotify_id, artist, album, spotify_url,
                reason: "selected_qobuz_album_unavailable", qobuz_id
              })) as $stale
            | ($immediate_records + $stale)
            | unique_by(.spotify_id)
            | sort_by([(.artist | ascii_downcase), (.album | ascii_downcase), .spotify_id])
          ' > "$__spotify_qobuz_unmatched_manifest"
          or die 'could not assemble unmatched Spotify album report'
          if not ${lib.getExe pkgs.jq} -e '
            def valid_record:
              type == "object"
              and (keys | sort == ["album", "artist", "qobuz_id", "reason", "spotify_id", "spotify_url"])
              and ((.spotify_id | type) == "string" and (.spotify_id | length) > 0)
              and ((.artist | type) == "string") and ((.album | type) == "string")
              and ((.spotify_url | type) == "string" and (.spotify_url | length) > 0)
              and ((.reason | type) == "string" and (.reason | length) > 0)
              and (.qobuz_id == null or ((.qobuz_id | type) == "string" and (.qobuz_id | length) > 0));
            type == "array" and all(.[]; valid_record)
          ' "$__spotify_qobuz_unmatched_manifest" >/dev/null
            ${lib.getExe pkgs.jq} -c '[to_entries[] | select(.value | type != "object" or (keys | sort != ["album", "artist", "qobuz_id", "reason", "spotify_id", "spotify_url"]) or (.spotify_id | type != "string" or length == 0) or (.artist | type != "string") or (.album | type != "string") or (.spotify_url | type != "string" or length == 0) or (.reason | type != "string" or length == 0) or (.qobuz_id != null and (type != "string" or length == 0))) | {index: .key, keys: (.value | if type == "object" then keys else [] end), types: (.value | if type == "object" then with_entries(.value |= type) else {record: type} end), reason: (.value.reason? // null)}][0:3]' "$__spotify_qobuz_unmatched_manifest" >&2
            die 'unmatched Spotify album report has an invalid schema'
          end
          set -g __spotify_qobuz_albums_unmatched_tmp (${lib.getExe' pkgs.coreutils "mktemp"} "$__spotify_qobuz_output_dir/.spotify-qobuz-albums-unmatched.XXXXXX")
          or die 'could not create temporary unmatched report'
          ${lib.getExe' pkgs.coreutils "chmod"} 600 "$__spotify_qobuz_albums_unmatched_tmp"
          or die 'could not secure temporary unmatched report'
          ${lib.getExe pkgs.jq} . "$__spotify_qobuz_unmatched_manifest" > "$__spotify_qobuz_albums_unmatched_tmp"
          or die 'could not write unmatched Spotify album report'
          ${lib.getExe' pkgs.coreutils "mv"} -f -- "$__spotify_qobuz_albums_unmatched_tmp" "$__spotify_qobuz_unmatched_report"
          or die 'could not atomically publish unmatched Spotify album report'
          set -g __spotify_qobuz_albums_unmatched_tmp ""
          set -g __spotify_qobuz_unmatched_count (${lib.getExe pkgs.jq} -r 'length' "$__spotify_qobuz_unmatched_manifest")
        end

        argparse -n spotify-qobuz-albums 'h/help' 'o/output=' 'no-download' 'retry-existing' 'yes' -- $argv
        or begin
          usage >&2
          exit 2
        end

        if set -q _flag_help
          usage
          exit 0
        end

        if test (count $argv) -ne 1
          usage >&2
          die 'expected exactly one Spotify playlist URL'
        end

        set -l playlist_url "$argv[1]"
        if not string match -rq '^https?://open\.spotify\.com/playlist/[^/?#]+(?:\?[^#]*)?$' -- "$playlist_url"
          die 'expected an open.spotify.com/playlist/<id> URL'
        end
        set -l playlist_id (string replace -r '^https?://open\.spotify\.com/playlist/([^/?#]+)(?:\?[^#]*)?$' '$1' -- "$playlist_url")

        set -l output "$PWD/spotify-qobuz-albums.json"
        if set -q _flag_output
          if test -z "$_flag_output"
            die '--output requires a non-empty file path'
          end
          set output "$_flag_output"
        end
        set -l output_dir (path dirname "$output")
        if not test -d "$output_dir"
          die "output directory does not exist: $output_dir"
        end
        set -l rejected_report
        set -l status_report
        set -l unmatched_report
        set -l beets_report
        if string match -rq '\.json$' -- "$output"
          set rejected_report (string replace -r '\.json$' '.rejected.json' -- "$output")
          set status_report (string replace -r '\.json$' '.status.json' -- "$output")
          set unmatched_report (string replace -r '\.json$' '.unmatched.json' -- "$output")
          set beets_report (string replace -r '\.json$' '.beets.json' -- "$output")
        else
          set rejected_report "$output.rejected.json"
          set status_report "$output.status.json"
          set unmatched_report "$output.unmatched.json"
          set beets_report "$output.beets.json"
        end

        if not set -q SPOTIFY_CLIENT_ID; or test -z "$SPOTIFY_CLIENT_ID"
          die 'SPOTIFY_CLIENT_ID is not set'
        end
        if not set -q SPOTIFY_CLIENT_SECRET; or test -z "$SPOTIFY_CLIENT_SECRET"
          die 'SPOTIFY_CLIENT_SECRET is not set'
        end
        if string match -rq '[\r\n]' -- "$SPOTIFY_CLIENT_ID$SPOTIFY_CLIENT_SECRET"
          die 'Spotify credentials contain an unsupported newline'
        end

        umask 077
        set -l tempdir ($mktemp -d)
        or die 'could not create temporary directory'
        set -g __spotify_qobuz_albums_tempdir "$tempdir"
        set -g __spotify_qobuz_albums_manifest_tmp ""
        set -g __spotify_qobuz_albums_rejected_tmp ""
        set -g __spotify_qobuz_albums_status_tmp ""
        set -g __spotify_qobuz_albums_unmatched_tmp ""
        set -g __spotify_qobuz_albums_beets_tmp ""

        function __spotify_qobuz_albums_cleanup --on-event fish_exit
          ${lib.getExe' pkgs.coreutils "rm"} -rf -- "$__spotify_qobuz_albums_tempdir"
          if test -n "$__spotify_qobuz_albums_manifest_tmp"
            ${lib.getExe' pkgs.coreutils "rm"} -f -- "$__spotify_qobuz_albums_manifest_tmp"
          end
          if test -n "$__spotify_qobuz_albums_rejected_tmp"
            ${lib.getExe' pkgs.coreutils "rm"} -f -- "$__spotify_qobuz_albums_rejected_tmp"
          end
          if test -n "$__spotify_qobuz_albums_status_tmp"
            ${lib.getExe' pkgs.coreutils "rm"} -f -- "$__spotify_qobuz_albums_status_tmp"
          end
          if test -n "$__spotify_qobuz_albums_unmatched_tmp"
            ${lib.getExe' pkgs.coreutils "rm"} -f -- "$__spotify_qobuz_albums_unmatched_tmp"
          end
          if test -n "$__spotify_qobuz_albums_beets_tmp"
            ${lib.getExe' pkgs.coreutils "rm"} -f -- "$__spotify_qobuz_albums_beets_tmp"
          end
        end

        $chmod 700 "$tempdir"
        or die 'could not secure temporary directory'

        set -l client_config "$tempdir/client.conf"
        set -l token_config "$tempdir/token.conf"
        set -l token_file "$tempdir/token.json"
        set -l page_file "$tempdir/page.json"
        set -l albums_jsonl "$tempdir/albums.jsonl"
        set -l albums_file "$tempdir/albums.json"
        set -l missing_albums_file "$tempdir/missing-albums.json"
        set -l owned_albums_file "$tempdir/owned-albums.json"
        set -l search_file "$tempdir/search.json"
        set -l resolved_jsonl "$tempdir/resolved.jsonl"
        set -l raw_manifest "$tempdir/raw-manifest.json"
        set -l valid_manifest "$tempdir/valid-manifest.json"
        set -l rejected_manifest "$tempdir/rejected-manifest.json"
        set -l pending_manifest "$tempdir/pending-manifest.json"
        set -l status_manifest "$tempdir/status-manifest.json"
        set -l old_manifest "$tempdir/old-manifest.json"
        set -l old_rejected_manifest "$tempdir/old-rejected-manifest.json"
        set -l merged_manifest "$tempdir/merged-manifest.json"
        set -l merged_rejected_manifest "$tempdir/merged-rejected-manifest.json"
        set -l unmatched_jsonl "$tempdir/unmatched.jsonl"
        set -l selected_jsonl "$tempdir/selected.jsonl"
        set -l unmatched_manifest "$tempdir/unmatched-manifest.json"
        set -g __spotify_qobuz_unmatched_jsonl "$unmatched_jsonl"
        set -g __spotify_qobuz_selected_jsonl "$selected_jsonl"
        set -g __spotify_qobuz_rejected_manifest "$rejected_manifest"
        set -g __spotify_qobuz_unmatched_manifest "$unmatched_manifest"
        set -g __spotify_qobuz_unmatched_report "$unmatched_report"
        set -g __spotify_qobuz_output_dir "$output_dir"
        printf "" > "$albums_jsonl"
        printf "" > "$unmatched_jsonl"
        printf "" > "$selected_jsonl"
        printf '[]\n' > "$rejected_manifest"
        or die 'could not create temporary Spotify album list'
        if test -e "$output"
          if not $jq -e '
            type == "array"
            and all(.[];
              type == "object"
              and (keys | sort == ["id", "media_type", "source"])
              and .source == "qobuz"
              and .media_type == "album"
              and (.id | type == "string" and length > 0)
            )
            and ([.[].id] as $ids | ($ids | length) == ($ids | unique | length))
          ' "$output" >/dev/null
            die 'existing output manifest is invalid; refusing to overwrite it'
          end
          $jq 'sort_by(.id)' "$output" > "$old_manifest"
          or die 'could not snapshot existing output manifest'
        else
          printf '[]\n' > "$old_manifest"
          or die 'could not initialize existing output manifest snapshot'
        end
        if test -e "$rejected_report"
          if not $jq -e '
            type == "array"
            and all(.[];
              type == "object"
              and (keys | sort == ["attempts", "id", "media_type", "reason", "source"])
              and .source == "qobuz"
              and .media_type == "album"
              and (.id | type == "string" and length > 0)
              and (.reason | type == "string" and length > 0)
              and (.attempts | type == "number" and . >= 1)
            )
            and ([.[].id] as $ids | ($ids | length) == ($ids | unique | length))
          ' "$rejected_report" >/dev/null
            die 'existing rejected report is invalid; refusing to overwrite it'
          end
          $jq 'sort_by(.id)' "$rejected_report" > "$old_rejected_manifest"
          or die 'could not snapshot existing rejected report'
        else
          printf '[]\n' > "$old_rejected_manifest"
          or die 'could not initialize rejected report snapshot'
        end
        $chmod 600 "$old_manifest" "$old_rejected_manifest"
        or die 'could not secure existing manifest snapshots'

        set -l escaped_credentials (string replace -a '\\' '\\\\' -- "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET")
        set escaped_credentials (string replace -a '"' '\\"' -- "$escaped_credentials")
        printf 'user = "%s"\n' "$escaped_credentials" > "$client_config"
        or die 'could not write Spotify authentication configuration'
        $chmod 600 "$client_config"
        or die 'could not secure Spotify authentication configuration'

        if not $curl --retry 3 --retry-all-errors --fail-with-body --silent --show-error --config "$client_config" --data 'grant_type=client_credentials' --output "$token_file" 'https://accounts.spotify.com/api/token'
          die 'Spotify authentication failed'
        end
        if not $jq -e '(.access_token | type == "string" and length > 0)' "$token_file" >/dev/null
          die 'Spotify returned an invalid authentication response'
        end
        set -l spotify_token ($jq -r '.access_token' "$token_file")
        if string match -rq '[\r\n]' -- "$spotify_token"
          die 'Spotify returned an invalid access token'
        end
        set -l escaped_token (string replace -a '\\' '\\\\' -- "$spotify_token")
        set escaped_token (string replace -a '"' '\\"' -- "$escaped_token")
        printf 'header = "Authorization: Bearer %s"\n' "$escaped_token" > "$token_config"
        or die 'could not write Spotify request configuration'
        $chmod 600 "$token_config"
        or die 'could not secure Spotify request configuration'
        set -e spotify_token escaped_credentials escaped_token

        set -l next_url "https://api.spotify.com/v1/playlists/$playlist_id/items?limit=50"
        while test -n "$next_url"
          if not $curl --retry 3 --retry-all-errors --fail-with-body --silent --show-error --config "$token_config" --output "$page_file" "$next_url"
            die 'could not fetch Spotify playlist items'
          end
          if not $jq -e '(.items | type == "array") and (.next == null or (.next | type == "string"))' "$page_file" >/dev/null
            die 'Spotify returned an invalid playlist response'
          end
          $jq -c '
            .items[]?
            | select(.track != null and .is_local != true and .track.is_local != true and .track.type == "track")
            | .track.album as $album
            | select(
                $album != null
                and ($album.id | type == "string" and length > 0)
                and ($album.name | type == "string" and length > 0)
                and ($album.artists | type == "array" and length > 0)
                and ($album.artists[0].name | type == "string" and length > 0)
              )
            | {
                spotify_id: $album.id,
                name: $album.name,
                artist: $album.artists[0].name,
                spotify_url: ($album.external_urls.spotify // ("https://open.spotify.com/album/" + $album.id))
              }
          ' "$page_file" >> "$albums_jsonl"
          or die 'could not extract Spotify albums from playlist response'
          set next_url ($jq -r '.next // empty' "$page_file")
        end

        if not $jq -s 'unique_by(.spotify_id) | sort_by(.spotify_id)' "$albums_jsonl" > "$albums_file"
          die 'could not prepare Spotify album list'
        end
        if not $jq -e '
          type == "array"
          and all(.[];
            type == "object"
            and (.spotify_id | type == "string" and length > 0)
            and (.name | type == "string" and length > 0)
            and (.artist | type == "string" and length > 0)
            and (.spotify_url | type == "string" and length > 0)
          )
        ' "$albums_file" >/dev/null
          die 'Spotify album data did not match the expected schema'
        end
        set -l spotify_album_count ($jq -r 'length' "$albums_file")
        if not $beets_inventory --beet "$beet" --config "$beets_config" --database "$beets_database" --input "$albums_file" --missing "$missing_albums_file" --owned "$owned_albums_file"
          die 'Beets inventory failed; no Qobuz work was started'
        end
        $chmod 600 "$missing_albums_file" "$owned_albums_file"
        or die 'could not secure Beets inventory results'
        set -l beets_owned_count ($jq -r 'length' "$owned_albums_file")
        set -l beets_missing_count ($jq -r 'length' "$missing_albums_file")
        set -l beets_tmp ($mktemp "$output_dir/.spotify-qobuz-albums-beets.XXXXXX")
        or die 'could not create temporary Beets report'
        set -g __spotify_qobuz_albums_beets_tmp "$beets_tmp"
        $chmod 600 "$beets_tmp"
        or die 'could not secure temporary Beets report'
        $jq . "$owned_albums_file" > "$beets_tmp"
        or die 'could not write Beets report'
        $mv -f -- "$beets_tmp" "$beets_report"
        or die 'could not atomically publish Beets report'
        set -g __spotify_qobuz_albums_beets_tmp ""
        printf 'Beets inventory: %s already owned; %s missing\n' "$beets_owned_count" "$beets_missing_count"
        printf 'Beets report: %s\n' "$beets_report"
        if test "$beets_owned_count" -gt 0
          $jq -r 'def safe: explode | map(if (. < 32 or . == 127) then 32 else . end) | implode | gsub(" +"; " "); .[] | "\(.artist | safe) — \(.album | safe)"' "$owned_albums_file"
        end
        if test "$beets_missing_count" -eq 0
          publish_unmatched
          set -l status_tmp ($mktemp "$output_dir/.spotify-qobuz-albums-status.XXXXXX")
          or die 'could not create temporary status report'
          set -g __spotify_qobuz_albums_status_tmp "$status_tmp"
          $chmod 600 "$status_tmp"
          or die 'could not secure temporary status report'
          $jq -n '[]' > "$status_tmp"
          or die 'could not write empty status report'
          $mv -f -- "$status_tmp" "$status_report"
          or die 'could not atomically publish empty status report'
          set -g __spotify_qobuz_albums_status_tmp ""
          printf 'Unmatched Spotify albums: 0\n'
          printf 'Unmatched report: %s\n' "$unmatched_report"
          printf 'All %s Spotify albums are already present in Beets.\n' "$spotify_album_count"
          exit 0
        end

        set -l resolved_count 0
        set -l skipped_count 0
        set -l album_index 0
        for album in ($jq -c '.[]' "$missing_albums_file")
          set -l album_name (printf '%s\n' "$album" | $jq -r '.name')
          set -l album_artist (printf '%s\n' "$album" | $jq -r '.artist')
          set -l spotify_url (printf '%s\n' "$album" | $jq -r '.spotify_url')
          set -l query "$album_name by $album_artist"
          set album_index (math $album_index + 1)
          printf '[%s/%s] %s — %s\n' "$album_index" "$beets_missing_count" "$album_artist" "$album_name"
          printf 'Spotify: %s\n' "$spotify_url"
          $rm -f -- "$search_file"
          if not $rip search --output-file "$search_file" --num-results 10 qobuz album "$query" >/dev/null
            warn "Qobuz search failed for: $query"
            record_unmatched "$album" qobuz_search_failed
            set skipped_count (math $skipped_count + 1)
            continue
          end
          if not test -f "$search_file"
            warn "no Qobuz album found for: $query"
            record_unmatched "$album" no_qobuz_results
            set skipped_count (math $skipped_count + 1)
            continue
          end
          if not $jq -e '
            type == "array"
            and all(.[];
              type == "object"
              and (keys | sort == ["desc", "id", "media_type", "source"])
              and .source == "qobuz"
              and .media_type == "album"
              and (.id | type == "string" and length > 0)
              and (.desc | type == "string")
            )
          ' "$search_file" >/dev/null
            warn "Qobuz returned invalid search data for: $query"
            record_unmatched "$album" invalid_qobuz_search_response
            set skipped_count (math $skipped_count + 1)
            continue
          end

          set -l candidate_count ($jq -r 'length' "$search_file")
          if test "$candidate_count" -eq 0
            warn "no Qobuz album found for: $query"
            record_unmatched "$album" no_qobuz_results
            set skipped_count (math $skipped_count + 1)
            continue
          end

          set -l expected "$album_name by $album_artist"
          set -l expected_normalized (normalize_desc "$expected")
          set -l matches
          for candidate in ($jq -c '.[]' "$search_file")
            set -l candidate_desc (printf '%s\n' "$candidate" | $jq -r '.desc')
            set -l candidate_normalized (normalize_desc "$candidate_desc")
            if test "$candidate_normalized" = "$expected_normalized"
              set -a matches "$candidate"
            end
          end
          set -l match_count (count $matches)
          set -l chosen
          if test "$candidate_count" -eq 1; and test "$match_count" -eq 1
            set chosen "$matches[1]"
            set -l chosen_desc (printf '%s\n' "$chosen" | $jq -r '.desc')
            set -l chosen_id (printf '%s\n' "$chosen" | $jq -r '.id')
            printf 'Auto-selected Qobuz: %s [Qobuz ID: %s] https://open.qobuz.com/album/%s\n' \
              (display_desc "$chosen_desc") "$chosen_id" "$chosen_id"
          else
            printf 'Spotify: %s\n' "$spotify_url"
            set -l candidate_index 0
            for candidate in ($jq -c '.[]' "$search_file")
              set candidate_index (math $candidate_index + 1)
              set -l candidate_desc (printf '%s\n' "$candidate" | $jq -r '.desc')
              set -l candidate_id (printf '%s\n' "$candidate" | $jq -r '.id')
              printf '%s. %s [Qobuz ID: %s] https://open.qobuz.com/album/%s\n' \
                "$candidate_index" (display_desc "$candidate_desc") "$candidate_id" "$candidate_id"
            end
            if not test -t 0
              warn "Qobuz result requires confirmation without a TTY: $query"
              record_unmatched "$album" ambiguous_noninteractive
              set skipped_count (math $skipped_count + 1)
              continue
            end
            while true
              if not read -l -P 'Choose a Qobuz album number, or s to skip: ' choice
                record_unmatched "$album" selection_cancelled
                set skipped_count (math $skipped_count + 1)
                break
              end
              if test "$choice" = s
                record_unmatched "$album" selection_skipped
                set skipped_count (math $skipped_count + 1)
                break
              end
              if string match -rq '^[0-9]+$' -- "$choice"; and test "$choice" -ge 1; and test "$choice" -le "$candidate_count"
                set chosen ($jq -c --arg choice "$choice" '.[(($choice | tonumber) - 1)]' "$search_file")
                break
              end
              printf 'Enter a number from 1 to %s, or s to skip.\n' "$candidate_count" >&2
            end
            if test -z "$chosen"
              continue
            end
          end
          printf '%s\n' "$chosen" | $jq -c '{ source, media_type, id }' >> "$resolved_jsonl"
          or die 'could not record resolved Qobuz album'
          set -l selected_qobuz_id (printf '%s\n' "$chosen" | $jq -r '.id')
          record_selected "$album" "$selected_qobuz_id"
          set resolved_count (math $resolved_count + 1)
        end

        if test "$resolved_count" -eq 0
          publish_unmatched
          printf 'Unmatched Spotify albums: %s\n' "$__spotify_qobuz_unmatched_count"
          printf 'Unmatched report: %s\n' "$unmatched_report"
          if test "$__spotify_qobuz_unmatched_count" -gt 0
            $jq -r 'def safe: explode | map(if (. < 32 or . == 127) then 32 else . end) | implode | gsub(" +"; " "); .[] | "\(.artist | safe) — \(.album | safe) [\(.reason)]"' "$unmatched_manifest"
          end
          die 'no Qobuz albums resolved; unmatched report was published'
        end

        if not $jq -s 'unique_by(.id) | sort_by(.id)' "$resolved_jsonl" > "$raw_manifest"
          die 'could not prepare current resolved manifest'
        end
        if not $jq -e '
          type == "array"
          and length > 0
          and all(.[];
            type == "object"
            and (keys | sort == ["id", "media_type", "source"])
            and .source == "qobuz"
            and .media_type == "album"
            and (.id | type == "string" and length > 0)
          )
        ' "$raw_manifest" >/dev/null
          die 'current resolved manifest did not match the expected schema'
        end
        $chmod 600 "$raw_manifest"
        or die 'could not secure current resolved manifest'
        set -l current_resolved_count ($jq -r 'length' "$raw_manifest")
        set -l already_listed_count ($jq --slurpfile old "$old_manifest" '($old[0] | map(.id)) as $old_ids | [.[] | select(.id as $id | $old_ids | index($id))] | length' "$raw_manifest")
        set -l newly_listed_count (math $current_resolved_count - $already_listed_count)
        printf 'Current resolved IDs: %s; already listed: %s; newly listed: %s\n' \
          "$current_resolved_count" "$already_listed_count" "$newly_listed_count"
        if not $preflight --config "$streamrip_config" --input "$raw_manifest" --valid "$valid_manifest" --rejected "$rejected_manifest" --pending "$pending_manifest" --status "$status_manifest"
          die 'Qobuz metadata preflight failed; manifests were not published'
        end
        $chmod 600 "$valid_manifest" "$rejected_manifest" "$pending_manifest" "$status_manifest"
        or die 'could not secure Qobuz preflight results'
        if not $jq -e '
          type == "array"
          and all(.[];
            type == "object"
            and (keys | sort == ["id", "media_type", "source"])
            and .source == "qobuz"
            and .media_type == "album"
            and (.id | type == "string" and length > 0)
          )
        ' "$valid_manifest" >/dev/null
          die 'Qobuz preflight produced an invalid valid manifest'
        end
        if not $jq -e '
          type == "array"
          and all(.[];
            type == "object"
            and (keys | sort == ["attempts", "id", "media_type", "reason", "source"])
            and .source == "qobuz"
            and .media_type == "album"
            and (.id | type == "string" and length > 0)
            and .reason == "No result matching given argument"
            and .attempts == 2
          )
        ' "$rejected_manifest" >/dev/null
          die 'Qobuz preflight produced an invalid rejected report'
        end
        set -l preflight_valid_count ($jq -r 'length' "$valid_manifest")
        set -l preflight_rejected_count ($jq -r 'length' "$rejected_manifest")
        if not $jq -s '
          .[0] as $old
          | .[1] as $new
          | ($new | map(.id)) as $new_ids
          | ($old | map(select(.id as $id | ($new_ids | index($id) | not))) + $new)
          | sort_by(.id)
        ' "$old_rejected_manifest" "$rejected_manifest" > "$merged_rejected_manifest"
          die 'could not merge rejected report history'
        end
        $chmod 600 "$merged_rejected_manifest"
        or die 'could not secure merged rejected report'
        set -l rejected_tmp ($mktemp "$output_dir/.spotify-qobuz-albums-rejected.XXXXXX")
        or die 'could not create temporary rejected report'
        set -g __spotify_qobuz_albums_rejected_tmp "$rejected_tmp"
        $chmod 600 "$rejected_tmp"
        or die 'could not secure temporary rejected report'
        if not $jq . "$merged_rejected_manifest" > "$rejected_tmp"
          die 'could not write merged rejected report'
        end
        $mv -f -- "$rejected_tmp" "$rejected_report"
        or die 'could not atomically publish rejected report'
        set -g __spotify_qobuz_albums_rejected_tmp ""

        if not $jq -s '(.[2] | map(.id)) as $rejected_ids | (.[0] + .[1]) | unique_by(.id) | map(select(.id as $id | ($rejected_ids | index($id) | not))) | sort_by(.id)' "$old_manifest" "$valid_manifest" "$rejected_manifest" > "$merged_manifest"
          die 'could not merge cumulative output manifest'
        end
        $chmod 600 "$merged_manifest"
        or die 'could not secure merged output manifest'
        set -l cumulative_count ($jq -r 'length' "$merged_manifest")
        printf 'Preflight: valid new: %s; rejected stale: %s\n' "$preflight_valid_count" "$preflight_rejected_count"
        if test "$preflight_rejected_count" -gt 0
          printf 'Rejected Qobuz IDs:\n'
          $jq -r '.[].id' "$rejected_manifest"
          printf 'Rejected report: %s\n' "$rejected_report"
        end
        set -l status_tmp ($mktemp "$output_dir/.spotify-qobuz-albums-status.XXXXXX")
        or die 'could not create temporary status report'
        set -g __spotify_qobuz_albums_status_tmp "$status_tmp"
        $chmod 600 "$status_tmp"
        or die 'could not secure temporary status report'
        if not $jq . "$status_manifest" > "$status_tmp"
          die 'could not write status report'
        end
        $mv -f -- "$status_tmp" "$status_report"
        or die 'could not atomically publish status report'
        set -g __spotify_qobuz_albums_status_tmp ""
        set -l complete_count ($jq -r '[.[] | select(.complete == true)] | length' "$status_manifest")
        set -l pending_count ($jq -r '[.[] | select(.complete != true)] | length' "$status_manifest")
        printf 'Download status: %s fully downloaded; %s incomplete or unknown.\n' "$complete_count" "$pending_count"
        printf 'Status report: %s\n' "$status_report"
        if test "$pending_count" -gt 0
          $jq -r '.[] | select(.complete != true) | "\(.artist) — \(.title) [\(.id)] \(.downloaded_tracks)/\(.total_tracks) tracks; \(.missing_tracks) missing\(if .reason then " (" + .reason + ")" else "" end)"' "$status_manifest"
        end
        publish_unmatched
        printf 'Unmatched Spotify albums: %s\n' "$__spotify_qobuz_unmatched_count"
        printf 'Unmatched report: %s\n' "$unmatched_report"
        if test "$__spotify_qobuz_unmatched_count" -gt 0
          $jq -r 'def safe: explode | map(if (. < 32 or . == 127) then 32 else . end) | implode | gsub(" +"; " "); .[] | "\(.artist | safe) — \(.album | safe) [\(.reason)]"' "$unmatched_manifest"
        end
        set -l metadata_valid_matched_count (math $spotify_album_count - $beets_owned_count - $__spotify_qobuz_unmatched_count)
        printf 'Spotify unique albums: %s; metadata-valid matched: %s; unmatched: %s\n' \
          "$spotify_album_count" "$metadata_valid_matched_count" "$__spotify_qobuz_unmatched_count"
        if test "$cumulative_count" -eq 0
          die 'no cumulative valid albums remain; rejected report was published'
        end
        set -l manifest_tmp ($mktemp "$output_dir/.spotify-qobuz-albums.XXXXXX")
        or die 'could not create temporary manifest'
        set -g __spotify_qobuz_albums_manifest_tmp "$manifest_tmp"
        $chmod 600 "$manifest_tmp"
        or die 'could not secure temporary manifest'
        if not $jq . "$merged_manifest" > "$manifest_tmp"
          die 'could not write cumulative manifest'
        end
        $mv -f -- "$manifest_tmp" "$output"
        or die 'could not atomically publish manifest'
        set -g __spotify_qobuz_albums_manifest_tmp ""

        printf 'Cumulative manifest: %s albums\n' "$cumulative_count"
        printf 'Manifest: %s\n' "$output"
        set -l download_manifest "$pending_manifest"
        set -l download_count ($jq -r 'length' "$pending_manifest")
        if set -q _flag_retry_existing
          set download_manifest "$valid_manifest"
          set download_count ($jq -r 'length' "$valid_manifest")
        end
        if test "$download_count" -eq 0
          printf "All %s current albums are fully downloaded according to Streamrip's downloads database.\n" "$current_resolved_count"
          exit 0
        end

        if set -q _flag_no_download
          exit 0
        end
        set -l download false
        if set -q _flag_yes
          set download true
        else if test -t 0
          read -l -P "Process $download_count incomplete or unknown Qobuz albums now? [y/N] " answer
          if string match -rq '^[Yy]$' -- "$answer"
            set download true
          end
        else
          warn 'not downloading without a TTY; use --yes to confirm'
        end
        if test "$download" = true
          $rip file "$download_manifest"
        end
      '';
      spotify-qobuz-albums = pkgs.writeShellApplication {
        name = "spotify-qobuz-albums";
        text = ''
          case "''${1:-}" in
            -h|--help)
              exec ${lib.getExe spotify-qobuz-albums-inner} "$@"
              ;;
          esac
          harmony_env=${lib.escapeShellArg config.age.secrets."beets-harmony".path}
          if [ ! -r "$harmony_env" ]; then
            printf '%s\n' 'spotify-qobuz-albums: cannot read beets-harmony secret' >&2
            exit 1
          fi
          set -a
          # shellcheck disable=SC1090
          if ! . "$harmony_env"; then
            set +a
            printf '%s\n' 'spotify-qobuz-albums: could not load beets-harmony secret' >&2
            exit 1
          fi
          set +a
          if [ -z "''${SPOTIFY_CLIENT_ID:-}" ] || [ -z "''${SPOTIFY_CLIENT_SECRET:-}" ]; then
            printf '%s\n' 'spotify-qobuz-albums: beets-harmony secret lacks Spotify credentials' >&2
            exit 1
          fi
          exec ${lib.getExe spotify-qobuz-albums-inner} "$@"
        '';
      };
    in
    {
      home.packages = [
        pkgs.streamrip
        spotify-qobuz-albums
      ];
      programs.fish.functions.rs = ''
        #!/bin/fish
        ${lib.getExe pkgs.streamrip} search qobuz album "$argv"
      '';
      programs.fish.functions.rr = ''
        #!/bin/fish
        set -l db_path "${config.xdg.configHome}/streamrip/failed_downloads.db"

        # Usage: rr or rr --list
        if test (count $argv) -gt 1
          echo "Usage: rr [--list]"
          return 1
        end
        if test (count $argv) -eq 1; and test "$argv[1]" != "--list"
          echo "Usage: rr [--list]"
          return 1
        end

        if not test -f "$db_path"
          echo "No failed downloads."
          echo "DB path: $db_path"
          return 0
        end

        set -l rows (${lib.getExe' pkgs.sqlite "sqlite3"} -separator '|' "$db_path" \
          "SELECT source, media_type, id FROM failed_downloads" 2>/dev/null)
        if test $status -ne 0
          echo "Failed to read DB"
          return 1
        end

        if test (count $rows) -eq 0
          echo "No failed downloads."
          echo "DB path: $db_path"
          return 0
        end

        # --list mode
        if test (count $argv) -eq 1
          for line in $rows
            set -l parts (string split '|' "$line")
            if test (count $parts) -eq 3
              printf '%-20s %-12s %s\n' $parts[1] $parts[2] $parts[3]
            end
          end
          return 0
        end

        # Retry mode
        set -l total 0
        set -l succeeded 0
        set -l failed 0
        for line in $rows
          set -l parts (string split '|' "$line")
          if test (count $parts) -ne 3
            continue
          end
          set total (math $total + 1)
          echo "Retrying ($total): $parts[1] $parts[2] $parts[3]"
          if ${lib.getExe pkgs.streamrip} id $parts[1] $parts[2] $parts[3]
            set succeeded (math $succeeded + 1)
            echo "  -> succeeded"
          else
            set failed (math $failed + 1)
            echo "  -> failed"
          end
        end

        echo ""
        echo "Total: $total, Succeeded: $succeeded, Failed: $failed"
        if test $failed -gt 0
          return 1
        end
      '';
      home.activation.streamripConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        $DRY_RUN_CMD ${lib.getExe mergeConfig} \
          ${lib.escapeShellArg (builtins.toJSON managedConfig)} \
          "${config.xdg.configHome}/streamrip/config.toml"
      '';
    };
}
