{ lib, ... }:
{
  flake.modules.nixos.games-tmodloader =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "terraria-tmodloader") cfg.servers;
      runtime = config.virtualisation.oci-containers.backend;
      secretName = id: "games/terraria/${id}-password";
      secretPath = id: "/run/agenix/${secretName id}";
      dir = id: "/srv/games/tmodloader/${id}";
      configPath = id: "/run/games/${id}/serverconfig.txt";
      icuMajor = lib.versions.major pkgs.icu.version;
      dotnetVersion = "8.0.31";
      dotnetArchive = pkgs.fetchurl {
        url = "https://builds.dotnet.microsoft.com/dotnet/Runtime/${dotnetVersion}/dotnet-runtime-${dotnetVersion}-linux-x64.tar.gz";
        hash = "sha256-4uOS7t1J/VpuugeNUIOD+pGRBZyzYsnZPPUz1SB7jbY=";
      };
      portableDotnet =
        pkgs.runCommand "games-tmodloader-dotnet-${dotnetVersion}"
          {
            nativeBuildInputs = [
              pkgs.gnutar
              pkgs.gzip
            ];
          }
          ''
            mkdir -p "$out"
            tar --extract --gzip --file ${dotnetArchive} --directory "$out" --no-same-owner
          '';
      runtimeConfig = pkgs.writeText "games-tmodloader.runtimeconfig.json" (
        builtins.toJSON {
          runtimeOptions = {
            tfm = "net8.0";
            framework = {
              name = "Microsoft.NETCore.App";
              version = dotnetVersion;
            };
            configProperties = {
              DEFAULT_STACK_SIZE = "400000";
              "System.Reflection.Metadata.MetadataUpdater.IsSupported" = false;
              "System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization" = false;
            };
          };
        }
      );
    in
    {
      config = lib.mkIf (servers != { }) {
        assertions = [
          {
            assertion = pkgs.stdenv.hostPlatform.isx86_64;
            message = "The pinned tModLoader image/runtime adapter supports x86_64 hosts.";
          }
          {
            assertion = runtime == "podman";
            message = "The game container adapter expects the existing Podman runtime.";
          }
        ];
        infra.games.artifacts.games-tmodloader-runtime = portableDotnet;
        infra.games.runtime = lib.mapAttrs (id: s: {
          inherit (s)
            game
            displayName
            memoryMax
            backup
            ;
          inherit id;
          owner = "root";
          unit = "${runtime}-games-${id}.service";
          container = "games-${id}";
          dataDir = dir id;
          worldPaths = [ "${dir id}/tModLoader/Worlds" ];
          worldFiles = map (extension: "${dir id}/tModLoader/Worlds/${s.terraria.worldName}.${extension}") [
            "wld"
            "twld"
          ];
          logDir = "${dir id}/logs";
          public = map (hostname: {
            inherit hostname;
            port = s.terraria.port;
            protocol = "tcp";
            edition = null;
          }) s.hostnames;
          publicTCPPorts = [ s.terraria.port ];
          publicUDPPorts = [ ];
          internalPorts = [ ];
          wakeOnJoin = false;
          serverPort = s.terraria.port;
          secretNames = [ (secretName id) ];
          available =
            builtins.hasAttr (secretName id) cfg.secretFiles
            && builtins.pathExists cfg.secretFiles.${secretName id};
          console = {
            method = "container-inject";
            command = [
              "games-console"
              id
            ];
          };
          fingerprint = builtins.hashString "sha256" (
            builtins.toJSON {
              inherit (s.terraria) image mods modConfigs;
              dotnet = toString portableDotnet;
              runtimeConfig = toString runtimeConfig;
              icu = toString pkgs.icu;
            }
          );
          configTemplates.${configPath id} = {
            source = toString (
              pkgs.writeText "${id}-serverconfig.txt" ''
                world=${"/data/tModLoader/Worlds/${s.terraria.worldName}.wld"}
                worldpath=/data/tModLoader/Worlds
                worldname=${s.terraria.worldName}
                autocreate=${toString s.terraria.worldSize}
                difficulty=${toString s.terraria.difficulty}
                maxplayers=${toString s.terraria.maxPlayers}
                port=${toString s.terraria.port}
                password=@PASSWORD@
                upnp=0
                language=en-US
              ''
            );
            replacements."@PASSWORD@" = secretPath id;
          };
          mods = lib.mapAttrs (_: path: toString path) s.terraria.mods;
          modConfigs = s.terraria.modConfigs;
        }) servers;
        virtualisation.oci-containers.containers = lib.mapAttrs' (
          id: s:
          lib.nameValuePair "games-${id}" {
            autoStart = true;
            image = s.terraria.image;
            log-driver = "journald";
            environment = {
              TMOD_USECONFIGFILE = "Yes";
              TMOD_AUTODOWNLOAD = "";
              TMOD_ENABLEDMODS = "";
              TMOD_AUTOSAVE_INTERVAL = "10";
              CLR_ICU_VERSION_OVERRIDE = icuMajor;
            };
            volumes = [
              "${dir id}:/data"
              "${dir id}/logs:/terraria-server/tModLoader-Logs"
              # The image's bundled installer fails; provide a pinned portable
              # runtime and its exact-version config without runtime downloads.
              "${portableDotnet}:/terraria-server/dotnet:ro"
              "${runtimeConfig}:/terraria-server/tModLoader.runtimeconfig.json:ro"
              # The image checks customconfig.txt but launches serverconfig.txt.
              "${configPath id}:/terraria-server/customconfig.txt:ro"
              "${configPath id}:/terraria-server/serverconfig.txt:ro"
            ]
            ++
              map
                (
                  library:
                  "${pkgs.icu}/lib/libicu${library}.so.${icuMajor}:/usr/lib/x86_64-linux-gnu/libicu${library}.so.${icuMajor}:ro"
                )
                [
                  "uc"
                  "i18n"
                  "data"
                ];
            extraOptions = [
              "--network=host"
              "--cgroup-parent=games.slice"
              "--memory=${lib.toLower s.memoryMax}"
              "--memory-swap=${lib.toLower s.memoryMax}"
              "--stop-timeout=150"
            ];
          }
        ) servers;
        systemd.services = lib.mapAttrs' (
          id: s:
          lib.nameValuePair "${runtime}-games-${id}" {
            enable = cfg.runtime.${id}.available;
            serviceConfig = {
              Slice = "games.slice";
              MemoryMax = s.memoryMax;
              TimeoutStartSec = lib.mkForce "40min";
              TimeoutStopSec = lib.mkForce 180;
              ExecStartPre = lib.mkBefore [
                "${lib.getExe cfg.packages.prechange} ${id}"
                "${lib.getExe cfg.packages.prepare} ${id}"
              ];
              ExecStop = lib.mkBefore [ "${lib.getExe cfg.packages.container-stop} ${id}" ];
              # Keep the exit status before oci-containers removes the container.
              ExecStopPost = lib.mkBefore [ "${lib.getExe cfg.packages.container-result} ${id}" ];
            };
          }
        ) servers;
        systemd.tmpfiles.rules = lib.concatLists (
          lib.mapAttrsToList (id: _: [
            "d ${dir id} 0700 root root -"
            "d ${dir id}/tModLoader 0700 root root -"
            "d ${dir id}/tModLoader/Worlds 0700 root root -"
            "d ${dir id}/logs 0700 root root -"
            "d /run/games/${id} 0700 root root -"
          ]) servers
        );
      };
    };
}
