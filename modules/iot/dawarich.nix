{
  lib,
  withSystem,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.dawarich-home-assistant = pkgs.stdenv.mkDerivation {
        pname = "home-assistant-custom-component-dawarich";
        version = "1.0.0-beta6";

        src = pkgs.fetchFromGitHub {
          owner = "AlbinLind";
          repo = "dawarich-home-assistant";
          rev = "eb7e052b05afb15ecd0661fc2374c88d8660f04e";
          hash = "sha256-2sDv53slyhS/z3ZZgz1MXva+yKAdjEHXfrDJfKsGtG0=";
        };

        installPhase = ''
          mkdir -p "$out/custom_components"
          cp -r custom_components/dawarich "$out/custom_components/"
        '';

        passthru = {
          isHomeAssistantComponent = true;
          domain = "dawarich";
        };

        meta = with lib; {
          homepage = "https://github.com/AlbinLind/dawarich-home-assistant";
          description = "Dawarich integration for Home Assistant";
          license = licenses.mit;
          platforms = platforms.all;
        };
      };
    };

  # Published as map.finnrut.is. Dawarich's nginx vhost
  # listens on port 80 and proxies to the Rails process on its private port.
  servicePublication.applications.map = {
    site = "nyc";
    public = true;
    publicHostname = "map.finnrut.is";
    access = {
      bypassAccess = true;
      bypassJustification = "Dawarich authenticates the UI and mobile ingestion uses API keys; Cloudflare Access would break background location uploads.";
    };
    homepage = {
      name = "Dawarich";
      group = "Services";
      description = "Private location-history dashboard";
      icon = "dawarich";
    };
    routes.root = {
      backend = {
        host = "iot";
        scheme = "http";
        port = 80;
      };
      health = {
        path = "/api/v1/health";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.iot.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      dawarichApi =
        ps:
        ps.buildPythonPackage {
          pname = "dawarich-api";
          version = "0.5.0";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/74/52/552dc2e098731fb13d8319d67152087935d0be8eddf8684837620d2033ae/dawarich_api-0.5.0.tar.gz";
            hash = "sha256-1xN7y4IXIhCmdlIzhxU+7OesdlF4gWlWeo5gpgA7l/0=";
          };

          pyproject = true;
          build-system = [ ps.setuptools ];
          dependencies = [
            ps.pydantic
            ps.aiohttp
          ];

          doCheck = false;
          pythonImportsCheck = [ "dawarich_api" ];
        };

      dawarichBackfill = pkgs.writeShellScriptBin "dawarich-backfill-home-assistant" ''
        unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
        exec ${pkgs.python3}/bin/python3 ${./dawarich-backfill.py} "$@"
      '';

      backfillRunner = pkgs.writeShellApplication {
        name = "dawarich-backfill-home-assistant";
        text = ''
          export HA_URL="http://127.0.0.1:8123"
          export HA_TOKEN_FILE="${config.age.secrets."homeassistant-token".path}"
          export DAWARICH_URL="http://127.0.0.1"
          export DAWARICH_HOST="${config.services.dawarich.localDomain}"
          export DAWARICH_DATABASE_NAME="${config.services.dawarich.database.name}"
          export DAWARICH_DATABASE_USER="${config.services.dawarich.database.user}"
          export DAWARICH_PSQL="${lib.getExe' config.services.postgresql.package "psql"}"
          export DAWARICH_RUNUSER="${lib.getExe' pkgs.util-linux "runuser"}"
          exec ${lib.getExe dawarichBackfill} "$@"
        '';
      };

      backfillMarker = "/var/lib/dawarich/.home-assistant-backfill-device-tracker-nougat-v1";
      primaryUserPromotionMarker = "/var/lib/dawarich/.primary-user-promoted-v1";

    in
    {
      # Port 80 is only the internal publication backend; Dawarich itself is
      # bound behind this module-managed nginx vhost on port 3000.
      networking.firewall.allowedTCPPorts = [ 80 ];

      services.dawarich = {
        enable = true;
        package = pkgs.dawarich;
        configureNginx = true;
        localDomain = "map.finnrut.is";
        webPort = 3000;
        automaticMigrations = true;
        database.createLocally = true;
        redis.createLocally = true;
        environment = {
          APPLICATION_PROTOCOL = "https";
        };
        extraEnvFiles = [ "/var/lib/dawarich/secrets/jwt.env" ];
      };

      # Preserve the HTTPS scheme from the Impa TLS terminator through this
      # second proxy hop instead of replacing it with iot's HTTP scheme.
      services.nginx.virtualHosts."map.finnrut.is".locations."@proxy" = {
        recommendedProxySettings = lib.mkForce false;
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };

      services.home-assistant = {
        extraPackages = ps: [ (dawarichApi ps) ];
        customComponents = [
          (withSystem pkgs.stdenv.hostPlatform.system (
            psArgs: psArgs.config.packages.dawarich-home-assistant
          ))
        ];
      };

      # The HA recorder keeps 21 days. Replay Finn's GPS tracker once when
      # this lands, before those pre-Dawarich points age out. The batch API is
      # an upsert, so a failed/retried run cannot duplicate identical points.
      systemd.services.dawarich-home-assistant-backfill = {
        description = "Backfill Dawarich from Home Assistant location history";
        wantedBy = [ "multi-user.target" ];
        after = [
          "home-assistant.service"
          "dawarich-web.service"
          "nginx.service"
        ];
        requires = [
          "home-assistant.service"
          "dawarich-web.service"
          "nginx.service"
        ];
        unitConfig.ConditionPathExists = "!${backfillMarker}";
        serviceConfig.Type = "oneshot";
        script = ''
          ${lib.getExe backfillRunner} \
            --entity-id device_tracker.nougat \
            --days 21 \
            --apply
          ${lib.getExe' pkgs.coreutils "touch"} ${backfillMarker}
        '';
      };

      # Dawarich seeds demo@dawarich.app as the initial administrator. Promote
      # the sole real account once so the admin-only user-management page is
      # available without signing in through the public default account.
      systemd.services.dawarich-promote-primary-user = {
        description = "Promote the primary Dawarich account to administrator";
        wantedBy = [ "multi-user.target" ];
        before = [ "dawarich-home-assistant-backfill.service" ];
        after = [ "dawarich-init-db.service" ];
        requires = [ "dawarich-init-db.service" ];
        unitConfig.ConditionPathExists = "!${primaryUserPromotionMarker}";
        serviceConfig.Type = "oneshot";
        script = ''
          ${lib.getExe' pkgs.util-linux "runuser"} \
            -u ${lib.escapeShellArg config.services.dawarich.database.user} -- \
            ${lib.getExe' config.services.postgresql.package "psql"} \
            -X \
            -d ${lib.escapeShellArg config.services.dawarich.database.name} \
            -v ON_ERROR_STOP=1 <<'SQL'
          DO $$
          DECLARE
            candidate_count integer;
          BEGIN
            SELECT count(*)
              INTO candidate_count
              FROM users
             WHERE deleted_at IS NULL
               AND status IN (1, 2)
               AND email <> 'demo@dawarich.app';

            IF candidate_count <> 1 THEN
              RAISE EXCEPTION
                'expected exactly one active non-demo Dawarich account, found %',
                candidate_count;
            END IF;

            UPDATE users
               SET admin = TRUE,
                   updated_at = NOW()
             WHERE deleted_at IS NULL
               AND status IN (1, 2)
               AND email <> 'demo@dawarich.app';
          END;
          $$;
          SQL
          ${lib.getExe' pkgs.coreutils "touch"} ${primaryUserPromotionMarker}
        '';
      };

      environment.systemPackages = [ backfillRunner ];

      # The upstream Dawarich module creates this unit when secretKeyBaseFile
      # remains null (the default). Its web, migration, and Sidekiq units all
      # require it, so appending here makes the generated environment file
      # available before any Dawarich process reads extraEnvFiles.
      systemd.services.dawarich-init-credentials.script = lib.mkAfter ''
        umask 077
        secretsDir=/var/lib/dawarich/secrets
        envFile="$secretsDir/jwt.env"
        mkdir -p "$secretsDir"

        for name in JWT_SECRET_KEY AUTH_JWT_SECRET_KEY; do
          secretFile="$secretsDir/$name"
          if ! test -s "$secretFile"; then
            tmp="$secretFile.tmp"
            rm -f "$tmp"
            ${lib.getExe pkgs.openssl} rand -hex 64 > "$tmp"
            chmod 0600 "$tmp"
            mv "$tmp" "$secretFile"
          fi
        done

        tmp="$envFile.tmp"
        {
          printf 'JWT_SECRET_KEY='
          tr -d '\n' < "$secretsDir/JWT_SECRET_KEY"
          printf '\nAUTH_JWT_SECRET_KEY='
          tr -d '\n' < "$secretsDir/AUTH_JWT_SECRET_KEY"
          printf '\n'
        } > "$tmp"
        chmod 0600 "$tmp"
        mv "$tmp" "$envFile"
      '';

    };
}
