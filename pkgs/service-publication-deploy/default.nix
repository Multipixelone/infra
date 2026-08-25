{
  bash,
  colmena,
  coreutils,
  gitMinimal,
  jq,
  servicePublicationSmoke,
  servicePublicationTofu,
  servicePublicationValidate,
  writeShellApplication,
}:
writeShellApplication {
  name = "service-publication-deploy";
  runtimeInputs = [
    bash
    colmena
    coreutils
    gitMinimal
    jq
    servicePublicationSmoke
    servicePublicationTofu
    servicePublicationValidate
  ];
  text = ''
    repo_root=$(git rev-parse --show-toplevel)
    cd "$repo_root"

    mode=''${1:-apply}
    route_filter=''${2:-}
    registry=infra/service-publication/registry.json
    state_dir=/var/lib/service-publication
    revision_file="$state_dir/last-successful-revision"

    case "$mode" in
    apply | plan-only) ;;
    *)
      echo "usage: $0 {apply|plan-only} [application/route]" >&2
      exit 2
      ;;
    esac

    stage() { printf '\n==> %s\n' "$1"; }

    allow_dirty=''${SERVICE_PUBLICATION_ALLOW_DIRTY:-}
    if [[ $mode == apply ]]; then
      if [[ $allow_dirty == 1 ]]; then
        echo "SERVICE_PUBLICATION_ALLOW_DIRTY=1; this run applies an uncommitted tree and will not record a successful revision" >&2
      elif [[ -n $(git status --porcelain --untracked-files=no) ]]; then
        echo "tracked files are modified or staged; the deploy applies the working tree but can only record HEAD, so commit first (or set SERVICE_PUBLICATION_ALLOW_DIRTY=1 to deploy without recording a revision)" >&2
        exit 1
      fi
    fi

    service-publication-validate

    if [[ $mode == plan-only ]]; then
      stage "review Cloudflare plan (no host deployment or apply)"
      service-publication-tofu plan
      exit 0
    fi

    if [[ ! -r $revision_file ]]; then
      if [[ ''${SERVICE_PUBLICATION_BOOTSTRAP:-} != 1 ]]; then
        echo "no last successful revision; complete the adoption runbook and set SERVICE_PUBLICATION_BOOTSTRAP=1 for the reviewed first run" >&2
        exit 1
      fi
      previous_public='[]'
      previous_origins='{}'
      previous_ingress='{}'
    else
      previous_revision=$(<"$revision_file")
      previous_public=$(git show "$previous_revision:$registry" | jq -c '[.routes | to_entries[] | select(.value.public) | .key] | sort')
      previous_origins=$(git show "$previous_revision:$registry" | jq -c '.routes | with_entries(select(.value.public)) | map_values(.proxy)')
      previous_ingress=$(git show "$previous_revision:$registry" | jq -c '.cloudflare.tunnel.ingressHost')
    fi
    current_public=$(jq -c '[.routes | to_entries[] | select(.value.public) | .key] | sort' "$registry")
    current_origins=$(jq -c '.routes | with_entries(select(.value.public)) | map_values(.proxy)' "$registry")
    current_ingress=$(jq -c '.cloudflare.tunnel.ingressHost' "$registry")

    added=$(jq -n --argjson old "$previous_public" --argjson new "$current_public" '$new - $old | length')
    removed=$(jq -n --argjson old "$previous_public" --argjson new "$current_public" '$old - $new | length')
    if ((added > 0 && removed > 0)); then
      echo "mixed publication additions/removals require separate reviewed deployments" >&2
      exit 1
    fi
    origin_moves=$(jq -n --argjson old "$previous_origins" --argjson new "$current_origins" '
      [$old | keys[] as $key | select($new[$key] != null and $new[$key] != $old[$key])] | length
    ')
    if ((origin_moves > 0)) || [[ $previous_ingress != '{}' && $previous_ingress != "$current_ingress" ]]; then
      echo "proxy/connector moves require the runbook's explicit overlap, dual-connector verification, and observation interval" >&2
      exit 1
    fi

    run_internal_smoke() {
      service-publication-smoke lan "$route_filter"
      if [[ -z ''${SERVICE_PUBLICATION_VPN_PROBE_COMMAND:-} ]]; then
        echo "no SERVICE_PUBLICATION_VPN_PROBE_COMMAND set; the VPN view stays unproven for this run" >&2
        return 0
      fi
      SERVICE_PUBLICATION_ROUTE_FILTER="$route_filter" bash -c "$SERVICE_PUBLICATION_VPN_PROBE_COMMAND"
    }

    run_external_smoke() {
      if [[ -z ''${SERVICE_PUBLICATION_EXTERNAL_PROBE_COMMAND:-} ]]; then
        echo "SERVICE_PUBLICATION_EXTERNAL_PROBE_COMMAND is required for public and private DNS verification" >&2
        return 1
      fi
      SERVICE_PUBLICATION_ROUTE_FILTER="$route_filter" bash -c "$SERVICE_PUBLICATION_EXTERNAL_PROBE_COMMAND"
    }

    if ((removed > 0)); then
      stage "withdraw external reachability before local removal"
      service-publication-tofu apply
      stage "deploy generated NixOS service configuration"
      colmena apply --on @service-publication
    else
      stage "deploy generated NixOS service configuration"
      colmena apply --on @service-publication
      stage "prove LAN origin readiness (and the VPN view when a probe is configured) before publication"
      run_internal_smoke
      stage "apply Access-protected Cloudflare publication"
      service-publication-tofu apply
    fi

    stage "run complete internal and external smoke verification"
    run_internal_smoke
    public_count=$(jq -n --argjson routes "$current_public" '$routes | length')
    if ((public_count > 0 || removed > 0)); then
      run_external_smoke
    else
      echo "registry publishes no public routes and none were withdrawn; skipping external smoke verification" >&2
    fi

    if [[ $allow_dirty == 1 ]]; then
      echo "service publication deployment succeeded from an uncommitted tree; refusing to record HEAD as the applied revision" >&2
      echo "$revision_file still names the last committed deployment; deploy from a committed tree before relying on addition/removal classification" >&2
      exit 0
    fi

    revision=$(git rev-parse HEAD)
    # The store sudo is not setuid, so only the NixOS wrapper can elevate here.
    /run/wrappers/bin/sudo install -d -m 0750 "$state_dir"
    printf '%s\n' "$revision" | /run/wrappers/bin/sudo tee "$revision_file" >/dev/null
    echo "service publication deployment succeeded at $revision"
  '';
  meta.description = "Run the full service publication deploy flow";
}
