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
              proxy = {
                id = "velocity";
                unit = "fixture-velocity.service";
                available = true;
                serverPort = 25565;
              };
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
            systemd.services.fixture-velocity.serviceConfig.ExecStart =
              "${pkgs.python3}/bin/python3 ${pkgs.writeText "fixture-velocity.py" ''
                import socket
                import time
                from pathlib import Path
                if Path("/run/fixture-velocity-fail").exists():
                    raise SystemExit(1)
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 25565))
                    listener.listen()
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
          def shared_status():
              value = json.loads(machine.succeed("curl --fail -s http://127.0.0.1:8780/api/servers"))
              return value["sharedServices"][0]["status"]

          assert shared_status() == {
              "id": "velocity", "state": "stopped", "unitState": "inactive",
              "ready": False, "playersOnline": None, "available": True,
          }
          machine.succeed("systemctl start fixture-velocity.service")
          machine.wait_for_open_port(25565)
          assert shared_status()["state"] == "running" and shared_status()["ready"]
          machine.succeed("systemctl stop fixture-velocity.service")
          assert shared_status()["state"] == "stopped" and not shared_status()["ready"]
          machine.succeed("touch /run/fixture-velocity-fail")
          machine.execute("systemctl start fixture-velocity.service")
          machine.wait_until_succeeds("systemctl is-failed fixture-velocity.service")
          assert shared_status()["state"] == "failed" and not shared_status()["ready"]
          assert machine.succeed("curl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://games.nyc.finnrut.is' -X POST http://127.0.0.1:8780/api/servers/velocity/start").strip() == "404"
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
