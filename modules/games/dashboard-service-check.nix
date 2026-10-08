{ config, lib, ... }:
let
  infra = config;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.games-dashboard-service = pkgs.testers.runNixOSTest {
        name = "games-dashboard-service";
        nodes.machine = { lib, pkgs, ... }: {
          imports = [
            infra.flake.modules.nixos.games-base
            infra.flake.modules.nixos.games-dashboard
            infra.flake.modules.nixos.games-dashboard-service
          ];
          # games-base declares age.secrets; this fixture needs no decryption.
          options.age.secrets = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          config = {
            networking.hostName = "link";
            security.polkit.enable = true;
            security.sudo.enable = true;
            security.sudo-rs.enable = false;
            environment.systemPackages = [ pkgs.curl ];
            infra.games = {
              secretFiles = { };
              runtime.fixture = {
                game = "terraria-tmodloader";
                displayName = "Fixture";
                public = [ ];
                unit = "fixture-game.service";
                container = "fixture-game";
                dataDir = "/srv/games/fixture";
                worldPaths = [ ];
                wakeOnJoin = false;
                available = true;
                console.method = "container-inject";
                backup = false;
                secretNames = [ ];
                internalPorts = [ ];
                publicTCPPorts = [ ];
                publicUDPPorts = [ ];
                serverPort = 7777;
              };
            };
            systemd.services.fixture-game.serviceConfig.ExecStart =
              "${pkgs.python3}/bin/python3 ${pkgs.writeText "fixture-game.py" ''
                import time
                print("fixture-game-log-one", flush=True)
                print("fixture-game-log-two", flush=True)
                while True:
                    time.sleep(1)
              ''}";
            systemd.services.fixture-unrelated.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
        };
        testScript = ''
          import json

          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("games-dashboard.service")
          machine.wait_for_open_port(8780)
          assert json.loads(machine.succeed("curl --fail -s http://127.0.0.1:8780/healthz")) == {"status": "ok"}
          assert "127.0.0.1:8780" in machine.succeed("ss -ltn")
          assert "0.0.0.0:8780" not in machine.succeed("ss -ltn")
          pid = machine.succeed("systemctl show -p MainPID --value games-dashboard.service").strip()
          assert "NoNewPrivs:\t0" in machine.succeed(f"cat /proc/{pid}/status")
          origin = "-H 'Origin: https://games.nyc.finnrut.is'"
          for action in ("start", "restart"):
              value = json.loads(machine.succeed(f"curl --fail -s {origin} -X POST http://127.0.0.1:8780/api/servers/fixture/{action}"))
              assert value["status"]["state"] == "running"
          # An actual game journal reader runs THROUGH the production sandbox
          # and setuid sudo. A mocked runner could not catch NNP regressions.
          code, output = machine.execute("curl -sS --no-buffer --max-time 3 http://127.0.0.1:8780/api/servers/fixture/events")
          assert code == 28 and "fixture-game-log-one" in output and "fixture-game-log-two" in output, output
          machine.fail("runuser -u games-dashboard -- systemctl --no-ask-password start fixture-unrelated.service")
          machine.fail("runuser -u games-dashboard -- games-logs fixture-unrelated")
          machine.fail("runuser -u games-dashboard -- sudo -n journalctl -n 1")
          value = json.loads(machine.succeed(f"curl --fail -s {origin} -X POST http://127.0.0.1:8780/api/servers/fixture/stop"))
          assert value["status"]["state"] == "stopped"
          assert machine.succeed("curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8780/api/servers/fixture/start").strip() == "403"
        '';
      };
    };
}
