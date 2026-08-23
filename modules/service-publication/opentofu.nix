{
  config,
  inputs,
  lib,
  rootPath,
  ...
}:
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
      colmenaPackage = inputs.colmena.packages.${pkgs.stdenv.hostPlatform.system}.colmena;
      choreopsTodoistSyncTool = pkgs.callPackage "${rootPath}/pkgs/choreops-todoist-sync" { };
      servicePublicationTofuTool = pkgs.callPackage "${rootPath}/pkgs/service-publication-tofu" { };
      servicePublicationSmokeTool = pkgs.callPackage "${rootPath}/pkgs/service-publication-smoke" { };
      servicePublicationDeployTool = pkgs.callPackage "${rootPath}/pkgs/service-publication-deploy" {
        colmena = colmenaPackage;
        servicePublicationSmoke = servicePublicationSmokeTool;
        servicePublicationTofu = servicePublicationTofuTool;
      };
    in
    {
      make-shells.default.packages = [ pkgs.opentofu ];

      packages = {
        service-publication-tofu = servicePublicationTofuTool;
        service-publication-smoke = servicePublicationSmokeTool;
        service-publication-deploy = servicePublicationDeployTool;
      };

      apps = {
        service-publication-tofu = {
          program = servicePublicationTofuTool;
          meta.description = "Run OpenTofu operations for service publication";
        };
        service-publication-smoke = {
          program = servicePublicationSmokeTool;
          meta.description = "Run service publication smoke probes";
        };
        service-publication-deploy = {
          program = servicePublicationDeployTool;
          meta.description = "Run the full service publication deploy flow";
        };
      };

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

      # Building writeShellApplication runs its generated-script shellcheck.
      checks.shell-applications = pkgs.linkFarm "shell-applications-check" [
        {
          name = "choreops-todoist-sync";
          path = choreopsTodoistSyncTool;
        }
        {
          name = "service-publication-deploy";
          path = servicePublicationDeployTool;
        }
        {
          name = "service-publication-smoke";
          path = servicePublicationSmokeTool;
        }
        {
          name = "service-publication-tofu";
          path = servicePublicationTofuTool;
        }
      ];

      checks.service-publication-tofu-credentials =
        pkgs.runCommand "service-publication-tofu-credentials"
          {
            src = ../..;
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
            ];
            tofu = lib.getExe servicePublicationTofuTool;
          }
          ''
            set -euo pipefail
            cp -r "$src" source
            cd source

            tmpdir="$(mktemp -d)"
            trap 'rm -rf "$tmpdir"' EXIT

            printf '%s\n' "use_lockfile = true" > "$tmpdir/backend.hcl"
            printf '%s\n' "CLOUDFLARE_API_TOKEN=example-token" > "$tmpdir/cloudflare-api.env"
            printf '%s\n' \
              "TF_VAR_bootstrap_complete=true" \
              "TF_VAR_cloudflare_account_id=example-account-id" \
              "TF_VAR_cloudflare_zone_id=example-zone-id" \
              "TF_VAR_tunnel_name=example-tunnel" > "$tmpdir/bootstrap.env"
            printf '%s\n' "tunnel-secret" > "$tmpdir/tunnel.secret"
            printf '%s\n' "AWS_SECRET_ACCESS_KEY=secret" > "$tmpdir/aws-missing.env"
            printf '%s\n' "AWS_ACCESS_KEY_ID=" > "$tmpdir/aws-empty.env"
            printf '%s\n' "AWS_SECRET_ACCESS_KEY=" >> "$tmpdir/aws-empty.env"
            printf '%s\n' \
              "AWS_ACCESS_KEY_ID=trace-access-key" \
              "AWS_SECRET_ACCESS_KEY=trace-secret-key" > "$tmpdir/aws-complete.env"

            run_case() {
              label=$1
              aws_file=$2
              capture_file="$tmpdir/credential-$label.out"

              set +e
              SERVICE_PUBLICATION_BACKEND_FILE="$tmpdir/backend.hcl" \
                SERVICE_PUBLICATION_REPO_ROOT="$PWD" \
                SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/$aws_file" \
                SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare-api.env" \
                SERVICE_PUBLICATION_BOOTSTRAP_ENV="$tmpdir/bootstrap.env" \
                SERVICE_PUBLICATION_TUNNEL_SECRET_FILE="$tmpdir/tunnel.secret" \
                "$tofu" plan >"$capture_file" 2>&1
              status=$?
              set -e

              if [ "$status" -eq 0 ]; then
                echo "$label unexpectedly succeeded" >&2
                cat "$capture_file" >&2
                exit 1
              fi

              if ! grep -q " is unset" "$capture_file"; then
                echo "$label did not fail on a missing/empty credential variable" >&2
                cat "$capture_file" >&2
                exit 1
              fi
            }

            run_case missing "aws-missing.env"
            run_case empty "aws-empty.env"

            # Even an explicitly traced invocation must stop tracing before it
            # sources any runtime file. Keep bootstrap false so this proof also
            # stops before tofu initialization or network access.
            sed -i 's/TF_VAR_bootstrap_complete=true/TF_VAR_bootstrap_complete=false/' "$tmpdir/bootstrap.env"
            trace_capture="$tmpdir/credential-trace.out"
            set +e
            SERVICE_PUBLICATION_BACKEND_FILE="$tmpdir/backend.hcl" \
              SERVICE_PUBLICATION_REPO_ROOT="$PWD" \
              SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/aws-complete.env" \
              SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare-api.env" \
              SERVICE_PUBLICATION_BOOTSTRAP_ENV="$tmpdir/bootstrap.env" \
              SERVICE_PUBLICATION_TUNNEL_SECRET_FILE="$tmpdir/tunnel.secret" \
              bash -x "$tofu" plan >"$trace_capture" 2>&1
            trace_status=$?
            set -e

            if [ "$trace_status" -eq 0 ] || ! grep -q "adoption gate is not complete" "$trace_capture"; then
              echo "traced credential test did not fail at the pre-init adoption gate" >&2
              exit 1
            fi
            for secret_value in trace-access-key trace-secret-key example-token tunnel-secret; do
              if grep -Fq "$secret_value" "$trace_capture"; then
                echo "traced credential test exposed a runtime secret" >&2
                exit 1
              fi
            done

            touch "$out"
          '';

      checks.no-raw-shell-scripts =
        pkgs.runCommand "no-raw-shell-scripts"
          {
            # A path literal inside the Git flake is VCS-filtered, so this source
            # contains tracked repository files and excludes untracked files.
            src = ../..;
            nativeBuildInputs = [ pkgs.findutils ];
          }
          ''
            set -euo pipefail
            raw_scripts=$(find "$src" -type f -name '*.sh' -print)
            if [ -n "$raw_scripts" ]; then
              echo "tracked raw shell scripts are forbidden:" >&2
              echo "$raw_scripts" >&2
              exit 1
            fi
            touch "$out"
          '';
    };

  # A public resource can never be emitted without the same artifact carrying
  # its stable Access dependency. The pure resolver also asserts this before
  # this OpenTofu tree is generated.
  flake.servicePublicationTofuSchema =
    config.flake.servicePublicationInventory.metadata.schemaVersion;
}
