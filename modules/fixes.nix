{
  nixpkgs.overlays = [
    (

      _final: prev: {
        python3Packages = prev.python3Packages.overrideScope (
          pyFinal: pyPrev: {
            # FastMCP 3.x still requires MCP SDK 1.x. nixpkgs now defaults
            # to SDK 2.x and marks fastmcp-slim broken with that dependency.
            # Keep the compatible SDK until FastMCP supports the new API.
            fastmcp-slim = pyPrev.fastmcp-slim.override {
              mcp = pyFinal.mcp_1;
            };
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
    # https://github.com/NixOS/nixpkgs/pull/493604
    # (final: prev: {
    #   anki = prev.anki.overrideAttrs {
    #     buildInputs = prev.anki.buildInputs ++ [ prev.qt6.qtwebengine ];
    #   };
    # })
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
