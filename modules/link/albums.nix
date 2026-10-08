{
  config,
  inputs,
  lib,
  withSystem,
  ...
}:
let
  owner = config.flake.meta.owner.username;
  stateDirectory = "/var/lib/beets-album-graph";
  coversDirectory = "${stateDirectory}/covers";
  cacheDirectory = "${stateDirectory}/cache";
  queryDirectory = "${cacheDirectory}/query";
  canonical = config.flake.servicePublicationInventory.applications.albums.canonical;
  publicationEnabled = config.servicePublication.rollout.enableLocalCutover;
  launchers = import ../../lib/album-graph-launchers.nix;
  snapshot =
    pkgs:
    pkgs.writers.writePython3Bin "beets-album-graph-snapshot" { flakeIgnore = [ "E501" ]; } (
      builtins.readFile ../../lib/album-graph-snapshot.py
    );
  # Shared with the HTTP fixture so it exercises the actual Origin and proxy
  # rules. Reuse the generated root ACL rather than adding an unguarded route.
  textProxy =
    { canonical, rootLocation }:
    {
      httpConfig = ''
        map $http_origin $album_graph_query_origin {
          default invalid;
          "" "";
          "https://${canonical}" "http://127.0.0.1:8765";
        }
      '';
      location = {
        inherit (rootLocation) proxyPass;
        # A location's own headers replace inherited headers. Avoid appending
        # nixpkgs' Host=$host after the localhost Host required by the server.
        recommendedProxySettings = false;
        extraConfig =
          rootLocation.extraConfig
          + "\n"
          + ''
            if ($album_graph_query_origin = invalid) {
              return 403;
            }
            client_max_body_size 4k;
            proxy_read_timeout 130s;
            proxy_cache off;
            proxy_set_header Host 127.0.0.1:8765;
            proxy_set_header Origin $album_graph_query_origin;
            proxy_set_header Connection "";
          '';
      };
    };
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
      rawBeets = withSystem pkgs.stdenv.hostPlatform.system (args: args.config.packages.beets-plugins);
      viewerPackage = inputs.beets-plugins.packages.${pkgs.stdenv.hostPlatform.system}.beets-album-graph;
      proxy = textProxy {
        inherit canonical;
        rootLocation = config.services.nginx.virtualHosts.${canonical}.locations."/";
      };
      viewer = pkgs.writeShellApplication {
        name = "beets-album-graph-serve";
        text = ''
          export BEETS_GRAPH_STATE=${lib.escapeShellArg stateDirectory}
          export BEETS_GRAPH_COVERS=${lib.escapeShellArg coversDirectory}
          export BEETS_GRAPH_CACHE=${lib.escapeShellArg cacheDirectory}
          # The packaged viewer supplies the absolute CPU --text-worker path.
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
          export BEETS_GRAPH_CACHE=${lib.escapeShellArg cacheDirectory}
          export BEETS_GRAPH_STORE=${lib.escapeShellArg store}
          export BEETS_GRAPH_LIBRARY=${lib.escapeShellArg home.programs.beets.settings.library}
          export BEETS_GRAPH_SNAPSHOT=${lib.escapeShellArg (lib.getExe (snapshot pkgs))}
          export BEETS_GRAPH_CONFIG=${lib.escapeShellArg "${beetsDirectory}/config.yaml"}
          export BEETS_GRAPH_LAUNCHER=${lib.escapeShellArg (lib.getExe rawBeets)}
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
        "d ${cacheDirectory} 2770 ${owner} album-graph - -"
        "d ${queryDirectory} 0700 album-graph album-graph - -"
      ];

      services.nginx = lib.mkIf publicationEnabled {
        commonHttpConfig = proxy.httpConfig;
        virtualHosts.${canonical}.locations."= /api/embed-text" = proxy.location;
      };

      systemd.services.beets-album-graph = {
        description = "Private album similarity graph viewer";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = hardening // {
          User = "album-graph";
          Group = "album-graph";
          # Phrase queries are interactive; the CPU child inherits this cgroup
          # and sandbox rather than competing inside the batch hierarchy.
          Slice = "system.slice";
          ExecStart = lib.getExe viewer;
          Restart = "on-failure";
          RestartSec = "5s";
          ProtectHome = true;
          # Includes the covers cache; the viewer cannot modify it.
          ReadOnlyPaths = [ stateDirectory ];
          # Upstream places only viewer runtime caches beneath query/. Keep
          # descriptor caches, graph JSON and covers immutable to this user.
          ReadWritePaths = [ queryDirectory ];
          # /nix/store remains readable, including the packaged CPU worker's
          # model link farm and its resolved checkpoint/tokenizer targets.
          RestrictAddressFamilies = [ "AF_INET" ];
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
          # Torch/oneDNN needs executable inference primitives (upstream MDWE
          # smoke). This exception is confined to the viewer and its CPU child.
          MemoryDenyWriteExecute = false;
          MemoryHigh = "2500M";
          MemoryMax = "3G";
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
            home.programs.beets.settings.library
            # Stored artwork paths resolve relative to /volume1/Media/Music.
            home.programs.beets.settings.directory
            "-${store}"
            "-${builtins.dirOf store}"
          ];
          ReadWritePaths = [
            # Covers are maintained in place, outside the temporary JSON staging.
            stateDirectory
          ];
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          Nice = 10;
          Slice = "system.slice";
          CPUWeight = 50;
          CPUQuota = "200%";
          IOWeight = 50;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
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
      fixtureProxy = textProxy {
        canonical = "albums.example.test";
        rootLocation = {
          proxyPass = "http://127.0.0.1:@BACKEND_PORT@";
          extraConfig = "allow 127.0.0.1;\ndeny all;\n";
        };
      };
      fixtureProxyConfig = pkgs.writeText "album-graph-proxy-fixture.conf" ''
        pid @ROOT@/nginx.pid;
        error_log stderr;
        events {}
        http {
          access_log off;
          client_body_temp_path @ROOT@/body;
          proxy_temp_path @ROOT@/proxy;
          ${fixtureProxy.httpConfig}
          server {
            listen 127.0.0.1:@PROXY_PORT@;
            location = /api/embed-text {
              proxy_pass ${fixtureProxy.location.proxyPass};
              ${fixtureProxy.location.extraConfig}
            }
          }
        }
      '';
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
              ${inputs.beets-plugins}/plugins/embed/beets_embed/covers.py \
              ${lib.getExe pkgs.nginx} ${fixtureProxyConfig} \
              ${inputs.beets-plugins}/plugins/embed/viewer/server.py \
              ${lib.getExe (snapshot pkgs)}
            python3 ${./tests/albums_snapshot_test.py} ${../../lib/album-graph-snapshot.py}
            touch "$out"
          '';
    };
}
