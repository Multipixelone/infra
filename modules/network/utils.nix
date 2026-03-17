{
  flake.modules.nixos.base.programs.bandwhich.enable = true;
  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        bind # for dig
        curl
        ethtool
        gping
        inetutils
        socat
        wifite2
      ];
    };
}
