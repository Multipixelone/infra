args@{
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
    {
      config,
      pkgs,
      self',
      ...
    }:
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
        cloudflare = args.config.servicePublication.cloudflare;
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
          if [[ -n ''${SERVICE_PUBLICATION_TEST_TOFU_ENV_LOG:-} ]]; then
            env | grep -E '^CLOUDFLARE_' >> "$SERVICE_PUBLICATION_TEST_TOFU_ENV_LOG" || true
          fi
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
      servicePublicationValidateTool =
        pkgs.callPackage "${rootPath}/pkgs/service-publication-validate"
          { };
      servicePublicationDeployTool = pkgs.callPackage "${rootPath}/pkgs/service-publication-deploy" {
        colmena = colmenaPackage;
        privilegeCommand = "/run/wrappers/bin/sudo";
        servicePublicationSmoke = servicePublicationSmokeTool;
        servicePublicationTofu = servicePublicationTofuTool;
        servicePublicationValidate = servicePublicationValidateTool;
        stateDir = "/var/lib/service-publication";
      };
      servicePublicationDeployTestPrivilege = pkgs.writeShellApplication {
        name = "service-publication-test-privilege";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          : "''${SERVICE_PUBLICATION_TEST_PRIVILEGE_LOG:?test privilege log is required}"
          printf '%s\n' "$*" >> "$SERVICE_PUBLICATION_TEST_PRIVILEGE_LOG"
          if [[ ''${1:-} == cat && ''${SERVICE_PUBLICATION_TEST_DENY_REVISION_READ:-} == 1 ]]; then
            exit 1
          fi
          exec "$@"
        '';
      };
      servicePublicationDeployTestSsh = pkgs.writeShellApplication {
        name = "service-publication-test-ssh";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          : "''${SERVICE_PUBLICATION_TEST_SSH_LOG:?test ssh log is required}"
          printf '%s\n' "$*" >> "$SERVICE_PUBLICATION_TEST_SSH_LOG"
          if [[ ''${SERVICE_PUBLICATION_TEST_SSH_FAIL:-} == 1 ]]; then
            exit 255
          fi
          printf '%s\n' "''${SERVICE_PUBLICATION_TEST_SSH_REVISION-}"
        '';
      };
      servicePublicationDeployTestCommand =
        name:
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            : "''${SERVICE_PUBLICATION_TEST_COMMAND_LOG:?test command log is required}"
            printf '%s %s\n' ${lib.escapeShellArg name} "$*" >> "$SERVICE_PUBLICATION_TEST_COMMAND_LOG"
            ${lib.optionalString (name == "service-publication-smoke") ''
              : "''${SERVICE_PUBLICATION_TEST_SMOKE_COUNT:?test smoke count is required}"
              count=0
              if [[ -e $SERVICE_PUBLICATION_TEST_SMOKE_COUNT ]]; then
                count=$(<"$SERVICE_PUBLICATION_TEST_SMOKE_COUNT")
              fi
              count=$((count + 1))
              printf '%s\n' "$count" > "$SERVICE_PUBLICATION_TEST_SMOKE_COUNT"
              if [[ ''${SERVICE_PUBLICATION_TEST_FAIL_FINAL_SMOKE:-} == 1 && $count -ge 2 ]]; then
                exit 1
              fi
            ''}
          '';
        };
      servicePublicationDeployTestTool = pkgs.callPackage "${rootPath}/pkgs/service-publication-deploy" {
        colmena = servicePublicationDeployTestCommand "colmena";
        privilegeCommand = lib.getExe servicePublicationDeployTestPrivilege;
        servicePublicationSmoke = servicePublicationDeployTestCommand "service-publication-smoke";
        servicePublicationTofu = servicePublicationDeployTestCommand "service-publication-tofu";
        servicePublicationValidate = servicePublicationDeployTestCommand "service-publication-validate";
        sshCommand = lib.getExe servicePublicationDeployTestSsh;
        stateDir = ".service-publication-test-state";
      };
      servicePublicationPlanOnlyTestTool =
        pkgs.callPackage "${rootPath}/pkgs/service-publication-deploy"
          {
            colmena = colmenaPackage;
            privilegeCommand = lib.getExe servicePublicationDeployTestPrivilege;
            servicePublicationSmoke = pkgs.writeShellApplication {
              name = "service-publication-smoke";
              text = ''
                echo "plan-only invoked smoke probes" >&2
                exit 1
              '';
            };
            servicePublicationTofu = pkgs.writeShellApplication {
              name = "service-publication-tofu";
              text = "exit 0";
            };
            servicePublicationValidate = pkgs.writeShellApplication {
              name = "service-publication-validate";
              text = "exit 0";
            };
            stateDir = ".service-publication-plan-only-state";
          };
    in
    {
      make-shells.default.packages = [ pkgs.opentofu ];

      packages = {
        service-publication-tofu = servicePublicationTofuTool;
        service-publication-smoke = servicePublicationSmokeTool;
        service-publication-validate = servicePublicationValidateTool;
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
        service-publication-validate = {
          program = servicePublicationValidateTool;
          meta.description = "Run focused, provider-safe service publication validation";
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

      checks.service-publication-workflow-generated =
        pkgs.runCommand "service-publication-workflow-generated-check"
          {
            src = ../..;
            workflow = config.files.file.${workflowPath}.source;
          }
          ''
            set -euo pipefail
            cmp "$workflow" "$src/${workflowPath}"
            touch "$out"
          '';

      checks.service-publication-formatting =
        pkgs.runCommand "service-publication-formatting-check"
          {
            src = ../..;
            nativeBuildInputs = [ self'.formatter ];
          }
          ''
            set -euo pipefail
            cp -r "$src" source
            chmod -R u+w source
            cd source
            treefmt --ci \
              docs/service-publication-runbook.md \
              docs/split-dns-service-publication.md \
              infra/service-publication \
              lib/service-publication.nix \
              modules/service-publication \
              pkgs/service-publication-deploy \
              pkgs/service-publication-smoke \
              pkgs/service-publication-tofu \
              pkgs/service-publication-validate
            touch "$out"
          '';

      checks.service-publication-shell-applications =
        pkgs.linkFarm "service-publication-shell-applications-check"
          [
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
            {
              name = "service-publication-validate";
              path = servicePublicationValidateTool;
            }
          ];

      checks.service-publication-plan-only =
        pkgs.runCommand "service-publication-plan-only-check"
          {
            deploy = servicePublicationPlanOnlyTestTool;
            nativeBuildInputs = [ pkgs.gitMinimal ];
          }
          ''
            set -euo pipefail
            mkdir source
            cd source
            git init --quiet
            privilege_log="$PWD/privilege.log"
            SERVICE_PUBLICATION_TEST_PRIVILEGE_LOG="$privilege_log" \
              env -u SERVICE_PUBLICATION_BLOCKY_ADDRESS "$deploy/bin/service-publication-deploy" plan-only
            if [[ -s $privilege_log || -e .service-publication-plan-only-state ]]; then
              echo "plan-only read or mutated revision state" >&2
              exit 1
            fi
            touch "$out"
          '';

      checks.service-publication-applied-revision =
        pkgs.runCommand "service-publication-applied-revision-check"
          {
            deploy = servicePublicationDeployTestTool;
            nativeBuildInputs = [ pkgs.gitMinimal ];
          }
          ''
            set -euo pipefail
            mkdir -p source/infra/service-publication
            cd source
            git init --quiet
            git config user.email test@example.invalid
            git config user.name "Service Publication Test"
            printf '%s\n' ${
              lib.escapeShellArg (
                builtins.toJSON {
                  applications = { };
                  routes = { };
                  internalProbes = [ ];
                  cloudflare.tunnel.ingressHost = { };
                  hosts = {
                    link = {
                      managedByNixOS = true;
                      capabilities = {
                        reverseProxy = true;
                        internalDns = true;
                        publicConnector = true;
                      };
                    };
                    iot = {
                      managedByNixOS = true;
                      capabilities = {
                        reverseProxy = false;
                        internalDns = false;
                        publicConnector = false;
                      };
                    };
                  };
                }
              )
            } > infra/service-publication/registry.json
            git add infra/service-publication/registry.json
            git commit --quiet -m fixture

            # What the generated /etc/service-publication/revision holds: the
            # registry bytes without the trailing newline the file adds.
            applied=$(head -c -1 infra/service-publication/registry.json | sha256sum | cut -d' ' -f1)
            command_log="$PWD/commands.log"
            privilege_log="$PWD/privilege.log"
            smoke_count="$PWD/smoke-count"
            ssh_log="$PWD/ssh.log"
            export SERVICE_PUBLICATION_TEST_COMMAND_LOG="$command_log"
            export SERVICE_PUBLICATION_TEST_PRIVILEGE_LOG="$privilege_log"
            export SERVICE_PUBLICATION_TEST_SMOKE_COUNT="$smoke_count"
            export SERVICE_PUBLICATION_TEST_SSH_LOG="$ssh_log"

            reset_logs() {
              rm -f "$command_log" "$privilege_log" "$smoke_count" "$ssh_log"
            }

            run_deploy() { "$deploy/bin/service-publication-deploy" "$@"; }

            export SERVICE_PUBLICATION_BOOTSTRAP=1
            run_deploy apply
            unset SERVICE_PUBLICATION_BOOTSTRAP
            if [[ $(grep -n -e 'colmena build' -e 'service-publication-tofu apply' "$command_log" |
              head -n1) != *'colmena build'* ]]; then
              echo "external state was touched before every host had been built" >&2
              exit 1
            fi

            reset_logs
            export SERVICE_PUBLICATION_TEST_SSH_REVISION="$applied"
            run_deploy apply
            grep -Fq colmena.link "$ssh_log"
            if grep -Fq colmena.iot "$ssh_log"; then
              echo "queried a host outside the service-publication deploy set" >&2
              exit 1
            fi

            reset_logs
            SERVICE_PUBLICATION_TEST_SSH_REVISION=0000
            if run_deploy apply 2> drift.log; then
              echo "apply classified additions and removals against a stale ledger" >&2
              exit 1
            fi
            grep -Fq "link runs 0000" drift.log
            if grep -Fq colmena "$command_log" || grep -Fq service-publication-tofu "$command_log"; then
              echo "a drifting host built or deployed something" >&2
              exit 1
            fi

            reset_logs
            export SERVICE_PUBLICATION_IGNORE_HOST_REVISION=1
            run_deploy apply
            unset SERVICE_PUBLICATION_IGNORE_HOST_REVISION
            grep -Fq 'colmena apply' "$command_log"

            reset_logs
            unset SERVICE_PUBLICATION_TEST_SSH_REVISION
            run_deploy apply

            reset_logs
            export SERVICE_PUBLICATION_TEST_SSH_FAIL=1
            if run_deploy apply; then
              echo "apply proceeded without reading an applied revision" >&2
              exit 1
            fi

            touch "$out"
          '';

      checks.service-publication-deploy-revision-state =
        pkgs.runCommand "service-publication-deploy-revision-state-check"
          {
            deploy = servicePublicationDeployTestTool;
            nativeBuildInputs = [
              pkgs.gitMinimal
              pkgs.jq
            ];
          }
          ''
            set -euo pipefail
            mkdir -p source/infra/service-publication
            cd source
            git init --quiet
            git config user.email test@example.invalid
            git config user.name "Service Publication Test"
            printf '%s\n' \
              '{"applications":{},"routes":{},"internalProbes":[],"cloudflare":{"tunnel":{"ingressHost":{}}}}' \
              > infra/service-publication/registry.json
            git add infra/service-publication/registry.json
            git commit --quiet -m fixture

            state_arg=.service-publication-test-state
            state_dir="$PWD/$state_arg"
            revision_file="$state_dir/last-successful-revision"
            command_log="$PWD/commands.log"
            privilege_log="$PWD/privilege.log"
            smoke_count="$PWD/smoke-count"
            expected_revision=$(git rev-parse HEAD)

            run_deploy() {
              SERVICE_PUBLICATION_TEST_COMMAND_LOG="$command_log" \
              SERVICE_PUBLICATION_TEST_PRIVILEGE_LOG="$privilege_log" \
              SERVICE_PUBLICATION_TEST_SMOKE_COUNT="$smoke_count" \
                "$deploy/bin/service-publication-deploy" "$@"
            }

            if run_deploy apply; then
              echo "first apply succeeded without bootstrap authorization" >&2
              exit 1
            fi
            [[ ! -e $revision_file ]]

            rm -f "$command_log" "$privilege_log" "$smoke_count"
            SERVICE_PUBLICATION_BOOTSTRAP=1 run_deploy apply
            [[ $(<"$revision_file") == "$expected_revision" ]]
            grep -Fq "install -d -m 0750 $state_arg" "$privilege_log"
            grep -Fq "tee $state_arg/last-successful-revision" "$privilege_log"

            rm -f "$command_log" "$privilege_log" "$smoke_count"
            run_deploy apply
            grep -Fqx "cat $state_arg/last-successful-revision" "$privilege_log"
            [[ $(<"$revision_file") == "$expected_revision" ]]

            rm -f "$command_log" "$privilege_log" "$smoke_count"
            if SERVICE_PUBLICATION_TEST_FAIL_FINAL_SMOKE=1 run_deploy apply; then
              echo "apply succeeded despite a failed final smoke probe" >&2
              exit 1
            fi
            [[ $(<"$revision_file") == "$expected_revision" ]]
            if grep -Fq "tee $state_arg/last-successful-revision" "$privilege_log"; then
              echo "failed apply rewrote revision state" >&2
              exit 1
            fi

            rm -f "$command_log" "$privilege_log" "$smoke_count"
            if SERVICE_PUBLICATION_TEST_DENY_REVISION_READ=1 run_deploy apply; then
              echo "apply succeeded with unreadable revision state and no bootstrap authorization" >&2
              exit 1
            fi
            [[ $(<"$revision_file") == "$expected_revision" ]]

            printf ' \n' >> infra/service-publication/registry.json
            rm -f "$command_log" "$privilege_log" "$smoke_count"
            SERVICE_PUBLICATION_ALLOW_DIRTY=1 run_deploy apply
            [[ $(<"$revision_file") == "$expected_revision" ]]
            if grep -Fq "tee $state_arg/last-successful-revision" "$privilege_log"; then
              echo "dirty emergency apply rewrote revision state" >&2
              exit 1
            fi

            rm -rf "$state_dir"
            rm -f "$command_log" "$privilege_log" "$smoke_count"
            run_deploy plan-only
            if [[ -s $privilege_log || -e $state_dir ]]; then
              echo "plan-only read or mutated revision state" >&2
              exit 1
            fi

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
            adoptedTofu = lib.getExe servicePublicationTofuAdoptedTestTool;
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

            # The provider reads a whole family of Cloudflare variables, so none of
            # them may survive from the operator's ambient environment.
            ambient_env_log="$tmpdir/cloudflare-ambient-env.log"
            CLOUDFLARE_ACCOUNT_ID=ambient-account \
              CLOUDFLARE_API_KEY=ambient-global-key \
              CLOUDFLARE_API_TOKEN=ambient-token \
              CLOUDFLARE_API_USER_SERVICE_KEY=ambient-service-key \
              CLOUDFLARE_BASE_URL=https://ambient.example.net \
              CLOUDFLARE_EMAIL=ambient@example.net \
              CLOUDFLARE_USER_AGENT_OPERATOR_SUFFIX=ambient-suffix \
              SERVICE_PUBLICATION_REPO_ROOT="$PWD" \
              SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/aws-complete.env" \
              SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare-api.env" \
              SERVICE_PUBLICATION_TEST_TOFU_LOG="$tmpdir/ambient-tofu.log" \
              SERVICE_PUBLICATION_TEST_TOFU_ENV_LOG="$ambient_env_log" \
              "$adoptedTofu" plan > "$tmpdir/cloudflare-ambient.out" 2>&1
            if grep -Eq '^CLOUDFLARE_(ACCOUNT_ID|API_KEY|API_USER_SERVICE_KEY|BASE_URL|EMAIL|USER_AGENT_OPERATOR_SUFFIX)=' \
              "$ambient_env_log"; then
              echo "ambient Cloudflare provider variables survived into the OpenTofu environment" >&2
              cat "$ambient_env_log" >&2
              exit 1
            fi
            if ! grep -Fxq 'CLOUDFLARE_API_TOKEN=example-token' "$ambient_env_log"; then
              echo "the reviewed Cloudflare token did not reach the OpenTofu environment" >&2
              cat "$ambient_env_log" >&2
              exit 1
            fi

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

      checks.service-publication-tunnel-ingress-guard =
        pkgs.runCommand "service-publication-tunnel-ingress-guard"
          {
            adoptedTofu = lib.getExe servicePublicationTofuAdoptedTestTool;
          }
          ''
            set -euo pipefail

            tmpdir="$(mktemp -d)"
            trap 'rm -rf "$tmpdir"' EXIT
            printf '%s\n' \
              "AWS_ACCESS_KEY_ID=example-access-key" \
              "AWS_SECRET_ACCESS_KEY=example-secret-key" > "$tmpdir/aws.env"
            printf '%s\n' "CLOUDFLARE_API_TOKEN=example-token" > "$tmpdir/cloudflare.env"

            # One adopted hostname disappears from the Tunnel ingress while another survives.
            dropping_plan='[{"type":"cloudflare_zero_trust_tunnel_cloudflared_config","change":{"actions":["update"],"before":{"config":{"ingress":[{"hostname":"adopted.example.net","service":"http://localhost:5030"},{"hostname":"kept.example.net","service":"http://localhost:5800"},{"service":"http_status:404"}]}},"after":{"config":{"ingress":[{"hostname":"kept.example.net","service":"http://localhost:5800"},{"service":"http_status:404"}]}}}}]'

            run_wrapper() {
              SERVICE_PUBLICATION_REPO_ROOT="$tmpdir" \
                SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV="$tmpdir/aws.env" \
                SERVICE_PUBLICATION_CLOUDFLARE_API_ENV="$tmpdir/cloudflare.env" \
                SERVICE_PUBLICATION_TEST_TOFU_LOG="$tmpdir/tofu.log" \
                SERVICE_PUBLICATION_TEST_RESOURCE_CHANGES="$dropping_plan" \
                "$adoptedTofu" "$@"
            }

            rm -f "$tmpdir/tofu.log"
            set +e
            SERVICE_PUBLICATION_APPROVE=APPLY \
              run_wrapper apply > "$tmpdir/unreviewed-apply.out" 2>&1
            unreviewed_apply_status=$?
            set -e
            if [ "$unreviewed_apply_status" -eq 0 ] \
              || ! grep -Fq 'adopted.example.net' "$tmpdir/unreviewed-apply.out" \
              || ! grep -Fq 'refusing to silently unpublish those hostnames' "$tmpdir/unreviewed-apply.out"; then
              echo "apply did not refuse an unreviewed Tunnel ingress removal" >&2
              cat "$tmpdir/unreviewed-apply.out" >&2
              exit 1
            fi
            if grep -Fq 'kept.example.net' "$tmpdir/unreviewed-apply.out"; then
              echo "the ingress guard reported a hostname the plan keeps" >&2
              cat "$tmpdir/unreviewed-apply.out" >&2
              exit 1
            fi
            if grep -Fq ' apply ' "$tmpdir/tofu.log"; then
              echo "an unreviewed Tunnel ingress removal reached apply" >&2
              exit 1
            fi

            rm -f "$tmpdir/tofu.log"
            run_wrapper plan > "$tmpdir/plan.out" 2>&1
            if ! grep -Fq 'WARNING: applying this plan would unpublish those hostnames' "$tmpdir/plan.out" \
              || ! grep -Fq 'adopted.example.net' "$tmpdir/plan.out"; then
              echo "plan did not warn about the Tunnel ingress removal" >&2
              cat "$tmpdir/plan.out" >&2
              exit 1
            fi

            rm -f "$tmpdir/tofu.log"
            SERVICE_PUBLICATION_APPROVE=APPLY \
              SERVICE_PUBLICATION_EXPECTED_INGRESS_REMOVALS='adopted.example.net,other.example.net' \
              run_wrapper apply > "$tmpdir/reviewed-apply.out" 2>&1
            grep -Eq 'apply -lock=true .+\.tfplan$' "$tmpdir/tofu.log"

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

      checks.service-publication-validation = pkgs.linkFarm "service-publication-validation-check" (
        map
          (name: {
            inherit name;
            path = self'.checks.${name};
          })
          [
            "service-publication-registry"
            "service-publication-registry-generated"
            "service-publication-workflow-generated"
            "service-publication-formatting"
            "service-publication-tofu"
            "service-publication-shell-applications"
            "service-publication-plan-only"
            "service-publication-applied-revision"
            "service-publication-deploy-revision-state"
            "service-publication-tofu-credentials"
            "service-publication-tofu-declarative-config"
            "service-publication-tunnel-ingress-guard"
            "service-publication-tunnel-adoption"
            "service-publication-tofu-backend"
          ]
      );

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
