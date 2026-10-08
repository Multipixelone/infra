{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      host = config.flake.nixosConfigurations.link;
      gameUnitNames = [
        "minecraft-server-survival"
        "minecraft-server-velocity"
        "podman-games-terraria"
      ];
      secretNames = [
        "games/minecraft/velocity-forwarding"
        "games/minecraft/floodgate-key"
        "games/minecraft/survival-rcon"
        "games/terraria/terraria-password"
        "games/restic-password"
      ];
      missing =
        (host.extendModules {
          modules = [ { infra.games.secretFiles = lib.mkForce { }; } ];
        }).config;
      enabled =
        (host.extendModules {
          modules = [
            {
              infra.games.secretFiles = lib.mkForce (lib.genAttrs secretNames (_: ./tests/fixture.age));
              infra.games.backup.enable = lib.mkForce true;
            }
          ];
        }).config;
      without =
        (host.extendModules {
          modules = [ { infra.games.servers = lib.mkForce { }; } ];
        }).config;
      discovered =
        (host.extendModules {
          modules = [
            {
              infra.games.servers = lib.mkForce (
                host.config.infra.games.servers
                // {
                  creative = host.config.infra.games.servers.survival // {
                    displayName = "Creative";
                    hostnames = [ "creative.mc.finnrut.is" ];
                    minecraft = host.config.infra.games.servers.survival.minecraft // {
                      proxyPort = 25576;
                      serverPort = 25577;
                      rconPort = 25585;
                    };
                  };
                }
              );
              infra.games.secretFiles = lib.mkForce { };
            }
          ];
        }).config;
      project = cfg: {
        manifest = builtins.fromJSON cfg.environment.etc."games/manifest.json".text;
        units = lib.genAttrs gameUnitNames (name: {
          inherit (cfg.systemd.services.${name}) enable;
          preStart = cfg.systemd.services.${name}.serviceConfig.ExecStartPre or [ ];
          stop = cfg.systemd.services.${name}.serviceConfig.ExecStop or [ ];
          memoryMax = cfg.systemd.services.${name}.serviceConfig.MemoryMax;
          slice = cfg.systemd.services.${name}.serviceConfig.Slice;
          stopTimeout = cfg.systemd.services.${name}.serviceConfig.TimeoutStopSec or null;
        });
        polkit = cfg.security.polkit.extraConfig;
        dashboardUser = {
          inherit (cfg.users.users.games-dashboard) isSystemUser extraGroups;
          group = cfg.users.users.games-dashboard.group;
        };
        gameSecrets = lib.filter (name: builtins.hasAttr name cfg.age.secrets) secretNames;
        tcp = cfg.networking.firewall.allowedTCPPorts;
        udp = cfg.networking.firewall.allowedUDPPorts;
        batch = cfg.systemd.slices.batch-beets.sliceConfig;
      };
      fixtureData = {
        missing = project missing;
        enabled = project enabled;
        discovery = builtins.fromJSON discovered.environment.etc."games/manifest.json".text;
        baselineTCP = without.networking.firewall.allowedTCPPorts;
        baselineUDP = without.networking.firewall.allowedUDPPorts;
        baselineBatch = without.systemd.slices.batch-beets.sliceConfig;
        gamesSlice = enabled.systemd.slices.games.sliceConfig;
        containerOptions = enabled.virtualisation.oci-containers.containers.games-terraria.extraOptions;
        backupTimers = lib.genAttrs [ "survival" "terraria" ] (
          id: enabled.services.restic.backups."games-${id}".timerConfig
        );
        ddns = {
          inherit (host.config.services.cloudflare-dyndns)
            domains
            proxied
            ipv4
            ipv6
            ;
        };
        gamesPublished = config.servicePublication.applications ? games;
        productionFixtureSecrets = lib.any (path: path == ./tests/fixture.age) (
          lib.attrValues host.config.infra.games.secretFiles
        );
        rconMode = enabled.age.secrets."games/minecraft/survival-rcon".mode;
        rconGroup = enabled.age.secrets."games/minecraft/survival-rcon".group;
        privateSecretGroups = map (name: enabled.age.secrets.${name}.group) (
          lib.filter (name: !lib.hasSuffix "-rcon" name) secretNames
        );
      };
      fixture = pkgs.writeText "games-contract-fixtures.json" (builtins.toJSON fixtureData);
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      treefmt.settings.global.excludes = [ "modules/games/tests/fixture.age" ];
      checks = {
        games-lazymc = pkgs.runCommand "games-lazymc-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
          export PYTHONDONTWRITEBYTECODE=1
          python3 ${./tests/lazymc_test.py} ${lib.getExe host.config.infra.games.artifacts.games-lazymc}
          touch "$out"
        '';
        games-runtime =
          pkgs.runCommand "games-runtime-check"
            {
              nativeBuildInputs = [ pkgs.python3 ];
              RESTIC_EXE = lib.getExe pkgs.restic;
            }
            ''
              export PYTHONDONTWRITEBYTECODE=1
              export XDG_CACHE_HOME="$TMPDIR/cache"
              python3 ${./tests/runtime_test.py} ${./runtime.py}
              touch "$out"
            '';
        games-contract =
          pkgs.runCommand "games-contract-check"
            {
              nativeBuildInputs = [ pkgs.python3 ];
              passthru = { inherit fixtureData; };
            }
            ''
              python3 - ${fixture} <<'PY'
              import json, re, sys
              data = json.load(open(sys.argv[1]))
              units = {"minecraft-server-survival.service", "minecraft-server-velocity.service", "podman-games-terraria.service"}
              for name in ("missing", "enabled"):
                  fixture = data[name]
                  manifest = fixture["manifest"]
                  assert manifest["schemaVersion"] == 1 and manifest["host"] == "link"
                  servers = {server["id"]: server for server in manifest["servers"]}
                  assert set(servers) == {"survival", "terraria"}
                  assert servers["survival"]["wakeOnJoin"] and not servers["terraria"]["wakeOnJoin"]
                  assert {endpoint["port"] for server in servers.values() for endpoint in server["public"]} == {25565, 19132, 7777}
                  assert all(server["console"]["command"] == ["games-console", server["id"]] for server in servers.values())
                  expected = name == "enabled"
                  assert all(server["available"] == expected for server in servers.values())
                  assert all(server["backup"]["enabled"] == expected for server in servers.values())
                  assert all(unit["enable"] == expected for unit in fixture["units"].values())
                  assert all(unit["slice"] == "games.slice" for unit in fixture["units"].values())
                  assert fixture["units"]["minecraft-server-survival"]["memoryMax"] == "6G"
                  assert fixture["units"]["minecraft-server-survival"]["stopTimeout"] == 180
                  assert fixture["units"]["minecraft-server-velocity"]["memoryMax"] == "1G"
                  assert fixture["units"]["podman-games-terraria"]["memoryMax"] == "4G"
                  allowlists = [set(json.loads(value)) for value in re.findall(r'(\[[^\n]*\])\.indexOf\(unit\)', fixture["polkit"])]
                  assert allowlists[0] == units
                  assert allowlists[1] == ({"restic-backups-games-survival.service", "restic-backups-games-terraria.service"} if expected else set())
                  assert 'subject.user !== "games-dashboard"' in fixture["polkit"]
                  assert '["start", "stop", "restart"].indexOf(verb)' in fixture["polkit"]
                  assert 'verb === "start"' in fixture["polkit"] and 'return polkit.Result.NO' in fixture["polkit"]
                  assert fixture["dashboardUser"] == {"isSystemUser": True, "extraGroups": [], "group": "games-dashboard"}
                  assert fixture["batch"] == data["baselineBatch"]
              assert data["missing"]["gameSecrets"] == []
              assert len(data["enabled"]["gameSecrets"]) == 5
              pre = data["enabled"]["units"]["minecraft-server-survival"]["preStart"]
              assert len(pre) == 3 and "games-prechange" in pre[0] and "survival-start-pre" in pre[1] and "games-prepare" in pre[2]
              pre = data["enabled"]["units"]["podman-games-terraria"]["preStart"]
              assert "games-prechange" in pre[0] and "games-prepare" in pre[1] and "pre-start" in pre[2]
              stop = data["enabled"]["units"]["podman-games-terraria"]["stop"]
              assert "games-container-stop" in stop[0] and "stop" in stop[1]
              assert set(data["missing"]["tcp"]) - set(data["baselineTCP"]) == {7777}  # ATM10 already opens 25565.
              assert set(data["missing"]["udp"]) - set(data["baselineUDP"]) == {19132}
              assert {25565, 7777} <= set(data["missing"]["tcp"])
              assert not ({25566, 25567, 25575} & (set(data["missing"]["tcp"]) | set(data["missing"]["udp"])))
              assert {"--network=host", "--cgroup-parent=games.slice", "--memory=4g", "--memory-swap=4g"} <= set(data["containerOptions"])
              assert data["gamesSlice"]["CPUWeight"] > data["baselineBatch"]["CPUWeight"]
              assert data["backupTimers"]["survival"]["OnCalendar"] == "00:30"
              assert data["backupTimers"]["terraria"]["OnCalendar"] == "00:40"
              assert all(timer["RandomizedDelaySec"] == "2m" for timer in data["backupTimers"].values())
              assert set(data["ddns"]["domains"]) == {"wg.finnrut.is", "mc.finnrut.is", "survival.mc.finnrut.is", "terraria.finnrut.is"}
              assert not data["ddns"]["proxied"] and data["ddns"]["ipv4"] and not data["ddns"]["ipv6"]
              assert not data["gamesPublished"] and not data["productionFixtureSecrets"]
              assert data["rconMode"] == "0440" and data["rconGroup"] == "games-dashboard"
              assert "games-dashboard" not in data["privateSecretGroups"]
              assert {server["id"] for server in data["discovery"]["servers"]} == {"creative", "survival", "terraria"}
              print("Game manifest, secret gates, controls, hooks, resources, DNS, and firewall contract passed")
              PY
              touch "$out"
            '';
      };
    };
}
