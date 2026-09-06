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
