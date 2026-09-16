{ config, lib, ... }:
let
  ownerUsername = config.flake.meta.owner.username;
in
{
  flake.modules.nixos.audio-output =
    { config, pkgs, ... }:
    let
      cfg = config.infra.audioOutput;
      inherit (cfg) snapclient;
      server = if snapclient.server != null then snapclient.server else "";
    in
    {
      options.infra.audioOutput = {
        user = lib.mkOption {
          type = lib.types.str;
          default = ownerUsername;
          description = "User account that owns the audio output services.";
        };
        snapclient = {
          enable = lib.mkEnableOption "Snapclient PipeWire playback";
          server = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Snapserver URI for Snapclient.";
          };
          sink = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional PipeWire sink name for Snapclient.";
          };
        };
      };

      config = lib.mkIf snapclient.enable {
        assertions = [
          {
            assertion = snapclient.server != null && snapclient.server != "";
            message = "infra.audioOutput.snapclient.server must be a non-empty Snapserver URI when Snapclient is enabled.";
          }
        ];

        users.users.${cfg.user}.linger = true;
        users.extraGroups.audio.members = [ cfg.user ];

        services.pipewire = {
          enable = true;
          wireplumber.enable = true;
        };

        systemd.user.services.snapclient = {
          description = "Snapclient PipeWire playback";
          after = [
            "pipewire.service"
            "wireplumber.service"
          ];
          wants = [
            "pipewire.service"
            "wireplumber.service"
          ];
          wantedBy = [ "default.target" ];
          unitConfig.ConditionUser = cfg.user;
          serviceConfig = {
            ExecStart = lib.escapeShellArgs (
              [
                (lib.getExe' pkgs.snapcast "snapclient")
                "--player"
                "pipewire"
              ]
              ++ lib.optionals (snapclient.sink != null) [
                "-s"
                snapclient.sink
              ]
              ++ [ server ]
            );
            Restart = "on-failure";
            RestartSec = "5s";
          };
        };
      };
    };
}
