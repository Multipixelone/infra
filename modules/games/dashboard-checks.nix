{ config, lib, ... }:
let
  infra = config;
  host = infra.flake.nixosConfigurations.link;
  canonical = "games.nyc.finnrut.is";
  vhost = host.config.services.nginx.virtualHosts.${canonical};
  root = vhost.locations."/";
  inventory = infra.flake.servicePublicationInventory;
  missing =
    (host.extendModules {
      modules = [ { infra.games.secretFiles = lib.mkForce { }; } ];
    }).config;
in
{
  perSystem =
    {
      pkgs,
      self',
      system,
      ...
    }:
    let
      fixture = pkgs.writeText "games-dashboard-mock-manifest.json" (
        builtins.toJSON infra.flake.checks.x86_64-linux.games-contract.fixtureData.enabled.manifest
      );
      proxyConfig = pkgs.writeText "games-dashboard-nginx-fixture.conf" ''
        pid @ROOT@/nginx.pid;
        error_log stderr;
        events {}
        http {
          access_log off;
          client_body_temp_path @ROOT@/body;
          proxy_temp_path @ROOT@/proxy;
          # Test-only source simulation, never installed in production nginx.
          set_real_ip_from 127.0.0.1;
          real_ip_header X-Test-Client-IP;
          server {
            listen 127.0.0.1:@PROXY_PORT@;
            ${vhost.extraConfig}
            location / {
              proxy_pass ${lib.replaceStrings [ ":8780" ] [ ":@BACKEND_PORT@" ] root.proxyPass};
              proxy_http_version 1.1;
              ${root.extraConfig}
            }
          }
        }
      '';
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.games-dashboard-publication =
        assert lib.assertMsg (
          inventory.applications.games.canonical == canonical
          && !inventory.applications.games.public
          && inventory.routes."games/root".backendAddress == "127.0.0.1"
          && inventory.routes."games/root".backend.port == 8780
          && inventory.routes."games/root".proxy.host == "link"
          && inventory.routes."games/root".health.path == "/healthz"
          && inventory.blockyRecords.${canonical} == "192.168.6.6"
          && lib.elem canonical inventory.nginxByHost.link.certificateNames
          && !(inventory.cloudflare.dnsRecords ? games)
          && !(inventory.cloudflare.accessApplications ? games)
          && lib.all (application: application.key != "games") inventory.cloudflare.tunnel.applications
        ) "games dashboard must remain private with link loopback backend, DNS and TLS";
        assert lib.assertMsg
          (
            host.config.systemd.services.games-dashboard.enable
            && missing.systemd.services.games-dashboard.enable
            && lib.all (name: !(lib.hasPrefix "games/dashboard-" name)) (lib.attrNames missing.age.secrets)
            && !(missing.systemd.services.games-dashboard.unitConfig ? ConditionPathExists)
            &&
              root.extraConfig
              == infra.flake.nixosConfigurations.impa.config.services.nginx.virtualHosts."snapweb.nyc.finnrut.is".locations."/".extraConfig
            && vhost.basicAuth == { }
            && vhost.basicAuthFile == null
            && lib.all (text: !(lib.hasInfix "auth_basic" text)) (
              [ vhost.extraConfig ] ++ map (location: location.extraConfig) (lib.attrValues vhost.locations)
            )
          )
          "games dashboard must be enabled without secrets and use the standard private ACL without basic auth";
        pkgs.runCommand "games-dashboard-publication-check"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            GAMES_DASHBOARD_MOCK_MANIFEST = fixture;
          }
          ''
            python3 ${../../pkgs/games-dashboard/backend/tests/packaged_smoke.py} \
              --executable ${lib.getExe self'.packages.games-dashboard} \
              --nginx ${lib.getExe pkgs.nginx} --proxy-config ${proxyConfig}
            touch "$out"
          '';
    };
}
