{
  flake.modules.nixos.base.programs.bandwhich.enable = true;
  flake.modules.homeManager.base =
    { pkgs, lib, ... }:
    {
      home.packages =
        (with pkgs; [
          bind # for dig
          curl
          gping
          inetutils
          socat
        ])
        # Linux-only network tooling.
        ++ lib.optionals pkgs.stdenv.isLinux (
          with pkgs;
          [
            ethtool
            wifite2
          ]
        );
    };
}
