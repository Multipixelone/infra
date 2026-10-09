{ lib, inputs, ... }:
{
  # Temporary Zotero-only downgrade to compatible Zotero 10.0.0 / Firefox ESR140.
  # Remove the input and overlay once https://github.com/NixOS/nixpkgs/issues/568692 is fixed.
  flake-file.inputs.nixpkgs-zotero.url =
    "github:nixos/nixpkgs/c27cdad491a991b11ed731760aa2ef8db0cb0410";

  nixpkgs.overlays = [
    (_final: prev: {
      zotero =
        (import inputs.nixpkgs-zotero {
          system = prev.stdenv.hostPlatform.system;
        }).zotero;
    })
  ];

  flake.modules.homeManager.gui =
    { pkgs, ... }:
    let
      # latexrun wrapped w/ args & copy synctex into root
      latexrun-wrapped = pkgs.writeShellScriptBin "latexrun" ''
        ${lib.getExe pkgs.latexrun} --bibtex-cmd "${pkgs.biber}/bin/biber" --latex-args=-synctex=1 "$1"
        SYNCTEX_FILE=$(find latex.out/ -name "*.synctex.gz")
        cp $SYNCTEX_FILE .
      '';
    in
    {
      home.packages = with pkgs; [
        zotero
        texliveBasic
        latexrun-wrapped
      ];
      programs.zathura = {

        enable = true;
        options = {
          recolor = true;
          adjust-open = "best-fit";
          pages-per-row = "1";
          scroll-page-aware = "true";
          scroll-full-overlap = "0.01";
          scroll-step = "100";
          zoom-min = "10";
          guioptions = "none";
        };
      };
    };
}
