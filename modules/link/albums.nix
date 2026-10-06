{
  config,
  inputs,
  lib,
  ...
}:
let
  owner = config.flake.meta.owner.username;
  stateDirectory = "/var/lib/beets-album-graph";
  coversDirectory = "${stateDirectory}/covers";
  launchers = import ../../lib/album-graph-launchers.nix;
in
{
  servicePublication.applications.albums = {
    site = "nyc";
    public = false;
    homepage = {
      name = "Albums";
      group = "Media";
      description = "Private album similarity graph";
      icon = "mdi-graph";
    };
    nginx.extraConfig = ''
      if ($args = "") {
        rewrite ^/$ /?data=data.json redirect;
      }
    '';
    routes.root = {
      backend = {
        host = "link";
        port = 8765;
      };
      # The viewer binds only to loopback; do not inherit the site's Impa proxy.
      proxy.host = "link";
      health = {
        path = "/index.html";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      home = config.home-manager.users.${owner};
      beetsDirectory = "${home.xdg.configHome}/beets";
      store = home.programs.beets.settings.embed.store;
      viewerPackage = inputs.beets-plugins.packages.${pkgs.stdenv.hostPlatform.system}.beets-album-graph;
      viewer = pkgs.writeShellApplication {
        name = "beets-album-graph-serve";
        text = ''
          export BEETS_GRAPH_STATE=${lib.escapeShellArg stateDirectory}
          export BEETS_GRAPH_COVERS=${lib.escapeShellArg coversDirectory}
          export BEETS_GRAPH_VIEWER=${lib.escapeShellArg (lib.getExe viewerPackage)}
          ${launchers.viewer}
        '';
      };
      exportGraph = pkgs.writeShellApplication {
        name = "beets-album-graph-export";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          export BEETS_GRAPH_STATE=${lib.escapeShellArg stateDirectory}
          export BEETS_GRAPH_COVERS=${lib.escapeShellArg coversDirectory}
          export BEETS_GRAPH_STORE=${lib.escapeShellArg store}
          export BEETS_GRAPH_CONFIG=${lib.escapeShellArg "${beetsDirectory}/config.yaml"}
          export BEETS_GRAPH_LAUNCHER=${lib.escapeShellArg (lib.getExe home.programs.beets.package)}
          ${launchers.export}
        '';
      };
      storeAvailable = pkgs.writeShellApplication {
        name = "beets-album-graph-store-available";
        text = ''
          if [[ ! -f ${lib.escapeShellArg store} ]]; then
            echo ${lib.escapeShellArg "Album graph export skipped: embeddings store is missing: ${store}"}
            exit 1
          fi
        '';
      };
      hardening = {
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    in
    {
      # Preserve the plugin's default, but make exporter/store agreement explicit.
      home-manager.users.${owner}.programs.beets.settings.embed.store =
        "${home.xdg.dataHome}/beets/embeddings.sqlite3";

      users.users.album-graph = {
        isSystemUser = true;
        group = "album-graph";
      };
      users.groups.album-graph = { };
      systemd.tmpfiles.rules = [
        "d ${stateDirectory} 0750 ${owner} album-graph - -"
        "d ${coversDirectory} 0750 ${owner} album-graph - -"
      ];

      systemd.services.beets-album-graph = {
        description = "Private album similarity graph viewer";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = hardening // {
          User = "album-graph";
          Group = "album-graph";
          ExecStart = lib.getExe viewer;
          Restart = "on-failure";
          RestartSec = "5s";
          ProtectHome = true;
          # Includes the covers cache; the viewer cannot modify it.
          ReadOnlyPaths = [ stateDirectory ];
          RestrictAddressFamilies = [ "AF_INET" ];
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
          MemoryDenyWriteExecute = true;
          UMask = "0077";
        };
      };

      # Manual refresh: sudo systemctl start beets-album-graph-export.service
      systemd.services.beets-album-graph-export = {
        description = "Export read-only album embeddings and play counts";
        after = [ "systemd-tmpfiles-setup.service" ];
        environment = {
          HOME = home.home.homeDirectory;
          BEETSDIR = beetsDirectory;
          XDG_CONFIG_HOME = home.xdg.configHome;
          XDG_DATA_HOME = home.xdg.dataHome;
          XDG_CACHE_HOME = "/tmp";
        };
        serviceConfig = hardening // {
          Type = "oneshot";
          User = owner;
          Group = "album-graph";
          ExecCondition = lib.getExe storeAvailable;
          ExecStart = lib.getExe exportGraph;
          # Only the fixed post-export restart runs privileged. ExecCondition
          # skips this too when the store is absent, preserving file-picker mode.
          ExecStartPost = "+${pkgs.systemd}/bin/systemctl try-restart beets-album-graph.service";
          TimeoutStartSec = "30m";
          Restart = "no";
          ProtectHome = "read-only";
          ReadOnlyPaths = [
            beetsDirectory
            # Stored artwork paths resolve relative to /volume1/Media/Music.
            home.programs.beets.settings.directory
            "-${store}"
          ];
          ReadWritePaths = [
            # Covers are maintained in place, outside the temporary JSON staging.
            stateDirectory
            "-${beetsDirectory}/.import.lock"
          ];
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          Nice = 10;
          CPUWeight = 10;
          IOSchedulingClass = "idle";
          UMask = "0027";
        };
      };

      systemd.timers.beets-album-graph-export = {
        description = "Refresh album graph after nightly analysis and play-count imports";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 11:00:00 America/New_York";
          Persistent = true;
        };
      };
    };

  perSystem =
    { pkgs, ... }:
    let
      fixtureExport = pkgs.writeShellApplication {
        name = "album-graph-fixture-export";
        runtimeInputs = [ pkgs.coreutils ];
        text = launchers.export;
      };
      fixtureViewer = pkgs.writeShellApplication {
        name = "album-graph-fixture-viewer";
        text = launchers.viewer;
      };
      fixturePython = pkgs.python3.withPackages (packages: [ packages.pillow ]);
    in
    {
      checks.beets-album-graph-host =
        pkgs.runCommand "beets-album-graph-host-check"
          {
            nativeBuildInputs = [
              fixturePython
            ];
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            python3 ${./tests/albums_test.py} \
              ${lib.getExe fixtureExport} ${lib.getExe fixtureViewer} \
              ${inputs.beets-plugins}/plugins/embed/beets_embed/covers.py
            touch "$out"
          '';
    };
}
