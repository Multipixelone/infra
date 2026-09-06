{ inputs, ... }:
let
  # RomM's own nginx vhost is the origin: the backend only speaks API, while
  # nginx serves the frontend, the X-Accel-Redirect ROM downloads and the
  # cross-origin isolation headers EmulatorJS needs. The publication proxy must
  # therefore point at this vhost, not at the API port.
  originPort = 8081;
  # Loopback-only; nothing but the local vhost talks to it.
  apiPort = 8080;

  # Not /srv: the ROM library, resources and cache belong on the 4 TB NVMe, and
  # `services.romm.dataDir` fixes the library at ${dataDir}/library with no way
  # to relocate just that subtree. A bind mount from /media/Data onto /srv/romm
  # would buy nothing but the convention, at the cost of a mount unit that
  # races systemd-tmpfiles on first boot, so the service simply lives where its
  # data lives and the backup paths below name it explicitly.
  dataDir = "/media/Data/romm";

  # Root-owned, on the root filesystem, outside anything the service user can
  # write. See the pgDump comment below for why this is not under dataDir.
  dumpDir = "/var/backup/romm";

  publicHostname = "rom.finnrut.is";

  backend = {
    host = "link";
    port = originPort;
  };

  # A path Grout reaches without an Access identity. Every one of these was
  # read off Grout's own endpoint table (romm/endpoints.go) and checked against
  # RomM 5.2.0's router mounts, so the set is what the handheld needs and
  # nothing more.
  #
  # `statuses` is what the ORIGIN answers an unauthenticated probe:
  #   200  the route is anonymous upstream (heartbeat, config)
  #   401  scoped route, no credentials -- decorators/auth.py:79 returns 401
  #        for an unauthenticated caller
  #   405  POST-only route; Starlette rejects the probe's GET at the router,
  #        before auth runs
  #   403  nginx refusing to index a static directory
  # Any of them proves the request reached the origin. An Access challenge
  # would instead be a 302 to cloudflareaccess.com, so these double as proof
  # that the bypass is actually in effect.
  bypassRoute =
    {
      prefix,
      health,
      statuses,
      why,
    }:
    {
      match.pathPrefix = prefix;
      inherit backend;
      access = {
        bypassAccess = true;
        bypassJustification = "Grout on the RG35XXSP authenticates with a RomM Client API Token and cannot complete a Cloudflare Access identity challenge; ${why}";
      };
      health = {
        path = health;
        expectedStatuses = statuses;
        timeoutSeconds = 8;
      };
    };
