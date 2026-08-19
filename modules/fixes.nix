{
  nixpkgs.overlays = [
    # https://github.com/NixOS/nixpkgs/pull/503253
    (

      _final: prev: {
        python3Packages = prev.python3Packages.overrideScope (
          pyFinal: pyPrev: {
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
    # No aioboto3 / fastmcp / syrupy overrides here, on purpose.
    #
    # All three only ever failed on `python312Packages`, a side set Hydra
    # barely builds — so the whole closure compiled locally and every flaky
    # suite in it got a chance to bite. modules/link/openclaw.nix now
    # instantiates pkgs/fli and pkgs/agentmail on the default (3.14) set, where
    # aioboto3, py-key-value-aio, pydocket, fastmcp, cyclopts and syrupy all
    # substitute straight from cache.nixos.org.
    #
    # Re-adding any of them is worse than useless: an override forks the
    # derivation, so the cache hit is lost and the package must be built —
    # which is the only way its tests ever run. The aioboto3 one was the
    # sharpest case: nothing here uses aioboto3 directly, but overriding it
    # rewrote py-key-value-aio -> pydocket -> fastmcp, forcing a local fastmcp
    # build whose Supabase integration test then failed in the sandbox.
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
    (_final: prev: {
      john = prev.john.overrideAttrs (_old: {
        src = prev.fetchFromGitHub {
          owner = "openwall";
          repo = "john";
          rev = "f514ece8ec4ae5e38ad75aaa322eac86d73dcd76";
          hash = "sha256-zO1/KUJe3LvYCGlwVpNg5uDwPRD0ql/7anErb7tywC0=";
        };
      });
    })
    # inline-snapshot 0.32.5: test_docs re-renders the code blocks in its own
    # markdown docs via black and diffs them against what's committed. At this
    # nixpkgs pin the rendered output drifts from the docs (a black version
    # skew upstream hasn't re-pinned yet), failing all 3 doc files. It's a
    # doc-sync check with no bearing on the library's behavior, so skip it
    # rather than block anything that transitively needs inline-snapshot
    # (python312Packages.openai's own test suite pulls it in). `python3` on
    # this pin aliases to python314, a distinct package set from python312 —
    # override python312 itself (not python3Packages) so it actually reaches
    # `pkgs.python312.withPackages` call sites like foodtown-sort/nudge-writer.
    (_final: prev: {
      python312 = prev.python312.override {
        packageOverrides = _pyFinal: pyPrev: {
          inline-snapshot = pyPrev.inline-snapshot.overridePythonAttrs (old: {
            disabledTests = (old.disabledTests or [ ]) ++ [ "test_docs" ];
          });
        };
      };
    })
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
