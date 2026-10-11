{ lib, ... }:
{
  flake.modules.nixos.games-minecraft = {
    options.infra.games.minecraftRanks = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = "Shared staff badges, LuckPerms prefixes, weights, and name colors.";
      default = lib.mapAttrs (
        rank: style:
        style
        // lib.optionalAttrs (style ? glyph) {
          # Client-side translation preserves normal-font labels without the pack.
          # Carbon and TAB must retain this component until recipient delivery.
          prefix = "<${style.color}><hover:show_text:'${style.label}'><lang_or:infra.rank.${rank}:'[${style.label}]'></hover></${style.color}> ";
        }
      ) (builtins.fromJSON (builtins.readFile ./rank-icons.json));
    };
  };
}