in
{
  # One hostname. The browser surface is gated by finn-only; a fixed list of
  # narrow prefixes is bypassed because Grout -- the muOS client that makes
  # this whole thing work -- authenticates with a RomM Client API Token and has
  # no way to complete an Access identity challenge. Cloudflare resolves the
  # most specific path-scoped application first and inherits nothing from the
  # parent, so each narrow bypass wins without opening the root (the same
  # arrangement copyparty uses for its anonymous share prefixes).
  #
  # Bypassing all of /api/ would be wrong, and not for a subtle reason.
  # RomM's @protected_route builds its guard as _requires_scopes(scopes or []),
  # which defers to starlette's has_required_scope; an EMPTY scope list
  # iterates zero times and returns true, and both Security dependencies use
  # auto_error=False. So @protected_route(m, p, []) is exactly as open as no
  # decorator at all, and grepping for the decorator proves nothing. Fifteen
  # /api/ routes are anonymous that way, four of them guarded only by "no
  # admin user exists yet" -- POST /api/users among them, with the role
  # settable from the request body. On a first deploy the database has no
  # admins while DNS, tunnel and bypass all come up together, so a blanket
  # /api/ bypass would leave a window in which any internet caller could POST
  # itself an administrator. /api/users, /api/setup/*, /api/feeds/*, /api/docs
  # and /api/redoc are therefore all outside the list below.
  #
  # The registry enforces this shape: lib/service-publication.nix rejects a
  # protected route nested inside a bypassed one ("narrow the bypass route
  # pathPrefix"), so re-gating the dangerous paths under a wide bypass is not
  # available -- the allowlist is the mechanism.
  #
  # DISABLE_DOWNLOAD_ENDPOINT_AUTH stays off: turning it on while any of these
  # is edge-bypassed would make the library world-downloadable.
  servicePublication.applications.romm = {
    site = "nyc";
    public = true;
    inherit publicHostname;
    homepage = {
      name = "RomM";
      group = "Media";
      description = "ROM library, in-browser play, and the save hub";
      icon = "romm";
    };
    access.policy = "finn-only";
    routes.root = {
      inherit backend;
      health = {
        # nginx serves the SPA shell unauthenticated; Access challenges happen
        # at the edge, in front of this probe's origin.
        path = "/";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
    # Connectivity and instance config. Both are anonymous upstream by design:
    # the frontend reads them before login to discover which auth modes and
    # metadata providers exist. /api/config redacts its two sensitive fields
    # for unauthenticated callers, and heartbeat returns provider booleans,
    # never key values.
    routes.heartbeat = bypassRoute {
      prefix = "/api/heartbeat";
      health = "/api/heartbeat";
      statuses = [ 200 ];
      why = "it polls the heartbeat to decide whether the server is reachable before every sync";
    };
    routes.config = bypassRoute {
      prefix = "/api/config";
      health = "/api/config";
      statuses = [ 200 ];
      why = "it reads instance config to map platform slugs to on-device directories";
    };

    # Pairing. Both flows are live: a QR/device-auth handshake and manual
    # pair-code entry. These mint the very token everything else presents, so
    # they cannot themselves sit behind a token.
    # Exactly the two legs Grout calls (romm/endpoints.go:40-41), not the whole
    # /api/auth/device/ prefix. The other three routes on that router --
    # /approve (ME_WRITE), /pending/{code} (ME_READ) and /deny (ME_WRITE) --
    # are driven by the browser that scans the pairing QR, and an
    # Access-authenticated browser sends its CF_Authorization cookie with those
    # XHRs, so they resolve through the gated root instead. Keeping them off
    # the public surface costs nothing and removes three endpoints an
    # unauthenticated caller could otherwise reach.
    routes.deviceAuthInit = bypassRoute {
      prefix = "/api/auth/device/init";
      health = "/api/auth/device/init";
      statuses = [ 405 ];
      why = "the handheld opens the QR pairing handshake here, before it holds any token";
    };
    routes.deviceAuthToken = bypassRoute {
      prefix = "/api/auth/device/token";
      health = "/api/auth/device/token";
      statuses = [ 405 ];
      why = "the handheld polls here to collect the token once the pairing is approved";
    };
    routes.tokenExchange = bypassRoute {
      # Deliberately deeper than /api/client-tokens: the bare prefix would also
      # expose token minting and listing. Only the exchange leg is needed.
      prefix = "/api/client-tokens/exchange";
      health = "/api/client-tokens/exchange";
      statuses = [ 405 ];
      why = "manual pair-code entry redeems its short code here";
    };

    # Library metadata.
    routes.platforms = bypassRoute {
      prefix = "/api/platforms";
      health = "/api/platforms";
      statuses = [ 401 ];
      why = "it maps RomM platforms onto muOS directories, and uses this route to validate its token";
    };
    routes.roms = bypassRoute {
      prefix = "/api/roms";
      health = "/api/roms";
      statuses = [ 401 ];
      why = "it browses the library and downloads ROMs from /api/roms/{id}/content";
    };
    routes.collections = bypassRoute {
      prefix = "/api/collections";
      health = "/api/collections";
      statuses = [ 401 ];
      why = "it renders collections, smart collections and virtual collections on the device";
    };
    routes.firmware = bypassRoute {
      prefix = "/api/firmware";
      health = "/api/firmware";
      statuses = [ 401 ];
      why = "it provisions BIOS files to the SD card and verifies their hashes";
    };

    # The save hub itself. Grout models states as saves with slots, so there is
    # no /api/states route to open.
    routes.saves = bypassRoute {
      prefix = "/api/saves";
      health = "/api/saves";
      statuses = [ 401 ];
      why = "this is the save sync itself -- the reason the instance exists";
    };
    routes.devices = bypassRoute {
      prefix = "/api/devices";
      health = "/api/devices";
      statuses = [ 401 ];
      why = "it registers itself as a device so the server can attribute saves to it";
    };
    routes.sync = bypassRoute {
      prefix = "/api/sync";
      health = "/api/sync/negotiate";
      statuses = [ 405 ];
      why = "sync sessions are negotiated and completed here";
    };

    # Deeper than /api/users on purpose. The bare prefix would expose
    # POST /api/users (unauthenticated admin creation before the first admin
    # exists) and /api/users/invite-link. RomM 5.2.0 has no /api/users/me/*
    # subroutes, so this prefix reaches exactly one route.
    routes.usersMe = bypassRoute {
      prefix = "/api/users/me";
      health = "/api/users/me";
      statuses = [ 401 ];
      why = "it shows the signed-in username; every call site tolerates failure, so this is the one entry that could be dropped";
    };

    # Not under /api/ at all. RomM serves cover art, logos, marquees, fanart,
    # screenshots and manuals from this nginx alias, and Grout builds those
    # URLs from the absolute path_cover_* fields the API hands it. Scoping the
    # bypass to /api/ alone would leave every image behind Access and the
    # handheld's library would render blank.
    routes.resources = bypassRoute {
      prefix = "/assets/romm/resources/";
      # nginx has autoindex off and this is a static alias, so the directory
      # itself is refused rather than listed; a 404 says the same thing if the
      # tree is still empty before the first scan.
      health = "/assets/romm/resources/";
      statuses = [
        403
        404
      ];
      why = "all box art and screenshots are served from this static alias, which is outside /api/";
    };
  };

  configurations.nixos.link.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # Postgres holds every save's metadata -- which ROM, which user, which
      # slot, the content hash sync decisions are made from. The bytes under
      # assets/ are meaningless without it, so the dump has to be inside the
      # same snapshot rather than on a timer of its own.
      #
      # Deliberately NOT under dataDir. This runs from restic-backups-srv,
      # which is root and carries no ProtectSystem or ProtectHome, and every
      # directory under dataDir is writable by the romm service user. Having
      # root create or chown a path the service can replace with a symlink
      # hands that service an arbitrary root-owned chown -- which is exactly
      # the escalation the romm units' NoNewPrivileges/ProtectSystem sandbox
      # exists to prevent. dumpDir is root-owned, created declaratively by
      # tmpfiles (which resolves paths symlink-safely), and romm cannot reach
      # it at all: pg_dump writes to a descriptor root already opened, so the
      # unprivileged half never names the path.
      pgDump = pkgs.writeShellApplication {
        name = "romm-pg-dump";
        runtimeInputs = [
          config.services.postgresql.package
          pkgs.util-linux
        ];
        text = ''
          umask 0077
          # Peer authentication over the unix socket, so pg_dump has to run as
          # the owning role. It writes to stdout rather than --file, so the
          # only thing the romm uid touches is the already-open descriptor.
          runuser -u romm -- pg_dump --format=custom romm > ${dumpDir}/romm.dump
        '';
      };
    in
    {
      # Metadata provider credentials plus ROMM_AUTH_SECRET_KEY. Owned by the
      # service user because the units read it as EnvironmentFile.
      #
      #   IGDB_CLIENT_ID=          IGDB_CLIENT_SECRET=      (via Twitch)
      #   MOBYGAMES_API_KEY=
      #   SCREENSCRAPER_USER=      SCREENSCRAPER_PASSWORD=
      #   STEAMGRIDDB_API_KEY=
      #   RETROACHIEVEMENTS_API_KEY=
      #   ROMM_AUTH_SECRET_KEY=    (openssl rand -hex 32)
      age.secrets."romm" = {
        file = "${inputs.secrets}/media/romm.age";
        mode = "400";
        owner = "romm";
        group = "romm";
      };

      # assets/ is the saves and states store -- the only irreplaceable thing
      # here -- and config/ carries the generated auth secret plus the
      # pre-backup database dump. library/ is deliberately absent: it is 2 GB
      # and growing of re-acquirable ROMs, and pushing it to OneDrive nightly
      # would dominate the repository for no recovery value.
      infra.backup.srvPaths = [
        "${dataDir}/assets"
        "${dataDir}/config"
        dumpDir
      ];

      services.romm = {
        enable = true;
        inherit dataDir;
        listenAddress = "127.0.0.1";
        port = apiPort;
        environmentFile = config.age.secrets."romm".path;

        nginx = {
          enable = true;
          # An internal-only server name. Naming the vhost rom.finnrut.is
          # would collide with the vhost service-publication generates for the
          # same name on this host: nginx resolves duplicate server_names by
          # silently keeping the first, which is not a failure mode worth
          # inheriting. Nothing resolves this name -- the vhost is the only
          # one listening on originPort, so it answers every request on that
          # port regardless of Host.
          virtualHost = "romm-origin";
        };

        extraEnvironment = {
          # The module derives both of these from the vhost, which here is an
          # internal plaintext name; the user-facing origin is the published
          # hostname, and these feed invite/reset links and the session cookie
          # flags.
          ROMM_BASE_URL = "https://${publicHostname}";
          ROMM_SESSION_SECURE_COOKIE = "true";
          # Empty would allow every origin. The API is reachable without an
          # Access challenge, so keep browser-originated cross-site calls off
          # it even though bearer auth is what actually guards the endpoints.
          ROMM_CORS_ALLOWED_ORIGINS = "https://${publicHostname}";
          # Keyless providers: no credential, no rate-limited account, just a
          # toggle. The keyed ones (IGDB, MobyGames, ScreenScraper,
          # SteamGridDB, RetroAchievements) come from the environment file.
          PLAYMATCH_API_ENABLED = "true";
          LAUNCHBOX_API_ENABLED = "true";
          HASHEOUS_API_ENABLED = "true";
          FLASHPOINT_API_ENABLED = "true";
          HLTB_API_ENABLED = "true";
          TGDB_API_ENABLED = "true";
        };
      };

      # Impa proxies this over the LAN, so the origin cannot be loopback-only.
      services.nginx.virtualHosts."romm-origin".listen = [
        {
          addr = "0.0.0.0";
          port = originPort;
        }
      ];
      networking.firewall.allowedTCPPorts = [ originPort ];

      # The module's own tmpfiles entry ("10-romm") creates the library at
      # 0750 romm:romm, which lets nobody but the service write it. The import
      # tooling runs as the login user, so widen the two trees it writes and
      # put tunnel in the group; "20-" sorts after "10-", so this is the mode
      # that survives. Everything else under dataDir stays 0750.
      #
      # Setgid, not plain 0770: without it, ROMs promoted by tunnel land owned
      # tunnel:users and the service cannot rename or delete its own library
      # afterwards -- which would quietly undo "RomM owns the ROMs". The bit
      # forces group romm on everything created below, and the import script
      # passes a matching --chmod so the group keeps write.
      # 0700 root:root, and tmpfiles resolves the path symlink-safely. The
      # romm uid has no access here at all, so nothing it controls is ever on
      # the path root walks.
      systemd.tmpfiles.settings."20-romm-dump".${dumpDir}.d = {
        mode = "0700";
        user = "root";
        group = "root";
      };

      systemd.tmpfiles.settings."20-romm-library" =
        lib.genAttrs
          [
            "${dataDir}/library"
            "${dataDir}/library/roms"
            "${dataDir}/library/bios"
          ]
          (_: {
            d = {
              mode = "2770";
              user = "romm";
              group = "romm";
            };
          });
      # Group membership is read at login, so this only takes effect on the
      # next session -- newgrp romm, or log out and back in.
      users.users.tunnel.extraGroups = [ "romm" ];

      # dataDir lives on a separate filesystem. Without this the units would
      # start against an unmounted /media/Data and quietly write a fresh empty
      # library into the mountpoint on the root disk.
      systemd.services = lib.mkMerge [
        (lib.genAttrs
          [
            "romm"
            "romm-worker"
            "romm-scheduler"
            "romm-watcher"
          ]
          (_: {
            unitConfig.RequiresMountsFor = [ dataDir ];
          })
        )
        {
          # One dump immediately before the srv snapshot rather than a timer of
          # its own: it cannot drift from the assets it describes, and it rides
          # the existing 01:00 stagger, so it never races the `home` job for
          # the rotating OneDrive token.
          restic-backups-srv = {
            serviceConfig.ExecStartPre = [ (lib.getExe pgDump) ];
            # Two of this job's three paths are on /media/Data. Without the
            # dependency an unmounted disk backs up an empty assets tree over
            # a good snapshot instead of failing loudly.
            unitConfig.RequiresMountsFor = [ dataDir ];
          };
        }
      ];
    };
}
