{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.games-backups-btrfs = pkgs.testers.runNixOSTest {
        name = "games-backups-btrfs";
        requiredFeatures.kvm = false;
        nodes.machine = { ... }: {
          virtualisation.emptyDiskImages = [ 1024 ];
          virtualisation.qemu.forceAccel = false;
          boot.supportedFilesystems = [ "btrfs" ];
          environment.systemPackages = [
            pkgs.btrfs-progs
            pkgs.restic
            pkgs.python3
            pkgs.util-linux
          ];
          systemd.services.fixture-paper = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
        };
        testScript = ''
          machine.start()
          machine.wait_for_unit("fixture-paper.service")
          machine.succeed("mkfs.btrfs -f /dev/vdb")
          machine.succeed("mkdir -p /mnt/btrfs /srv")
          machine.succeed("mount /dev/vdb /mnt/btrfs")
          machine.succeed("btrfs subvolume create /mnt/btrfs/srv")
          machine.succeed("mount -o subvol=srv /dev/vdb /srv")
          machine.succeed("PYTHONPATH=${pkgs.writeTextDir "minecraft_status.py" (builtins.readFile ./minecraft_status.py)} python3 -B ${./tests/backup_btrfs_test.py} ${./runtime.py} ${./online-restic.py}", timeout=300)
          machine.succeed("test -z \"$(ls -A /srv/.games-backup-snapshots)\"")
          machine.succeed("test -z \"$(find /srv/games/.state -name '*-online-backup.json')\"")
        '';
      };
    };
}
