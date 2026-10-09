{ lib, ... }: {
  flake.modules.nixos.games-minecraft = { pkgs, ... }: {
    infra.games.artifacts = {
      games-skinsrestorer = pkgs.fetchurl {
        name = "skinsrestorer-15.12.6.jar";
        url = "https://github.com/SkinsRestorer/SkinsRestorer/releases/download/15.12.6/SkinsRestorer.jar";
        sha256 = "a85b4a370f988741c9a38f4d0498262edacbf3220314790ac1c127461996359c";
      };
      games-bluemap = pkgs.fetchurl {
        name = "bluemap-5.28.jar";
        url = "https://github.com/BlueMap-Minecraft/BlueMap/releases/download/v5.28/bluemap-5.28-paper.jar";
        sha256 = "4cfb4a9963132d5be0a9db031a28a98e9df92deed37ebb0756d3a7dd8721ab98";
      };
      games-minimotd = pkgs.fetchurl {
        name = "minimotd-2.2.5.jar";
        url = "https://cdn.modrinth.com/data/16vhQOQN/versions/B4VwaP78/minimotd-velocity-2.2.5.jar";
        sha256 = "b5d01ae7596b951f842d105d8a70552bf75761ced2bd413739d627c59b058ed5";
      };
      games-luckperms-paper = pkgs.fetchurl {
        name = "luckperms-paper-5.5.71.jar";
        url = "https://cdn.modrinth.com/data/Vebnzrzj/versions/b0mk8uS6/LuckPerms-Bukkit-5.5.71.jar";
        sha256 = "49cecb66fa1fd22a133039a490e9c1e5095a238e7cd66eb9d2a16fe6c897550d";
      };
      games-luckperms-velocity = pkgs.fetchurl {
        name = "luckperms-velocity-5.5.71.jar";
        url = "https://cdn.modrinth.com/data/Vebnzrzj/versions/tamnmXad/LuckPerms-Velocity-5.5.71.jar";
        sha256 = "a3ac92ef4e29fd87a4d706dc92445fd946f1caf1d33526ca18422a62554fa18a";
      };
      games-voicechat = pkgs.fetchurl {
        name = "voicechat-2.6.24.jar";
        url = "https://cdn.modrinth.com/data/9eGKb6K1/versions/EJth3OAr/voicechat-bukkit-2.6.24.jar";
        sha256 = "af3d4e2ad318d3065959248c1370ae32a619752cb4d2a4fec2f7a79b10067769";
      };
      games-discordsrv = pkgs.fetchurl {
        name = "discordsrv-1.30.5.jar";
        url = "https://cdn.modrinth.com/data/UmLGoGij/versions/ATlquwiT/DiscordSRV-Build-1.30.5.jar";
        sha256 = "ef2fa1f2eb146c7c77412b7190a7dd33f1fc91282683fe45407739554c8aefef";
      };
      games-tickscope = pkgs.fetchurl {
        name = "tickscope-2.0.1.jar";
        url = "https://github.com/gzimbric/TickScope/releases/download/v2.0.1/TickScope-2.0.1.jar";
        sha256 = "4b789277f3a72d4b83b44a06ee3f902240d930f491e788659772c22cb9be23a8";
      };
      games-minecraft-client = pkgs.fetchurl {
        name = "minecraft-client-26.3.jar";
        url = "https://piston-data.mojang.com/v1/objects/e877b6a07acd633fb3bb475002175cec036e7b87/client.jar";
        sha256 = "4508d006323f24fa02876310c192d739af56516eb259000ac50f0909a68c9a2d";
      };
    };
    options.infra.games.minecraftPlugins = let
      pluginSet = lib.types.submodule { options = {
        jars = lib.mkOption { type = lib.types.attrsOf lib.types.package; default = {}; };
        templates = lib.mkOption { type = lib.types.attrs; default = {}; };
        statePaths = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
        secretNames = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
        inventory = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
      }; };
    in {
      proxy = lib.mkOption { type = pluginSet; default = {}; };
      backends = lib.mkOption { type = lib.types.attrsOf pluginSet; default = {}; };
    };
  };
}
