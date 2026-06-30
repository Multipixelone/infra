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
    # aioboto3 dynamo tests fail on werkzeug 3.1 (Duplicate 'Server' header)
    (_final: prev: {
      python3Packages = prev.python3Packages.overrideScope (
        _pyFinal: pyPrev: {
          aioboto3 = pyPrev.aioboto3.overridePythonAttrs (old: {
            disabledTests = (old.disabledTests or [ ]) ++ [
              "test_dynamo_resource_query"
              "test_dynamo_resource_put"
              "test_dynamo_resource_batch_write_flush_on_exit_context"
              "test_dynamo_resource_batch_write_flush_amount"
              "test_flush_doesnt_reset_item_buffer"
              "test_dynamo_resource_property"
              "test_dynamo_resource_waiter"
            ];
          });
        }
      );
    })
    # fastmcp: two rate-limiting integration tests are timing-sensitive and
    # flaky under the build sandbox (the limiter doesn't trip in time, so the
    # expected ToolError is never raised). Skip them.
    (_final: prev: {
      python3Packages = prev.python3Packages.overrideScope (
        _pyFinal: pyPrev: {
          fastmcp = pyPrev.fastmcp.overridePythonAttrs (old: {
            disabledTests = (old.disabledTests or [ ]) ++ [
              "test_rate_limiting_with_different_operations"
              "test_rate_limiting_recovery_over_time"
            ];
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
    # https://github.com/NixOS/nixpkgs/pull/493604
    # (final: prev: {
    #   anki = prev.anki.overrideAttrs {
    #     buildInputs = prev.anki.buildInputs ++ [ prev.qt6.qtwebengine ];
    #   };
    # })
    # (final: prev: {
    #   linuxPackages_zen = prev.linuxPackages_zen.extend (
    #     lpself: lpsuper: {
    #       amneziawg = lpsuper.amneziawg.overrideAttrs {
    #         patches = lpsuper.amneziawg.patches ++ [ ./amnezia.patch ];
    #       };
    #     }
    #   );
    # })
  ];
}
