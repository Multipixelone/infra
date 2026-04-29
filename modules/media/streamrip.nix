{
  inputs,
  ...
}:
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
    in
    {
      home.packages = [
        pkgs.streamrip
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
