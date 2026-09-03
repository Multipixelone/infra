{
  config,
  inputs,
  lib,
  ...
}:
let
  secrets = {
    service-publication-cloudflare-api = "${inputs.secrets}/cloudflare/service-publication-api.age";
    service-publication-state-credentials = "${inputs.secrets}/aws/service-publication-state-credentials.age";
  };
  operatorSecretNames = builtins.attrNames secrets;
  availableSecrets = lib.filterAttrs (_: file: builtins.pathExists file) secrets;
in
{
  configurations.nixos.link.module =
    { pkgs, ... }:
    {
      age.secrets = lib.mapAttrs (_: file: {
        inherit file;
        owner = "tunnel";
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

  perSystem =
    { pkgs, ... }:
    let
      linkSecrets = config.flake.nixosConfigurations.link.config.age.secrets;
      impaSecrets = config.flake.nixosConfigurations.impa.config.age.secrets;
      hasOperatorSecret = secrets: name: builtins.hasAttr name secrets;
      hasOperatorSecretContract =
        name:
        hasOperatorSecret linkSecrets name
        && linkSecrets.${name}.owner == "tunnel"
        && linkSecrets.${name}.group == "users"
        && linkSecrets.${name}.mode == "0400";
    in
    {
      checks.service-publication-operator-credentials =
        assert lib.assertMsg (lib.all hasOperatorSecretContract operatorSecretNames)
          "service publication operator credentials must be declared on Link for tunnel:users with mode 0400";
        assert lib.assertMsg (lib.all (name: !hasOperatorSecret impaSecrets name)
          operatorSecretNames
        ) "service publication operator credentials must not follow public ingress to Impa";
        pkgs.runCommand "service-publication-operator-credentials-check" { } ''
          touch "$out"
        '';
    };
}
