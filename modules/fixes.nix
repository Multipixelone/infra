{
  nixpkgs.overlays = [
    # https://github.com/NixOS/nixpkgs/pull/503253
    (

      final: prev: {
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
