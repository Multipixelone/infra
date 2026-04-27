{
  inputs,
  withSystem,
  rootPath,
  ...
}:
{
  flake-file.inputs = {
    apple-fonts.url = "github:Lyndeno/apple-fonts.nix";
    apple-emoji = {
      url = "github:samuelngs/apple-emoji-ttf";
      flake = false;
    };
  };

  perSystem =
    { pkgs, ... }:
    {
      packages = {
        pragmata = pkgs.callPackage "${rootPath}/pkgs/pragmata" { };
      };
    };
  nixpkgs.config.allowUnfreePackages = [
    "pragmata-pro"
    "vista-fonts"
    "corefonts"
  ];
  flake.modules.nixos.pc =
    { pkgs, ... }:
    let
      pragmata = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.pragmata);
      appleEmoji = pkgs.callPackage "${inputs.apple-emoji}/default.nix" {
        src = inputs.apple-emoji;
        ttc = pkgs.fetchurl {
          url = "https://blusky.s3.us-west-2.amazonaws.com/apple-emoji.ttc";
          sha256 = "0qpzsw0a1823g3igmgadpkz33k3k0ij3ibfxi7h73mi6bfvy0pj3";
        };
      };
    in
    {
      fonts = {
        enableDefaultPackages = false;
        packages = with pkgs; [
          ipafont
          minecraftia

          # windows fonts
          corefonts
          vista-fonts

          # macos fonts
          # inputs.apple-fonts.packages.${pkgs.stdenv.hostPlatform.system}.ny
          # inputs.apple-fonts.packages.${pkgs.stdenv.hostPlatform.system}.sf-pro
          # inputs.apple-fonts.packages.${pkgs.stdenv.hostPlatform.system}.sf-compact
          # inputs.apple-fonts.packages.${pkgs.stdenv.hostPlatform.system}.sf-mono
          appleEmoji

          # my fonts
          nerd-fonts.iosevka
          pragmata
        ];
        fontconfig = {
          defaultFonts = {
            # ipa gothic required for cjk support
            serif = [
              "PragmataPro Liga"
              "IPAGothic"
            ];
            sansSerif = [
              "PragmataPro Liga"
              "IPAGothic"
            ];
            monospace = [
              "PragmataPro Mono Liga"
              "IPAGothic"
            ];
            emoji = [ "Apple Color Emoji" ];
          };
        };
      };
    };
}
