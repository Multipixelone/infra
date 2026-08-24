{
  backendConfig,
  coreutils,
  gitMinimal,
  gnugrep,
  jq,
  opentofu,
  writeShellApplication,
}:
writeShellApplication {
  name = "service-publication-tofu";
  runtimeInputs = [
    coreutils
    gitMinimal
    gnugrep
    jq
    opentofu
  ];
  text = ''
    repo_root=''${SERVICE_PUBLICATION_REPO_ROOT:-$(git rev-parse --show-toplevel)}
    tofu_root="$repo_root/infra/service-publication"
    backend_file=${backendConfig}
    aws_credentials_env=''${SERVICE_PUBLICATION_AWS_CREDENTIALS_ENV:-/run/agenix/service-publication-state-credentials}
    cloudflare_api_env=''${SERVICE_PUBLICATION_CLOUDFLARE_API_ENV:-/run/agenix/service-publication-cloudflare-api}
    bootstrap_env=''${SERVICE_PUBLICATION_BOOTSTRAP_ENV:-/run/agenix/service-publication-bootstrap}
    tunnel_secret_file=''${SERVICE_PUBLICATION_TUNNEL_SECRET_FILE:-/run/agenix/service-publication-tunnel-secret}
    action=''${1:-plan}

    case "$action" in
    plan | apply | output | import) ;;
    *)
      echo "usage: $0 {plan|apply|output|import} [import arguments...]" >&2
      exit 2
      ;;
    esac

    for runtime_file in "$aws_credentials_env" "$cloudflare_api_env" "$bootstrap_env" "$tunnel_secret_file"; do
      if [[ ! -r $runtime_file ]]; then
        echo "service publication bootstrap blocker: unreadable runtime file $runtime_file" >&2
        exit 1
      fi
    done

    if ! grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true([[:space:]]|$)' "$backend_file"; then
      echo "service publication refuses a backend without use_lockfile = true" >&2
      exit 1
    fi

    unset \
      AWS_ACCESS_KEY_ID \
      AWS_CONFIG_FILE \
      AWS_CONTAINER_CREDENTIALS_FULL_URI \
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
      AWS_DEFAULT_PROFILE \
      AWS_PROFILE \
      AWS_ROLE_ARN \
      AWS_SECRET_ACCESS_KEY \
      AWS_SESSION_TOKEN \
      AWS_SHARED_CREDENTIALS_FILE \
      AWS_WEB_IDENTITY_TOKEN_FILE \
      CLOUDFLARE_API_TOKEN
    # Never trace assignments loaded from runtime credential files.
    set +x
    set -a
    # shellcheck disable=SC1090
    source "$aws_credentials_env"
    # shellcheck disable=SC1090
    source "$cloudflare_api_env"
    # shellcheck disable=SC1090
    source "$bootstrap_env"
    set +a
    export TF_VAR_tunnel_secret
    TF_VAR_tunnel_secret=$(<"$tunnel_secret_file")

    required_vars=(
      AWS_ACCESS_KEY_ID
      AWS_SECRET_ACCESS_KEY
      CLOUDFLARE_API_TOKEN
      TF_VAR_bootstrap_complete
      TF_VAR_cloudflare_account_id
      TF_VAR_cloudflare_zone_id
      TF_VAR_tunnel_name
      TF_VAR_tunnel_secret
    )
    for variable in "''${required_vars[@]}"; do
      if [[ -z ''${!variable:-} ]]; then
        echo "service publication bootstrap blocker: $variable is unset" >&2
        exit 1
      fi
    done
    if [[ $action != import && ''${TF_VAR_bootstrap_complete:-} != true ]]; then
      echo "service publication adoption gate is not complete" >&2
      exit 1
    fi

    tofu -chdir="$tofu_root" init -reconfigure -backend-config="$backend_file"

    case "$action" in
    plan | apply)
      plan_file=$(mktemp --tmpdir service-publication.XXXXXX.tfplan)
      plan_json=$(mktemp --tmpdir service-publication.XXXXXX.json)
      trap 'rm -f "$plan_file" "$plan_json"' EXIT

      tofu -chdir="$tofu_root" plan -lock=true -out="$plan_file"
      tofu -chdir="$tofu_root" show -json "$plan_file" >"$plan_json"
      tofu -chdir="$tofu_root" show -no-color "$plan_file"

      replacement_count=$(jq '[.resource_changes[]? | select(.change.actions == ["delete", "create"] or .change.actions == ["create", "delete"])] | length' "$plan_json")
      if ((replacement_count > 0)); then
        echo "refusing $replacement_count resource replacement(s); reconcile imports or use an explicit reviewed migration" >&2
        exit 1
      fi
      if [[ $action == apply ]]; then
        if [[ ''${SERVICE_PUBLICATION_APPROVE:-} != APPLY ]]; then
          read -r -p "Type APPLY to apply this exact locked plan: " approval
          [[ $approval == APPLY ]] || {
            echo "apply cancelled" >&2
            exit 1
          }
        fi
        tofu -chdir="$tofu_root" apply -lock=true "$plan_file"
      fi
      ;;
    output)
      tofu -chdir="$tofu_root" output
      ;;
    import)
      shift
      if (($# != 1)); then
        echo "usage: $0 import RESOURCE_ADDRESS" >&2
        exit 2
      fi
      if [[ -z ''${SERVICE_PUBLICATION_IMPORT_ID:-} ]]; then
        read -r -s -p "Import ID (will not be echoed): " SERVICE_PUBLICATION_IMPORT_ID
        printf '\n' >&2
      fi
      [[ -n $SERVICE_PUBLICATION_IMPORT_ID ]] || {
        echo "import ID is empty" >&2
        exit 1
      }
      tofu -chdir="$tofu_root" import -lock=true -var=bootstrap_complete=true "$1" "$SERVICE_PUBLICATION_IMPORT_ID"
      unset SERVICE_PUBLICATION_IMPORT_ID
      ;;
    esac
  '';
  meta.description = "Run OpenTofu operations for service publication";
}
