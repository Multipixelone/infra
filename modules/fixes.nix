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
