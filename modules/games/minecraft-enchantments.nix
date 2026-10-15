{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      # Preserve the release's complete shop/enchantment defaults. Both files
      # are managed, so an upgrade cannot silently restore disabled enchants.
      configuration =
        pkgs.runCommand "crazyenchantments-26.3-ed9d9ab-config"
          { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ]; }
          ''
            mkdir -p "$out"
            python3 - ${cfg.artifacts.games-crazyenchantments} "$out" <<'PY'
            import pathlib, sys, zipfile
            import yaml
            with zipfile.ZipFile(sys.argv[1]) as jar:
                config = yaml.safe_load(jar.read("config.yml"))
                enchants = yaml.safe_load(jar.read("Enchantments.yml"))
            settings = config["Settings"]
            settings["Toggle-Metrics"] = False
            options = settings["EnchantmentOptions"]
            options["UnSafe-Enchantments"] = False
            options["Limit"]["Default-Limit"] = 3
            options["Right-Click-Enchantment-Table"] = False
            # Costs are stored separately from the utility's GUI options.
            for name, cost in settings["Costs"].items():
                if cost["Currency"] == "Vault":
                    section = settings["Dust"][name] if name in ("SuccessDust", "DestroyDust") else settings[name]
                    section["InGUI"] = False
            for category in config["Categories"].values():
                if category.get("Currency") == "Vault":
                    category["InGUI"] = False
                if category["LostBook"]["Currency"] == "Vault":
                    category["LostBook"]["InGUI"] = False
            for name in ("VeinMiner", "Blast"):
                enchants["Enchantments"][name]["Enabled"] = False
            for name, value in (("config.yml", config), ("Enchantments.yml", enchants)):
                (pathlib.Path(sys.argv[2]) / name).write_text(yaml.safe_dump(value, sort_keys=False))
            PY
          '';
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.crazyenchantments = cfg.artifacts.games-crazyenchantments;
        templates =
          lib.genAttrs
            (map (name: "/srv/games/minecraft/${id}/plugins/CrazyEnchantments/${name}") [
              "config.yml"
              "Enchantments.yml"
            ])
            (path: {
              source = "${configuration}/${builtins.baseNameOf path}";
            });
        statePaths = [ "/srv/games/minecraft/${id}/plugins/CrazyEnchantments" ];
        inventory = [
          {
            name = "CrazyEnchantments";
            version = "26.3-ed9d9ab";
            installed = true;
          }
        ];
      }) servers;
    };
}
