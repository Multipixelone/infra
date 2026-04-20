{
  withSystem,
  rootPath,
  ...
}:
{
  nixpkgs.config.allowUnfreePackages = [ "plexamp-headless" ];

  perSystem =
    { pkgs, ... }:
    {
      packages.plexamp-headless = pkgs.callPackage "${rootPath}/pkgs/plexamp-headless" { };
    };

  configurations.nixos.marin.module =
    { pkgs, lib, ... }:
    let
      plexamp-headless = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.plexamp-headless
      );
      stateDir = "/var/lib/plexamp-headless";
      # File written by Plexamp after a successful claim — used as the auth sentinel
      tokenPath = "${stateDir}/.local/share/Plexamp/Settings/%40Plexamp%3Auser%3Atoken";
      # systemd treats bare % as a specifier prefix; escape them for use in unit files
      tokenPathUnit = builtins.replaceStrings [ "%" ] [ "%%" ] tokenPath;

      claimScript = pkgs.writeShellScriptBin "plexamp-headless-claim" ''
        if [ -f "${tokenPath}" ]; then
          echo "Already claimed. Remove ${tokenPath} to re-claim."
          exit 0
        fi
        exec systemd-run --pty --collect \
          -p User=plexamp-headless \
          -p 'Environment=HOME=${stateDir}' \
          -p 'Environment="NODE_OPTIONS=--dns-result-order=ipv4first"' \
          -p 'Environment=XDG_CONFIG_HOME=${stateDir}/.config' \
          -p 'Environment=XDG_DATA_HOME=${stateDir}/.local/share' \
          ${lib.getExe plexamp-headless}
      '';
    in
    {
      users.users.plexamp-headless = {
        isSystemUser = true;
        group = "plexamp-headless";
        # Needs audio group to open /dev/snd/* (ALSA output); without it
        # Plexamp accepts the session but playback hangs / the client bounces.
        extraGroups = [ "audio" ];
        home = stateDir;
      };
      users.groups.plexamp-headless = { };

      environment.systemPackages = [ claimScript ];

      networking.firewall = {
        allowedTCPPorts = [
          8324 # Control other plex devices
          32500 # Plexamp dashboard port
        ];
        allowedUDPPortRanges = [
          {
            from = 32410;
            to = 32414; # mDNS ports for device discovert
          }
        ];
      };

      systemd.services.plexamp-headless = {
        description = "Plexamp Headless";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        # Skip start (and restart loops) until claim has been completed
        unitConfig.ConditionPathExists = tokenPathUnit;
        serviceConfig = {
          Type = "simple";
          User = "plexamp-headless";
          Group = "plexamp-headless";
          StateDirectory = "plexamp-headless";
          Environment = [
            "NODE_OPTIONS=--dns-result-order=ipv4first"
            "HOME=${stateDir}"
            "XDG_CONFIG_HOME=${stateDir}/.config"
            "XDG_DATA_HOME=${stateDir}/.local/share"
          ];
          ExecStart = lib.getExe plexamp-headless;
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    };
}
