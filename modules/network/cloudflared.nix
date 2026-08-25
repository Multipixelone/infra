{
  lib,
  inputs,
  ...
}:
{
  flake.modules.nixos.cloudflared =
    { pkgs, config, ... }:
    let
      _ = lib.getExe;
    in
    {
      users.users.cloudflared = {
        group = "cloudflared";
        isSystemUser = true;
      };
      users.groups.cloudflared = { };
      systemd.services.cf-tunnel = {
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "dnscrypt-proxy.service"
        ];
        serviceConfig = {
          # this is gross
          ExecStart = ''${_ pkgs.bash} -c "${_ pkgs.cloudflared} tunnel --no-autoupdate run --token $(${lib.getExe' pkgs.coreutils "cat"} ${config.age.secrets."cf".path})"'';
          Restart = "always";
          User = "cloudflared";
          Group = "cloudflared";
        };
      };
      age.secrets = {
        "cf" = {
          file = "${inputs.secrets}/cloudflare/${config.networking.hostName}.age";
          mode = "440";
          owner = "cloudflared";
          group = "cloudflared";
        };
      };
    };
}
