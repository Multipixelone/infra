{ config, lib, ... }:
{
  gitignore = [
    "**/.terraform/*"
    "**/.tofu/*"
    "*.tfstate"
    "*.tfstate.*"
    "crash.log"
    "crash.*.log"
    "*.tfplan"
    "*.plan"
    "*.auto.tfvars"
    "*.auto.tfvars.json"
    "override.tf"
    "override.tf.json"
    "*_override.tf"
    "*_override.tf.json"
    ".terraformrc"
    "terraform.rc"
    "backend.hcl"
  ];

  perSystem =
    { pkgs, ... }:
    let
      tofuRoot = "infra/service-publication";
      tofu = lib.getExe pkgs.opentofu;
      workflowPath = ".github/workflows/service-publication.yaml";
    in
    {
      make-shells.default.packages = [ pkgs.opentofu ];

      treefmt.settings.formatter.opentofu = {
        command = tofu;
        options = [ "fmt" ];
        includes = [ "${tofuRoot}/*.tf" ];
      };
      treefmt.settings.global.excludes = [
        workflowPath
        "${tofuRoot}/.terraform.lock.hcl"
        "${tofuRoot}/backend.hcl.example"
        "${tofuRoot}/registry.json"
      ];

      files.file.${workflowPath}.source = pkgs.writers.writeJSON "service-publication-workflow.yaml" {
        name = "Service publication";
        on = {
          pull_request.paths = [
            "infra/service-publication/**"
            "lib/service-publication.nix"
            "modules/service-publication/**"
          ];
          push.paths = [
            "infra/service-publication/**"
            "lib/service-publication.nix"
            "modules/service-publication/**"
          ];
        };
        jobs.validate = {
          runs-on = "ubuntu-latest";
          permissions.contents = "read";
          steps = [
            { uses = "actions/checkout@v4"; }
            {
              uses = "opentofu/setup-opentofu@v1";
              "with".tofu_version = "1.12.5";
            }
            {
              name = "Format and validate without a backend";
              run = ''
                tofu -chdir=infra/service-publication fmt -check -diff
                tofu -chdir=infra/service-publication init -backend=false
                tofu -chdir=infra/service-publication validate
              '';
            }
          ];
        };
      };

      checks.service-publication-tofu =
        pkgs.runCommand "service-publication-tofu-check"
          {
            nativeBuildInputs = [ pkgs.opentofu ];
            src = ../../infra/service-publication;
          }
          ''
            cp -r "$src" source
            chmod -R u+w source
            cd source
            ${tofu} fmt -check -diff
            # Provider-backed `tofu validate` runs in the generated CI workflow
            # and deployment wrapper; Nix builds are deliberately networkless.
            touch "$out"
          '';
    };

  # A public resource can never be emitted without the same artifact carrying
  # its stable Access dependency. The pure resolver also asserts this before
  # this OpenTofu tree is generated.
  flake.servicePublicationTofuSchema =
    config.flake.servicePublicationInventory.metadata.schemaVersion;
}
