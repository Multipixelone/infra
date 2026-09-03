{
  bind,
  coreutils,
  curl,
  gitMinimal,
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "service-publication-smoke";
  runtimeInputs = [
    bind
    coreutils
    curl
    gitMinimal
    jq
  ];
  text = ''
    registry_file=''${SERVICE_PUBLICATION_REGISTRY:-}
    if [[ -z $registry_file ]]; then
      if ! repo_root=$(git rev-parse --show-toplevel); then
        echo "no repository checkout to resolve the generated registry from; set SERVICE_PUBLICATION_REGISTRY" >&2
        exit 1
      fi
      registry_file=$repo_root/infra/service-publication/registry.json
    fi
    context=''${1:-lan}
    route_filter=''${2:-}
    blocky_address_override=''${SERVICE_PUBLICATION_BLOCKY_ADDRESS:-}
    external_resolver=''${SERVICE_PUBLICATION_EXTERNAL_RESOLVER:-1.1.1.1}

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
      probe_list=externalProbes
    else
      probe_list=internalProbes
    fi

    # Assign first so errexit sees jq's status; a process substitution would hide it.
    routes_json=$(jq -c --arg route "$route_filter" ".''${probe_list}[] | $select_filter" "$registry_file")
    routes=()
    if [[ -n $routes_json ]]; then
      mapfile -t routes <<<"$routes_json"
    fi

    if ((''${#routes[@]} == 0)); then
      if [[ -n $route_filter ]]; then
        echo "no generated $context probe matches $route_filter" >&2
        exit 1
      elif [[ $context == external ]]; then
        echo "0 external probes - nothing validated (generated $probe_list is empty)" >&2
      else
        echo "generated $probe_list is empty; $context smoke validated no route" >&2
        exit 1
      fi
    fi

    for route in "''${routes[@]}"; do
      key=$(jq -r .key <<<"$route")
      hostname=$(jq -r .hostname <<<"$route")
      path=$(jq -r .path <<<"$route")
      timeout=$(jq -r .timeoutSeconds <<<"$route")

      if [[ $context == external ]]; then
        # Resolve through the public resolver and pin curl to that address. Run from
        # the LAN, the system resolver is Blocky, whose split-horizon record would
        # send the probe straight at the local proxy and never reach Access at all.
        edge=""
        while read -r candidate; do
          [[ $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && edge=$candidate
        done < <(dig "@$external_resolver" +short "$hostname" A)
        if [[ -z $edge ]]; then
          echo "$key: $hostname has no public A record on $external_resolver" >&2
          exit 1
        fi
        case "$edge" in
        10.* | 127.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*)
          echo "$key: $external_resolver returned private address $edge for $hostname; the external probe cannot reach the edge from here" >&2
          exit 1
          ;;
        esac
        if [[ $(jq -r '.access.bypassAccess' <<<"$route") == true ]]; then
          # A reviewed bypass is anonymous on purpose, so there is no Access
          # challenge to assert and demanding one would fail the deploy. Hold the
          # route to its own health contract instead, which is what still proves
          # the bypass reaches the origin rather than a Cloudflare error page.
          status=$(curl --silent --show-error --output /dev/null --max-time "$timeout" \
            --resolve "$hostname:443:$edge" \
            --write-out '%{http_code}' "https://$hostname$path")
          jq -e --argjson status "$status" '.expectedStatuses | index($status) != null' <<<"$route" >/dev/null || {
            echo "$key: bypassed external health returned $status" >&2
            exit 1
          }
        elif [[ -z ''${CF_ACCESS_CLIENT_ID:-} || -z ''${CF_ACCESS_CLIENT_SECRET:-} ]]; then
          challenge=$(curl --silent --show-error --output /dev/null --max-time "$timeout" \
            --resolve "$hostname:443:$edge" \
            --write-out '%{http_code} %{redirect_url}' "https://$hostname$path")
          read -r status redirect_url <<<"$challenge"
          case "$status" in
          301 | 302 | 303 | 307 | 308) ;;
          *)
            echo "$key: unauthenticated external response ($status) did not come from Cloudflare Access" >&2
            exit 1
            ;;
          esac
          redirect_host=''${redirect_url#*://}
          redirect_host=''${redirect_host%%/*}
          redirect_host=''${redirect_host##*@}
          redirect_host=''${redirect_host%%:*}
          if [[ $redirect_host != *.cloudflareaccess.com ]]; then
            echo "$key: unauthenticated external redirect to '$redirect_url' did not come from Cloudflare Access" >&2
            exit 1
          fi
        else
          # Feed the service token to curl through a config on stdin: header values
          # on argv would be readable in /proc/<pid>/cmdline for the probe's lifetime.
          access_id=''${CF_ACCESS_CLIENT_ID//\\/\\\\}
          access_id=''${access_id//\"/\\\"}
          access_secret=''${CF_ACCESS_CLIENT_SECRET//\\/\\\\}
          access_secret=''${access_secret//\"/\\\"}
          status=$(printf 'header = "CF-Access-Client-Id: %s"\nheader = "CF-Access-Client-Secret: %s"\n' \
            "$access_id" "$access_secret" |
            curl --config - --silent --show-error --output /dev/null --max-time "$timeout" \
              --resolve "$hostname:443:$edge" \
              --write-out '%{http_code}' "https://$hostname$path")
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
