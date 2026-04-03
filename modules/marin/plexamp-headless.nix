{
  withSystem,
  rootPath,
  ...
}:
{
  nixpkgs.config.allowUnfreePackages = [ "plexamp-headless" ];

  perSystem =
    { pkgs, ... }:
    {
      packages.plexamp-headless = pkgs.callPackage "${rootPath}/pkgs/plexamp-headless" { };
    };

  configurations.nixos.marin.module =
    { pkgs, lib, ... }:
    let
      plexamp-headless = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.plexamp-headless
      );
      plexamp-url = "https://plexamp.plex.tv/headless/Plexamp-Linux-headless-v4.13.0.tar.bz2";
      install-plexamp-headless = pkgs.writeShellScript "install-plexamp-headless" ''
        set -euo pipefail

        state_dir=/var/lib/plexamp-headless
        target_dir="$state_dir/plexamp"
        target_index="$target_dir/js/index.js"

        if [ -f "$target_index" ]; then
          exit 0
        fi

        tmpdir="$(${pkgs.coreutils}/bin/mktemp -d)"
        trap '${pkgs.coreutils}/bin/rm -rf "$tmpdir"' EXIT

        archive="$tmpdir/plexamp.tar.bz2"
        ${pkgs.curl}/bin/curl -fsSL "${plexamp-url}" -o "$archive"

        extract_dir="$tmpdir/extracted"
        ${pkgs.coreutils}/bin/mkdir -p "$extract_dir"
        ${pkgs.gnutar}/bin/tar -xjf "$archive" -C "$extract_dir"

        staged_dir="$extract_dir/plexamp"
        if [ ! -f "$staged_dir/js/index.js" ]; then
          echo "plexamp-headless archive missing plexamp/js/index.js" >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/rm -rf "$state_dir/.plexamp.new"
        ${pkgs.coreutils}/bin/mv "$staged_dir" "$state_dir/.plexamp.new"
        ${pkgs.coreutils}/bin/chown -R plexamp-headless:plexamp-headless "$state_dir/.plexamp.new"
        ${pkgs.coreutils}/bin/chmod -R u+rwX "$state_dir/.plexamp.new"

        ${pkgs.coreutils}/bin/rm -rf "$target_dir"
        ${pkgs.coreutils}/bin/mv "$state_dir/.plexamp.new" "$target_dir"
      '';
    in
    {
      users.users.plexamp-headless = {
        isSystemUser = true;
        group = "plexamp-headless";
        home = "/var/lib/plexamp-headless";
      };
      users.groups.plexamp-headless = { };

      systemd.services.plexamp-headless = {
        description = "Plexamp Headless";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          User = "plexamp-headless";
          Group = "plexamp-headless";
          StateDirectory = "plexamp-headless";
          Environment = [
            "HOME=/var/lib/plexamp-headless"
            "XDG_CONFIG_HOME=/var/lib/plexamp-headless/.config"
          ];
          ExecStartPre = [ install-plexamp-headless ];
          ExecStart = lib.getExe plexamp-headless;
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    };
}
