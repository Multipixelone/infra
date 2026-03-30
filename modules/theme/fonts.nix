{
  inputs,
  withSystem,
  rootPath,
  ...
}:
{
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
    "apple-emoji"
  ];
  flake.modules.nixos.pc =
    { pkgs, ... }:
    let
      pragmata = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.pragmata);
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
          inputs.apple-emoji.packages.${pkgs.stdenv.hostPlatform.system}.default

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
