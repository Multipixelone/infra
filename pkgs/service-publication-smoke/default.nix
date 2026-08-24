{
  bind,
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "service-publication-smoke";
  runtimeInputs = [
    bind
    coreutils
    curl
    jq
  ];
  text = ''
    repo_root=$(git rev-parse --show-toplevel)
    registry_file=''${SERVICE_PUBLICATION_REGISTRY:-$repo_root/infra/service-publication/registry.json}
    context=''${1:-lan}
    route_filter=''${2:-}
    blocky_address_override=''${SERVICE_PUBLICATION_BLOCKY_ADDRESS:-}

    case "$context" in
    lan | vpn | external) ;;
    *)
      echo "usage: $0 {lan|vpn|external} [application/route]" >&2
      exit 2
      ;;
    esac

    if [[ ! -r $registry_file ]]; then
      echo "missing generated registry: $registry_file" >&2
      exit 1
    fi

    select_filter='.'
    if [[ -n $route_filter ]]; then
      # shellcheck disable=SC2016 # $route is a jq variable, not a shell variable.
      select_filter='select(.key == $route)'
    fi

    if [[ $context == external ]]; then
      mapfile -t routes < <(jq -c --arg route "$route_filter" ".externalProbes[] | $select_filter" "$registry_file")
    else
      mapfile -t routes < <(jq -c --arg route "$route_filter" ".internalProbes[] | $select_filter" "$registry_file")
    fi

    if ((''${#routes[@]} == 0)) && [[ -n $route_filter ]]; then
      echo "no generated $context probe matches $route_filter" >&2
      exit 1
    fi

    for route in "''${routes[@]}"; do
      key=$(jq -r .key <<<"$route")
      hostname=$(jq -r .hostname <<<"$route")
      path=$(jq -r .path <<<"$route")
      timeout=$(jq -r .timeoutSeconds <<<"$route")

      if [[ $context == external ]]; then
        if [[ -z ''${CF_ACCESS_CLIENT_ID:-} || -z ''${CF_ACCESS_CLIENT_SECRET:-} ]]; then
          status=$(curl --silent --show-error --output /dev/null --max-time "$timeout" --write-out '%{http_code}' "https://$hostname$path")
          case "$status" in
          301 | 302 | 303 | 307 | 308 | 401 | 403) ;;
          *)
            echo "$key: unauthenticated external request did not receive an Access challenge ($status)" >&2
            exit 1
            ;;
          esac
        else
          status=$(curl --silent --show-error --output /dev/null --max-time "$timeout" --write-out '%{http_code}' \
            --header "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
            --header "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
            "https://$hostname$path")
          jq -e --argjson status "$status" '.expectedStatuses | index($status) != null' <<<"$route" >/dev/null || {
            echo "$key: Access-aware external health returned $status" >&2
            exit 1
          }
        fi
      else
        proxy=$(jq -r .proxyAddress <<<"$route")
        resolver=$(jq -r .resolverAddress <<<"$route")
        blocky_address=''${blocky_address_override:-$resolver}
        if [[ -z $blocky_address || $blocky_address == null ]]; then
          echo "$key: generated internal probe has no Blocky resolver address" >&2
          exit 1
        fi
        answer=$(dig "@$blocky_address" +short "$hostname" A | tail -n 1)
        [[ $answer == "$proxy" ]] || {
          echo "$key: $context DNS returned '$answer', expected '$proxy'" >&2
          exit 1
        }
        status=$(curl --silent --show-error --output /dev/null --max-time "$timeout" \
          --resolve "$hostname:443:$proxy" --write-out '%{http_code}' "https://$hostname$path")
        jq -e --argjson status "$status" '.expectedStatuses | index($status) != null' <<<"$route" >/dev/null || {
          echo "$key: $context health returned $status" >&2
          exit 1
        }
        alias=$(jq -r '.alias // empty' <<<"$route")
        if [[ -n $alias ]]; then
          alias_answer=$(dig "@$blocky_address" +short "$alias" A | tail -n 1)
          [[ $alias_answer == "$proxy" ]] || {
            echo "$key: $context alias DNS returned '$alias_answer', expected '$proxy'" >&2
            exit 1
          }
          redirect=$(curl --silent --show-error --head --output /dev/null --max-time "$timeout" \
            --resolve "$alias:443:$proxy" --write-out '%{http_code} %{redirect_url}' "https://$alias$path")
          [[ $redirect == "308 https://$hostname"* ]] || {
            echo "$key: $context alias did not redirect to $hostname ($redirect)" >&2
            exit 1
          }
        fi
      fi
      echo "$key: $context probe passed"
    done

    if [[ $context == external ]]; then
      external_resolver=''${SERVICE_PUBLICATION_EXTERNAL_RESOLVER:-1.1.1.1}
      mapfile -t private_names < <(jq -r '
        .applications | to_entries[] |
        if .value.public then .value.alias else .value.canonical end |
        select(. != null)
      ' "$registry_file")
      mapfile -t legacy_names < <(jq -r '.applications | keys[] | . + ".home.finnrut.is"' "$registry_file")
      for name in "''${private_names[@]}" "''${legacy_names[@]}"; do
        answer=$(dig "@$external_resolver" +short "$name" A)
        answer="''${answer}$(dig "@$external_resolver" +short "$name" AAAA)"
        answer="''${answer}$(dig "@$external_resolver" +short "$name" CNAME)"
        [[ -z $answer ]] || {
          echo "$name: unexpected external/legacy DNS answer" >&2
          exit 1
        }
      done
    fi
  '';
  meta.description = "Run service publication smoke probes";
}
