{
  config,
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      cfg = config.flake.nixosConfigurations.link.config;
      hm = cfg.home-manager.users.tunnel;
      source = "${inputs.secrets}/grafana/media.age";
      sourceAvailable = builtins.pathExists source;
      original = cfg.age.secrets.media-observability or null;
      copy = cfg.age.secrets.openclaw-media or null;
      companion = hm.xdg.configFile."openclaw/gateway.env" or null;
      gateway = hm.systemd.user.services.openclaw-gateway.Service;
      metadata = secret: {
        file = toString secret.file;
        inherit (secret)
          path
          owner
          group
          mode
          ;
      };
      originalPath = "/run/agenix/media-observability";
      copyPath = "/run/agenix/openclaw-media";
      contract =
        if sourceAvailable then
          original != null
          && copy != null
          && companion != null
          &&
            metadata original == {
              file = source;
              path = originalPath;
              owner = "root";
              group = "root";
              mode = "0400";
            }
          &&
            metadata copy == {
              file = source;
              path = copyPath;
              owner = "tunnel";
              group = "users";
              mode = "0400";
            }
          && hm.home.homeDirectory == "/home/tunnel"
          && hm.xdg.configHome == "/home/tunnel/.config"
          && lib.elem "HOME=/home/tunnel" gateway.Environment
          && lib.elem "OPENCLAW_STATE_DIR=/home/tunnel/.openclaw" gateway.Environment
          && gateway.WorkingDirectory == "/home/tunnel/.openclaw"
          && cfg.systemd.services.homepage-dashboard.serviceConfig.EnvironmentFile == [ originalPath ]
          &&
            lib.all
              (
                container:
                cfg.virtualisation.oci-containers.containers.${container}.environmentFiles == [ originalPath ]
              )
              [
                "scraparr"
                "tautulli-exporter"
              ]
        else
          original == null && copy == null && companion == null;
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.openclaw-media-credentials =
        assert lib.assertMsg contract
          "OpenClaw media credential ownership, native dotenv wiring, or original consumers regressed";
        pkgs.runCommand "openclaw-media-credentials"
          {
            companionSource = if sourceAvailable then companion.source else "";
          }
          ''
            ${lib.optionalString sourceAvailable ''
              test -L "$companionSource"
              test "$(readlink "$companionSource")" = ${lib.escapeShellArg copyPath}
            ''}
            touch "$out"
          '';
    };
}
