{
  bind,
  coreutils,
  curl,
  gitMinimal,
  jq,
  python3,
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
    python3
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
      select_filter='select((.routeKey // .key) == $route or .key == $route)'
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

    check_edge_only_dns_once() {
      local key=$1 resolver=$2 hostname=$3 proxy=$4 record_type answer
      local answers=()
      for record_type in A AAAA; do
        if ! answer=$(dig -r "@$resolver" +time=3 +tries=1 +noall +comments +answer "$hostname." "$record_type"); then
          echo "$key: failed to query $hostname $record_type on $resolver" >&2
          return 1
        fi
        answers+=("$answer")
      done
      python3 - "$key" "$resolver" "$proxy" "''${SERVICE_PUBLICATION_ALLOW_UNPUBLISHED_DNS:-}" "''${answers[@]}" <<'PY'
    import ipaddress
    import re
    import sys

    key, resolver, proxy, allow_unpublished, *answers = sys.argv[1:]

    def unmap(address):
        return getattr(address, "ipv4_mapped", None) or address

    origin = unmap(ipaddress.ip_address(proxy))
    public_answer = False
    nxdomain = False
    for record_type, answer in zip(("A", "AAAA"), answers):
        status = re.search(r"^;; ->>HEADER<<- .*\bstatus: ([A-Z]+),", answer, re.MULTILINE)
        if not status or status[1] not in ("NXDOMAIN", "NOERROR"):
            sys.exit(f"{key}: unexpected {record_type} DNS status on {resolver}: {status[1] if status else 'missing'}")
        nxdomain |= status[1] == "NXDOMAIN"
        for line in answer.splitlines():
            fields = line.split()
            if len(fields) < 4 or fields[2] != "IN" or fields[3] not in ("A", "AAAA"):
                continue
            rr_type = fields[3]
            try:
                address = ipaddress.ip_address(fields[4])
            except (IndexError, ValueError):
                sys.exit(f"{key}: malformed {rr_type} DNS answer on {resolver}")
            if len(fields) != 5 or address.version != (4 if rr_type == "A" else 6):
                sys.exit(f"{key}: malformed {rr_type} DNS answer on {resolver}")
            # Mapped IPv4 must not let a private or origin address through as IPv6.
            address = unmap(address)
            if (address == origin or not address.is_global or address.is_multicast
                    or address.is_reserved or getattr(address, "is_site_local", False)):
                sys.exit(f"{key}: {resolver} returned a non-public or origin {rr_type} answer: {address}")
            if status[1] != "NOERROR":
                sys.exit(f"{key}: {resolver} returned an address with {status[1]} for {record_type}")
            public_answer |= rr_type == record_type

    # Only a valid negative or empty result is retryable; all other failures
    # (including a private answer in either family) abort immediately.
    if allow_unpublished != "1" and (nxdomain or not public_answer):
        sys.exit(75)
    PY
    }

    edge_dns_deadline=0
    check_edge_only_dns() {
      local key=$1 resolver=$2 hostname=$3 proxy=$4 result announced=0
      while :; do
        if check_edge_only_dns_once "$key" "$resolver" "$hostname" "$proxy"; then
          return 0
        else
          result=$?
        fi
        if ((result != 75)); then
          return "$result"
        fi
        if [[ ''${SERVICE_PUBLICATION_WAIT_FOR_EDGE_DNS:-} != 1 ]]; then
          echo "$key: $hostname on $resolver needs NOERROR for both A and AAAA and at least one public address" >&2
          return 1
        fi
        if ((edge_dns_deadline == 0)); then
          # Blocky caches negative replies for 30 minutes by default. Use one
          # shared retry window per smoke run with some room for upstream DNS.
          edge_dns_deadline=$((SECONDS + 2100))
        fi
        if ((SECONDS >= edge_dns_deadline)); then
          echo "$key: timed out waiting for published DNS for $hostname on $resolver (need NOERROR for both A and AAAA and at least one public address)" >&2
          return 1
        fi
        if ((announced == 0)); then
          echo "$key: waiting for negative DNS cache/propagation for $hostname on $resolver" >&2
          announced=1
        fi
        sleep 15
      done
    }

    for route in "''${routes[@]}"; do
      key=$(jq -r .key <<<"$route")
      hostname=$(jq -r .hostname <<<"$route")
      path=$(jq -r .path <<<"$route")
      timeout=$(jq -r .timeoutSeconds <<<"$route")
      edge_only=$(jq -r '.edgeOnly // false' <<<"$route")
      curl_options=()
      if [[ $edge_only == true ]]; then
        # Do not let ~/.curlrc add credentials or redirects, or let an HTTPS
        # proxy bypass --resolve. These probes must be anonymous and pinned.
        curl_options=(--disable --noproxy '*')
      fi

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
        elif [[ $edge_only == true || -z ''${CF_ACCESS_CLIENT_ID:-} || -z ''${CF_ACCESS_CLIENT_SECRET:-} ]]; then
          challenge=$(curl "''${curl_options[@]}" --silent --show-error --output /dev/null --max-time "$timeout" \
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
        if [[ $edge_only == true ]]; then
          check_edge_only_dns "$key" "$blocky_address" "$hostname" "$proxy"
        else
          answer=$(dig "@$blocky_address" +short "$hostname" A | tail -n 1)
          [[ $answer == "$proxy" ]] || {
            echo "$key: $context DNS returned '$answer', expected '$proxy'" >&2
            exit 1
          }
        fi
        status=$(curl "''${curl_options[@]}" --silent --show-error --output /dev/null --max-time "$timeout" \
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
