{ lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.openclaw-nixos-approval-notify =
        let
          target = pkgs.runCommand "nixos-system-link-notify-fixture" { } ''
            mkdir -p "$out/etc" "$out/bin"
            printf 'x86_64-linux\n' > "$out/system"
            printf 'link\n' > "$out/etc/hostname"
            ln -s ${pkgs.coreutils}/bin/true "$out/activate"
            ln -s ${pkgs.coreutils}/bin/true "$out/bin/switch-to-configuration"
          '';
          cli = pkgs.writeShellApplication {
            name = "openclaw";
            runtimeInputs = [ pkgs.python3 ];
            text = ''
              exec python3 ${./tests/openclaw_nixos_cli_fixture.py} "$@"
            '';
          };
          fixturePkgs = pkgs // {
            nvd = pkgs.writeShellApplication {
              name = "nvd";
              text = ''
                [[ ! -e /run/fixture-diff-fail ]] || exit 1
                echo 'fixture root-computed diff'
              '';
            };
            coreutils =
              let
                sync = pkgs.writeShellApplication {
                  name = "sync";
                  text = ''
                    if [[ -e /run/fixture-expire-on-sync && "$2" == */approved ]]; then
                      rm /run/fixture-expire-on-sync
                      ${pkgs.coreutils}/bin/date -s "@$(( $(${pkgs.coreutils}/bin/date +%s) + 1801 ))" >/dev/null
                    fi
                    if [[ -e /run/fixture-sync-file-fail && "$2" == */.approval.* ]] \
                      || [[ -e /run/fixture-sync-dir-fail && "$2" == */approved ]]; then
                      exit 1
                    fi
                    exec ${pkgs.coreutils}/bin/sync "$@"
                  '';
                };
              in
              pkgs.symlinkJoin {
                name = "coreutils-approval-fixture";
                paths = [ pkgs.coreutils ];
                postBuild = ''
                  rm "$out/bin/sync"
                  ln -s ${sync}/bin/sync "$out/bin/sync"
                '';
              };

          };
          gateModule =
            (import ./openclaw-nixos-activation.nix { inherit lib; }).configurations.nixos.link.module;
          test = pkgs.testers.runNixOSTest {
            name = "openclaw-nixos-approval-notify";
            # QEMU's TCG fallback lets agents without /dev/kvm run this check.
            requiredFeatures.kvm = false;
            nodes.machine =
              { pkgs, ... }:
              {
                imports = [
                  (args: gateModule (args // { pkgs = fixturePkgs; }))
                ];
                networking.hostName = "link";
                users.users.tunnel = {
                  isNormalUser = true;
                  uid = 1000;
                };
                security.sudo.enable = true;
                security.sudo-rs.enable = false;
                # Only this isolated fixture grants passwordless approval, so
                # the success test exercises real sudo's invoking-user metadata.
                security.sudo.extraRules = [
                  {
                    users = [ "tunnel" ];
                    commands = [
                      {
                        command = "/run/current-system/sw/bin/openclaw-nixos-approve";
                        options = [ "NOPASSWD" ];
                      }
                    ];
                  }
                ];
                services.timesyncd.enable = false;
                nix.settings.experimental-features = [ "nix-command" ];
                system.extraDependencies = [ target ];
                environment.etc."notify-fixture-target".text = toString target;
                environment.systemPackages = [
                  pkgs.python3
                  pkgs.strace
                ];
                programs.nh.package = pkgs.writeShellApplication {
                  name = "nh";
                  text = ''
                    # No system activation ever occurs, even if a test regresses.
                    touch /run/fixture-activation-called
                    exit 1
                  '';
                };
                systemd.tmpfiles.rules = [
                  "d /home/tunnel/.npm-global 0755 tunnel users -"
                  "d /home/tunnel/.npm-global/bin 0755 tunnel users -"
                  "L+ /home/tunnel/.npm-global/bin/openclaw - - - - ${cli}/bin/openclaw"
                  "d /home/tunnel/.openclaw 0700 tunnel users -"
                ];
              };
            testScript = builtins.readFile ./tests/openclaw_nixos_approval_test.py;
          };
        in
        test;
    };
}
