{
  nixpkgs.config.allowUnfreePackages = [ "vscode" ];
  flake.modules.homeManager.gui =
    { pkgs, lib, ... }:
    {
      home.packages = with pkgs; [
        vscode
        playwright-driver.browsers
      ];

      programs.fish.shellInit = lib.mkAfter ''
        set -gx PLAYWRIGHT_BROWSERS_PATH ${pkgs.playwright-driver.browsers}
        set -gx PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS true
        set -gx PLAYWRIGHT_HOST_PLATFORM_OVERRIDE "ubuntu-24.04"
      '';
    };
}
