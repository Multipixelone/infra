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
      servicePublicationBackendConfig = pkgs.writeText "service-publication-backend.hcl" ''
        bucket       = "finntf-557459769096-us-east-1-an"
        key          = "service-publication/cloudflare.tfstate"
        region       = "us-east-1"
        encrypt      = true
        use_lockfile = true
      '';
      valueOrEmpty = value: if value == null then "" else value;
      mkServicePublicationVariables =
        name: cloudflare:
        assert lib.assertMsg (
          !cloudflare.adoptionComplete
          || (cloudflare.accountId != null && cloudflare.zoneId != null && cloudflare.tunnelName != null)
        ) "service publication: the adoption gate requires all declarative Cloudflare identifiers";
        pkgs.writeText name ''
          TF_VAR_cloudflare_account_id=${lib.escapeShellArg (valueOrEmpty cloudflare.accountId)}
          TF_VAR_cloudflare_zone_id=${lib.escapeShellArg (valueOrEmpty cloudflare.zoneId)}
          TF_VAR_tunnel_name=${lib.escapeShellArg (valueOrEmpty cloudflare.tunnelName)}
          TF_VAR_bootstrap_complete=${lib.boolToString cloudflare.adoptionComplete}
        '';
      mkServicePublicationTofuTool =
        {
          cloudflare,
          opentofu ? pkgs.opentofu,
        }:
        pkgs.callPackage "${rootPath}/pkgs/service-publication-tofu" {
          inherit opentofu;
          backendConfig = servicePublicationBackendConfig;
          variablesConfig = mkServicePublicationVariables "service-publication-variables.env" cloudflare;
        };
      servicePublicationTofuTool = mkServicePublicationTofuTool {
        cloudflare = config.servicePublication.cloudflare;
      };
      servicePublicationTestCloudflare = {
        accountId = "example-account-id";
        zoneId = "example-zone-id";
        tunnelName = "example-tunnel";
        adoptionComplete = false;
      };
      servicePublicationTofuTestTool = mkServicePublicationTofuTool {
        cloudflare = servicePublicationTestCloudflare;
      };
      servicePublicationFakeTofu = pkgs.writeShellApplication {
        name = "tofu";
        text = ''
          : "''${SERVICE_PUBLICATION_TEST_TOFU_LOG:?test log is required}"
          printf '%s\n' "$*" >> "$SERVICE_PUBLICATION_TEST_TOFU_LOG"
          if [[ $* == *" show -json "* ]]; then
            printf '{"resource_changes":%s}\n' "''${SERVICE_PUBLICATION_TEST_RESOURCE_CHANGES:-[]}"
          fi
        '';
      };
      servicePublicationTofuGateTestTool = mkServicePublicationTofuTool {
        cloudflare = servicePublicationTestCloudflare;
        opentofu = servicePublicationFakeTofu;
      };
      servicePublicationTofuMissingConfigTestTool = mkServicePublicationTofuTool {
        cloudflare = servicePublicationTestCloudflare // {
          accountId = null;
        };
        opentofu = servicePublicationFakeTofu;
      };
      servicePublicationTofuAdoptedTestTool = mkServicePublicationTofuTool {
        cloudflare = servicePublicationTestCloudflare // {
          adoptionComplete = true;
        };
        opentofu = servicePublicationFakeTofu;
      };
      missingAdoptedConfigEvaluation = builtins.tryEval (
        mkServicePublicationVariables "invalid-service-publication-variables.env" (
          servicePublicationTestCloudflare
          // {
            accountId = null;
            adoptionComplete = true;
          }
        )
      );
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
            tofu = lib.getExe servicePublicationTofuTestTool;
          }
          ''
            set -euo pipefail
            cp -r "$src" source
            cd source

            tmpdir="$(mktemp -d)"
            trap 'rm -rf "$tmpdir"' EXIT

            printf '%s\n' "CLOUDFLARE_API_TOKEN=example-token" > "$tmpdir/cloudflare-api.env"
            printf '%s\n' "IGNORED=value" > "$tmpdir/cloudflare-api-missing.env"
            printf '%s\n' "CLOUDFLARE_API_TOKEN=" > "$tmpdir/cloudflare-api-empty.env"
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
              SERVICE_PUBLICATION_REPO_ROOT="$PWD" \
                SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/$aws_file" \
                SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare-api.env" \
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

              if [ -e infra/service-publication/.terraform ]; then
                echo "$label reached tofu init before credential validation" >&2
                exit 1
              fi
            }

            absent_capture="$tmpdir/credential-absent.out"
            set +e
            SERVICE_PUBLICATION_REPO_ROOT="$PWD" \
              SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/aws-absent.env" \
              SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare-api.env" \
              "$tofu" plan >"$absent_capture" 2>&1
            absent_status=$?
            set -e
            if [ "$absent_status" -eq 0 ] || ! grep -Fq "unreadable runtime file $tmpdir/aws-absent.env" "$absent_capture"; then
              echo "absent AWS credential file did not fail at the readability gate" >&2
              cat "$absent_capture" >&2
              exit 1
            fi
            if [ -e infra/service-publication/.terraform ]; then
              echo "absent AWS credential file reached tofu init" >&2
              exit 1
            fi

            run_case missing "aws-missing.env"
            run_case empty "aws-empty.env"

            run_cloudflare_case() {
              label=$1
              cloudflare_file=$2
              capture_file="$tmpdir/cloudflare-$label.out"

              set +e
              CLOUDFLARE_API_TOKEN=ambient-token \
                SERVICE_PUBLICATION_REPO_ROOT="$PWD" \
                SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/aws-complete.env" \
                SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/$cloudflare_file" \
                "$tofu" plan >"$capture_file" 2>&1
              status=$?
              set -e

              if [ "$status" -eq 0 ] || ! grep -Fq "CLOUDFLARE_API_TOKEN is unset" "$capture_file"; then
                echo "$label Cloudflare credential unexpectedly passed validation" >&2
                cat "$capture_file" >&2
                exit 1
              fi
              if [ -e infra/service-publication/.terraform ]; then
                echo "$label Cloudflare credential reached tofu init" >&2
                exit 1
              fi
            }

            run_cloudflare_case missing "cloudflare-api-missing.env"
            run_cloudflare_case empty "cloudflare-api-empty.env"

            # Even an explicitly traced invocation must stop tracing before it
            # sources any runtime secret. The declarative adoption gate remains
            # false, so this proof also stops before initialization or network access.
            trace_capture="$tmpdir/credential-trace.out"
            set +e
            SERVICE_PUBLICATION_REPO_ROOT="$PWD" \
              SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/aws-complete.env" \
              SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare-api.env" \
              bash -x "$tofu" plan >"$trace_capture" 2>&1
            trace_status=$?
            set -e

            if [ "$trace_status" -eq 0 ] || ! grep -q "adoption gate is not complete" "$trace_capture"; then
              echo "traced credential test did not fail at the pre-init adoption gate" >&2
              exit 1
            fi
            if [ -e infra/service-publication/.terraform ]; then
              echo "traced credential test reached tofu init" >&2
              exit 1
            fi
            for secret_value in trace-access-key trace-secret-key example-token; do
              if grep -Fq "$secret_value" "$trace_capture"; then
                echo "traced credential test exposed a runtime secret" >&2
                exit 1
              fi
            done

            if grep -Eq 'SERVICE_PUBLICATION_TUNNEL_SECRET_FILE|TF_VAR_tunnel_secret|service-publication-tunnel-secret' "$tofu"; then
              echo "service-publication-tofu still depends on an unnecessary Tunnel secret" >&2
              exit 1
            fi

            touch "$out"
          '';

      checks.service-publication-tofu-declarative-config =
        assert !missingAdoptedConfigEvaluation.success;
        pkgs.runCommand "service-publication-tofu-declarative-config"
          {
            gateTofu = lib.getExe servicePublicationTofuGateTestTool;
            adoptedTofu = lib.getExe servicePublicationTofuAdoptedTestTool;
            missingConfigTofu = lib.getExe servicePublicationTofuMissingConfigTestTool;
            tofu = lib.getExe servicePublicationTofuTool;
          }
          ''
            set -euo pipefail

            tmpdir="$(mktemp -d)"
            trap 'rm -rf "$tmpdir"' EXIT
            printf '%s\n' \
              "AWS_ACCESS_KEY_ID=example-access-key" \
              "AWS_SECRET_ACCESS_KEY=example-secret-key" > "$tmpdir/aws.env"
            printf '%s\n' "CLOUDFLARE_API_TOKEN=example-token" > "$tmpdir/cloudflare.env"

            run_wrapper() {
              wrapper=$1
              shift
              SERVICE_PUBLICATION_REPO_ROOT="$tmpdir" \
                SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/aws.env" \
                SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare.env" \
                SERVICE_PUBLICATION_TEST_TOFU_LOG="$tmpdir/tofu.log" \
                "$wrapper" "$@"
            }

            for action in plan apply output; do
              rm -f "$tmpdir/tofu.log"
              set +e
              run_wrapper "$gateTofu" "$action" > "$tmpdir/$action.out" 2>&1
              status=$?
              set -e
              if [ "$status" -eq 0 ] || ! grep -Fq "adoption gate is not complete" "$tmpdir/$action.out"; then
                echo "$action did not fail at the declarative adoption gate" >&2
                cat "$tmpdir/$action.out" >&2
                exit 1
              fi
              if [ -e "$tmpdir/tofu.log" ]; then
                echo "$action reached tofu init before the adoption gate" >&2
                exit 1
              fi
            done

            rm -f "$tmpdir/tofu.log"
            run_wrapper "$gateTofu" adoption-plan
            grep -Fq 'init -reconfigure -backend-config=' "$tmpdir/tofu.log"
            grep -Eq 'plan -lock=true -var=bootstrap_complete=true -out=' "$tmpdir/tofu.log"
            grep -Fq 'show -json ' "$tmpdir/tofu.log"
            if grep -Fq ' apply ' "$tmpdir/tofu.log"; then
              echo "adoption-plan reached apply" >&2
              exit 1
            fi

            rm -f "$tmpdir/tofu.log"
            set +e
            SERVICE_PUBLICATION_TEST_RESOURCE_CHANGES='[{"change":{"actions":["delete","create"]}}]' \
              run_wrapper "$gateTofu" adoption-plan > "$tmpdir/adoption-replacement.out" 2>&1
            adoption_replacement_status=$?
            set -e
            if [ "$adoption_replacement_status" -eq 0 ] \
              || ! grep -Fq 'refusing 1 resource replacement' "$tmpdir/adoption-replacement.out"; then
              echo "adoption-plan did not reject a replacement" >&2
              cat "$tmpdir/adoption-replacement.out" >&2
              exit 1
            fi
            if grep -Fq ' apply ' "$tmpdir/tofu.log"; then
              echo "replacement-bearing adoption-plan reached apply" >&2
              exit 1
            fi

            rm -f "$tmpdir/tofu.log"
            set +e
            run_wrapper "$missingConfigTofu" import 'cloudflare_zero_trust_tunnel_cloudflared.managed' \
              > "$tmpdir/missing.out" 2>&1
            missing_status=$?
            set -e
            if [ "$missing_status" -eq 0 ] \
              || ! grep -Fq "declarative Nix option servicePublication.cloudflare.accountId is unset" "$tmpdir/missing.out"; then
              echo "missing declarative account ID did not fail closed" >&2
              cat "$tmpdir/missing.out" >&2
              exit 1
            fi
            if [ -e "$tmpdir/tofu.log" ]; then
              echo "missing declarative configuration reached tofu init" >&2
              exit 1
            fi

            for resource in \
              cloudflare_zero_trust_tunnel_cloudflared.managed \
              cloudflare_zero_trust_tunnel_cloudflared_config.managed; do
              set +e
              SERVICE_PUBLICATION_IMPORT_ID=wrong-account/example-tunnel-id \
                run_wrapper "$gateTofu" import "$resource" \
                > "$tmpdir/tunnel-import-shape.out" 2>&1
              tunnel_import_shape_status=$?
              set -e
              if [ "$tunnel_import_shape_status" -eq 0 ] \
                || ! grep -Fq "must be <account_id>/<tunnel_id>" "$tmpdir/tunnel-import-shape.out"; then
                echo "$resource accepted an import ID outside <account_id>/<tunnel_id>" >&2
                cat "$tmpdir/tunnel-import-shape.out" >&2
                exit 1
              fi

              SERVICE_PUBLICATION_IMPORT_ID=example-account-id/example-tunnel-id \
                run_wrapper "$gateTofu" import "$resource"
              grep -Fq 'init -reconfigure -backend-config=' "$tmpdir/tofu.log"
              grep -Fq "import -lock=true -var=bootstrap_complete=true $resource example-account-id/example-tunnel-id" "$tmpdir/tofu.log"
            done

            rm -f "$tmpdir/tofu.log"
            run_wrapper "$adoptedTofu" plan
            grep -Eq 'plan -lock=true -out=' "$tmpdir/tofu.log"
            run_wrapper "$adoptedTofu" output
            grep -Eq -- '-chdir=.*/infra/service-publication output$' "$tmpdir/tofu.log"
            SERVICE_PUBLICATION_APPROVE=APPLY run_wrapper "$adoptedTofu" apply
            grep -Eq 'apply -lock=true .+\.tfplan$' "$tmpdir/tofu.log"

            rm -f "$tmpdir/tofu.log"
            set +e
            run_wrapper "$adoptedTofu" adoption-plan > "$tmpdir/adopted-adoption-plan.out" 2>&1
            adopted_adoption_plan_status=$?
            set -e
            if [ "$adopted_adoption_plan_status" -eq 0 ] \
              || ! grep -Fq 'adoption is complete; use the normal plan command' "$tmpdir/adopted-adoption-plan.out"; then
              echo "adoption-plan remained available after adoption" >&2
              cat "$tmpdir/adopted-adoption-plan.out" >&2
              exit 1
            fi
            if [ -e "$tmpdir/tofu.log" ]; then
              echo "post-adoption adoption-plan reached tofu init" >&2
              exit 1
            fi

            if grep -Fq '/run/agenix/service-publication-bootstrap' "$tofu"; then
              echo "service-publication-tofu still depends on the obsolete agenix bootstrap file" >&2
              exit 1
            fi
            if grep -Fq 'SERVICE_PUBLICATION_BOOTSTRAP_ENV' "$tofu"; then
              echo "service-publication-tofu still accepts an out-of-band bootstrap override" >&2
              exit 1
            fi

            touch "$out"
          '';

      checks.service-publication-tunnel-adoption =
        pkgs.runCommand "service-publication-tunnel-adoption"
          {
            src = ../..;
            nativeBuildInputs = [ pkgs.ripgrep ];
          }
          ''
            set -euo pipefail
            cp -r "$src" source

            main=source/infra/service-publication/main.tf
            wrapper=source/pkgs/service-publication-tofu/default.nix

            rg -F 'resource "cloudflare_zero_trust_tunnel_cloudflared" "managed"' "$main"
            rg -F 'config_src = "cloudflare"' "$main"
            rg -F 'prevent_destroy = true' "$main"
            rg -F 'replacement_count' "$wrapper"
            rg -F 'Tunnel and Tunnel configuration import IDs must be <account_id>/<tunnel_id>' "$wrapper"
            rg -F '`<account_id>/<tunnel_id>` pair' source/docs/service-publication-runbook.md
            rg -F 'there is no separate configuration import ID.' source/docs/service-publication-runbook.md

            if rg -n 'tunnel_secret|service-publication-tunnel-secret|SERVICE_PUBLICATION_TUNNEL_SECRET_FILE' \
              source/infra/service-publication \
              source/modules/service-publication/runtime.nix \
              source/pkgs/service-publication-tofu; then
              echo "remotely managed Tunnel adoption still requires a locally managed Tunnel secret" >&2
              exit 1
            fi

            touch "$out"
          '';

      checks.service-publication-tofu-backend =
        pkgs.runCommand "service-publication-tofu-backend"
          {
            backendConfig = servicePublicationBackendConfig;
            tofu = lib.getExe servicePublicationTofuTool;
          }
          ''
            set -euo pipefail

            grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true([[:space:]]|$)' "$backendConfig"
            if ! grep -Fq "backend_file=$backendConfig" "$tofu"; then
              echo "service-publication-tofu does not use the packaged backend config" >&2
              exit 1
            fi
            if ! grep -Fq 'init -reconfigure -backend-config="$backend_file"' "$tofu"; then
              echo "service-publication-tofu does not pass the packaged config to tofu init" >&2
              exit 1
            fi
            if grep -Fq '/run/agenix/service-publication-backend' "$tofu"; then
              echo "service-publication-tofu still requires the obsolete agenix backend file" >&2
              exit 1
            fi
            if grep -Fq 'SERVICE_PUBLICATION_BACKEND_FILE' "$tofu"; then
              echo "service-publication-tofu still accepts an out-of-band backend source" >&2
              exit 1
            fi

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
