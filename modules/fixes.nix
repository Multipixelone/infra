{
  nixpkgs.overlays = [
    # nixpkgs' OpenCode 2.2.5 node_modules hash differs from the fetched output.
    (_final: prev: {
      opencode = prev.opencode.overrideAttrs (old: {
        node_modules = old.node_modules.overrideAttrs (_: {
          outputHash = "sha256-prx9dX7kUvs/E3zopkaPk5LXh3xJAy5sZeum/W8L7cA=";
        });
      });
    })
    (

      _final: prev: {
        python3Packages = prev.python3Packages.overrideScope (
          pyFinal: pyPrev: {
            # https://github.com/NixOS/nixpkgs/pull/503253
            wand = pyPrev.wand.overridePythonAttrs (_: rec {
              version = "0.6.13";
              src = pyFinal.fetchPypi {
                pname = "Wand";
                inherit version;
                hash = "sha256-9QE0hOr3og6yLRghqu/mC1DMMpciNytfhWXUbUqq/Mo=";
              };
            });
          }
        );
      })
    # urllib3-future's suite hangs in the sandbox after the socks tests fail,
    # and niquests' proxy-from-environment tests fail the same way. Hydra has
    # no substitute for either, so every closure pulling in niquests (Home
    # Assistant via caldav) builds them. An extension rather than overrideScope
    # so Home Assistant's own interpreter sees it.
    (_final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (pyFinal: pyPrev: {
          # FastMCP 3.x still requires MCP SDK 1.x. nixpkgs now defaults to
          # SDK 2.x and marks fastmcp-slim broken with that dependency. Keep
          # the compatible SDK until FastMCP supports the new API. An extension
          # so every interpreter (python3.pkgs, python314Packages) sees it.
          fastmcp-slim = pyPrev.fastmcp-slim.override {
            mcp = pyFinal.mcp_1;
          };
          urllib3-future = pyPrev.urllib3-future.overridePythonAttrs { doCheck = false; };
          niquests = pyPrev.niquests.overridePythonAttrs (old: {
            disabledTests = (old.disabledTests or [ ]) ++ [ "test_use_proxy_from_environment" ];
          });
        })
      ];
    })
    # calibre-web 0.6.27b0 declares requests<2.33.0 but works with 2.33.x
    (_final: prev: {
      calibre-web = prev.calibre-web.overridePythonAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "requests" ];
      });
    })
    # john-rolling-2604: upstream GitHub re-generated the archive tarball,
    # so the rev f514ece... now hashes to a different NAR. nixpkgs still
    # pins the old hash, which breaks anything that depends on `john`
    # (e.g. wifite2). Pin the correct content hash until nixpkgs catches up.
    # (_final: prev: {
    #   john = prev.john.overrideAttrs (_old: {
    #     src = prev.fetchFromGitHub {
    #       owner = "openwall";
    #       repo = "john";
    #       rev = "f514ece8ec4ae5e38ad75aaa322eac86d73dcd76";
    #       hash = "sha256-zO1/KUJe3LvYCGlwVpNg5uDwPRD0ql/7anErb7tywC0=";
    #     };
    #   });
    # })
    # Anki 26.09.4's offline wheel list lacks tomlkit, required by hatchling 1.32.0.
    # Cargo's system-library hook also needs explicit native dependencies.
    # Remove when nixpkgs fixes Anki's wheel list and native build inputs.
    (final: prev: {
      anki = prev.anki.overrideAttrs (old: {
        env = old.env // {
          UV_FIND_LINKS = final.runCommand "uv-wheels-with-tomlkit" { } ''
            mkdir -p $out
            ln -s ${old.env.UV_FIND_LINKS}/*.whl $out/
            ln -s ${final.python3.pkgs.tomlkit.dist}/*.whl $out/
          '';
        };
        nativeBuildInputs = old.nativeBuildInputs ++ [ final.pkg-config ];
        buildInputs = old.buildInputs ++ [
          final.sqlite
          final.xz
          final.zstd
        ];
      });
    })
    # codex-acp pulls in source-built codex even though the CLI uses codex-nix.
    # Remove once nixpkgs includes this upstream build-input fix:
    # https://github.com/NixOS/nixpkgs/commit/16b463698a5b9f20881b6c5f1150ce37e2456db9
    (final: prev: {
      codex = prev.codex.overrideAttrs (old: {
        buildInputs = old.buildInputs ++ [
          final.aws-lc
          final.oniguruma
          final.sqlite
          final.zstd
        ];
      });
    })
    # govee2mqtt links rusqlite against system SQLite (cargo-setup-hook sets
    # LIBSQLITE3_SYS_USE_PKG_CONFIG). Remove once nixpkgs adds sqlite to buildInputs.
    (final: prev: {
      govee2mqtt = prev.govee2mqtt.overrideAttrs (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [ final.sqlite ];
      });
    })
    # RomM 5.4 imports httpx2 (not httpx) and apprise, but nixpkgs' pythonEnv
    # still lists only httpx, so romm-migrate dies with ModuleNotFoundError.
    # Remove once the pinned nixpkgs includes this upstream fix:
    # https://github.com/NixOS/nixpkgs/commit/4ba1433a42f1e91c8750852f10dff29e2f9469d6
    (_final: prev: {
      romm = prev.romm.overrideAttrs (old: {
        passthru = old.passthru // {
          pythonEnv = old.passthru.pythonEnv.override (env: {
            extraLibs = env.extraLibs ++ [
              prev.python3.pkgs.apprise
              prev.python3.pkgs.httpx2
            ];
          });
        };
      });
    })
    # espanso 2.3.0 fails to link on aarch64-darwin: buildRustPackage's default
    # cargo-auditable pass injects an undefined `_AUDITABLE_VERSION_INFO` symbol
    # plus an espanso_audit_data.o, and the cctools `ld` crashes (Trace/BPT trap,
    # exit 133) while linking them — which also takes down the espanso-*-fish-
    # completions drv. Disable auditable for espanso on darwin so that SBOM object
    # is never emitted. `auditable` is a buildRustPackage arg (not an espanso
    # package.nix arg and not reachable via overrideAttrs, since it's consumed in
    # extendDrvArgs before mkDerivation), so wrap buildRustPackage to force it off.
    # Linux links fine, so leave it untouched there to avoid needless rebuilds.
    (
      _final: prev:
      prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
        espanso = prev.espanso.override {
          rustPlatform = prev.rustPlatform // {
            buildRustPackage =
              args:
              prev.rustPlatform.buildRustPackage (
                if builtins.isFunction args then
                  finalAttrs: (args finalAttrs) // { auditable = false; }
                else
                  args // { auditable = false; }
              );
          };
        };
      }
    )
  ];
}
