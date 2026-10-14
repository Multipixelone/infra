{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      ranks = pkgs.writeText "minecraft-ranks.json" (builtins.toJSON cfg.minecraftRanks);
      pack = pkgs.runCommand "minecraft-rank-icons-26.3" { } ''
        ${pkgs.python3}/bin/python3 ${./minecraft-resource-pack.py} build ${cfg.artifacts.games-minecraft-client} ${ranks} ${./assets/discord.png} "$out"
      '';
      # The derivation path versions the URL without import-from-derivation.
      # nginx location keys cannot carry store dependencies; the alias below
      # retains the pack dependency, while this URL is only its public name.
      path = "/packs/${builtins.unsafeDiscardStringContext (builtins.baseNameOf pack)}.zip";
    in
    {
      options.infra.games.minecraftRankPackUrl = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "https://map.finnrut.is${path}";
        description = "Immutable HTTPS URL of the Java staff and chat icon pack.";
      };
      config = lib.mkIf (servers != { }) {
        infra.games.artifacts.games-rank-icons = pack;
        assertions = [
          {
            assertion = lib.all (s: s.minecraft.version == "26.3") (lib.attrValues servers);
            message = "Review the staff icon pack when upgrading Minecraft from 26.3.";
          }
        ];
        services.nginx.virtualHosts.minecraft-map-origin.locations."= ${path}" = {
          alias = "${pack}/rank-icons.zip";
          extraConfig = ''
            default_type application/zip;
            add_header Cache-Control "public, max-age=31536000, immutable" always;
            add_header X-Content-Type-Options nosniff always;
          '';
        };
      };
    };
}
