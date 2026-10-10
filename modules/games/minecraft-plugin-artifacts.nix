{ lib, ... }: {
  flake.modules.nixos.games-minecraft = { pkgs, ... }: {
    config.infra.games.artifacts = {
      games-fawe = pkgs.fetchurl {
        # 2.16.1's FluidState.is(Fluid) call fails on pinned Paper 26.3 build 159;
        # 2.16.0 uses is(Object) and passes the isolated runtime checks.
        name = "fastasyncworldedit-paper-2.16.0.jar";
        url = "https://cdn.modrinth.com/data/z4HZZnLr/versions/U2dcKa9T/FastAsyncWorldEdit-Paper-2.16.0.jar";
        sha256 = "1a3cf8178f22d97fe78db100c7d50ebe57acdb59f3df1a972c29761ebba6f0cd";
      };
      games-voxelsniper = pkgs.fetchurl {
        name = "fastasyncvoxelsniper-3.2.5.jar";
        url = "https://cdn.modrinth.com/data/D7XBSI1y/versions/AnYq3r1h/fastasyncvoxelsniper-3.2.5.jar";
        sha256 = "485e8b5694df0dbda96038049cb9a73bee4e37d9ec8c7f589af5e8a590fca2e9";
      };
      games-worldedit-visualizer = pkgs.fetchurl {
        name = "worldeditselectionvisualizer-2.1.10.jar";
        url = "https://github.com/MrMicky-FR/WorldEditSelectionVisualizer/releases/download/v2.1.10/WorldEditSelectionVisualizer-2.1.10.jar";
        sha256 = "5897fd8de2fafa3fadcde94bb4e48d69047817548bcb9190254190a596509bd2";
      };
      games-openinv = pkgs.fetchurl {
        name = "openinv-5.3.5.jar";
        url = "https://github.com/Jikoo/OpenInv/releases/download/5.3.5/OpenInv.jar";
        sha256 = "7b37f3909a75dd8c1d81aed52fcf66cf16cc266dcdb607b3df600e7644d48c5e";
      };
      games-carbon = pkgs.fetchurl {
        name = "carbonchat-paper-3.0.0-beta.39.jar";
        url = "https://github.com/Hexaoxide/Carbon/releases/download/v3.0.0-beta.39/carbonchat-paper-3.0.0-beta.39.jar";
        sha256 = "bc79bba5b67f4ceeca531775970ce6e2922ddff87999e12e463cdffa8e6fe4f5";
      };
      games-miniplaceholders = pkgs.fetchurl {
        name = "miniplaceholders-paper-3.2.0.jar";
        url = "https://github.com/MiniPlaceholders/MiniPlaceholders/releases/download/3.2.0/MiniPlaceholders-Paper-3.2.0.jar";
        sha256 = "559f40c6d5e9eaad49fb5fb67c8e9d5163dc9ab22753eb709792d52989fb626a";
      };
      games-miniplaceholders-luckperms = pkgs.fetchurl {
        name = "miniplaceholders-luckperms-2.1.0.jar";
        url = "https://github.com/MiniPlaceholders/LuckPerms-Expansion/releases/download/2.1.0/LuckPerms-Expansion-2.1.0.jar";
        sha256 = "5c788b69b63c4e5f54c8fbe8580ffba1d3d09bfd43a6d3b4232665ef7a15099a";
      };
      games-flectonepulse = pkgs.fetchurl {
        name = "flectonepulse-bukkit-1.14.0.jar";
        url = "https://github.com/Flectone/FlectonePulse/releases/download/v1.14.0/FlectonePulse-Bukkit-1.14.0.jar";
        sha256 = "96e4d2f5848db107ba200f50e1d233e580e79b0ed44835b88ebbc1daccf6f692";
      };
      games-chunky = pkgs.fetchurl {
        name = "chunky-bukkit-1.5.3.jar";
        url = "https://cdn.modrinth.com/data/fALzjamp/versions/MdY6JATr/Chunky-Bukkit-1.5.3.jar";
        sha256 = "530d2c7430a96a39957391b7088be144daa3108f7665896d1c23aa8dd4af32f3";
      };
      games-huskhomes = pkgs.fetchurl {
        name = "huskhomes-paper-4.11-9ed80cc.jar";
        url = "https://cdn.modrinth.com/data/J6U9o3JG/versions/eXHdkjXf/HuskHomes-Paper-4.11-9ed80cc.jar";
        sha256 = "86591445fffc24533bc3e76de5df01cdde50011c80d88a45d0eb3fe123d617ab";
      };
      games-axgraves = pkgs.fetchurl {
        name = "axgraves-1.32.1.jar";
        url = "https://hangarcdn.papermc.io/plugins/Artillex-Studios/AxGraves/versions/1.32.1/PAPER/AxGraves-1.32.1.jar";
        sha256 = "06358594c2ee3032bdddbe473b7605c23b48631c6b41161f1b0f63db992dfc78";
      };
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
      games-bluemap-floodgate = pkgs.fetchurl {
        # Paper plugin (not a native packs addon); no backend Floodgate needed.
        # Java 21/API 1.17, BlueMap API 2.7.7; linkage checked on 26.3/5.28.
        name = "bluemap-floodgate-3.6.jar";
        url = "https://github.com/TechnicJelle/BlueMapFloodgate/releases/download/v3.6/BlueMapFloodgate-3.6.jar";
        sha256 = "bff1a585a59a88ebf7944b372d0654db8d99af0d8d8ed357272a96b5b7760f27";
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
      games-vault = pkgs.fetchurl {
        name = "vault-1.7.3.jar";
        url = "https://github.com/MilkBowl/Vault/releases/download/1.7.3/Vault.jar";
        sha256 = "a6b5ed97f43a5cf5bbaf00a7c8cd23c5afc9bd003f849875af8b36e6cf77d01d";
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
    options.infra.games.minecraftPlugins =
      let
        pluginSet = lib.types.submodule {
          options = {
            jars = lib.mkOption {
              type = lib.types.attrsOf lib.types.package;
              default = { };
            };
            templates = lib.mkOption {
              type = lib.types.attrs;
              default = { };
            };
            statePaths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            secretNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            inventory = lib.mkOption {
              type = lib.types.listOf lib.types.attrs;
              default = [ ];
            };
          };
        };
      in
      {
        proxy = lib.mkOption {
          type = pluginSet;
          default = { };
        };
        backends = lib.mkOption {
          type = lib.types.attrsOf pluginSet;
          default = { };
        };
      };
  };
}
