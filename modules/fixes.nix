{
  nixpkgs.overlays = [
    # https://github.com/NixOS/nixpkgs/pull/494140
    (
      final: prev:
      let
        src = prev.fetchFromGitHub {
          owner = "janeczku";
          repo = "calibre-web";
          # remember changing this back (and changelog below) to tag after new release come out
          rev = "5e48a64b1517574c31cf667be8c45bcd05cd0904";
          hash = "sha256-OgaU+Kj24AzalMM8dhelJz1L8akadJoJApQw3q8wbCc=";
        };
      in
      {
        calibre-web = prev.calibre-web.overrideAttrs {
          version = "0.6.27-unstable-2026-02-22";
          inherit src;
        };
      }
    )
    # https://github.com/NixOS/nixpkgs/pull/493604
    # (final: prev: {
    #   anki = prev.anki.overrideAttrs {
    #     buildInputs = prev.anki.buildInputs ++ [ prev.qt6.qtwebengine ];
    #   };
    # })
    (final: prev: {
      linuxPackages_zen = prev.linuxPackages_zen.extend (
        lpself: lpsuper: {
          amneziawg = lpsuper.amneziawg.overrideAttrs {
            patches = lpsuper.amneziawg.patches ++ [ ./amnezia.patch ];
          };
        }
      );
    })
  ];
}
