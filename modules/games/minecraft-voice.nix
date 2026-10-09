{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: s: {
        jars.voicechat = cfg.artifacts.games-voicechat;
        inventory = [
          {
            name = "Simple Voice Chat";
            version = "2.6.24";
            installed = true;
          }
        ];
        statePaths = [ "/srv/games/minecraft/${id}/plugins/voicechat" ];
        templates."/srv/games/minecraft/${id}/plugins/voicechat/voicechat-server.properties".source =
          toString
            (
              (pkgs.formats.javaProperties { }).generate "voicechat-${id}.properties" {
                port = toString s.minecraft.voicechatPort;
                bind_address = "0.0.0.0";
                voice_host = "${lib.head s.hostnames}:${toString s.minecraft.voicechatPort}";
                force_voice_chat = "false";
                enable_groups = "true";
              }
            );
      }) servers;
    };
}
