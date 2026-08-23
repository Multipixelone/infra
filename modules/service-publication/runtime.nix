{
  config,
  inputs,
  lib,
  ...
}:
let
  secrets = {
    service-publication-backend = "${inputs.secrets}/cloudflare/service-publication-backend.age";
    service-publication-bootstrap = "${inputs.secrets}/cloudflare/service-publication-bootstrap.age";
    service-publication-cloudflare-api = "${inputs.secrets}/cloudflare/service-publication-api.age";
    service-publication-tunnel-secret = "${inputs.secrets}/cloudflare/service-publication-tunnel-secret.age";
  };
  availableSecrets = lib.filterAttrs (_: file: builtins.pathExists file) secrets;
in
{
  configurations.nixos.${config.servicePublication.sites.nyc.publicIngressHost}.module =
    { pkgs, ... }:
    {
      age.secrets = lib.mapAttrs (_: file: {
        inherit file;
        owner = config.flake.meta.owner.username;
        group = "users";
        mode = "0400";
      }) availableSecrets;

      environment.systemPackages = [
        pkgs.bind
        pkgs.curl
        pkgs.gitleaks
        pkgs.jq
        pkgs.opentofu
      ];
    };
}
