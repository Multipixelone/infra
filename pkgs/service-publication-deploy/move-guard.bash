#!/usr/bin/env bash
# Permit precisely the reviewed Link-to-Impa public-ingress cutover. This is
# intentionally a one-off classifier rather than a general move override.
set -euo pipefail

current_registry=${1:?usage: move-guard CURRENT_REGISTRY < PREVIOUS_REGISTRY}
previous_registry=$(</dev/stdin)

[[ ${SERVICE_PUBLICATION_APPROVE_MOVE:-} == link-to-impa ]] || exit 1

jq -e --argjson previous "$previous_registry" '
  def publicRoutes:
    [.routes | to_entries[] | select(.value.public) | .key] | sort;
  def publicOrigins:
    .routes | with_entries(select(.value.public)) | map_values(.proxy);
  def edgeHost($name; $address):
    .hosts[$name].site == "nyc"
    and .hosts[$name].addresses.lan == $address
    and .hosts[$name].managedByNixOS
    and .hosts[$name].capabilities.reverseProxy
    and .hosts[$name].capabilities.publicConnector;

  ($previous | publicRoutes) == ["seerr/root"]
  and publicRoutes == ["seerr/root"]
  and ($previous | publicOrigins) == {
    "seerr/root": { "host": "link", "lanAddress": "192.168.6.6" }
  }
  and publicOrigins == {
    "seerr/root": { "host": "impa", "lanAddress": "192.168.6.50" }
  }
  and $previous.cloudflare.tunnel.ingressHost == { "nyc": "link" }
  and .cloudflare.tunnel.ingressHost == { "nyc": "impa" }
  and ($previous.cloudflare.tunnel.connectorHosts == null)
  and .cloudflare.tunnel.connectorHosts == { "nyc": ["link", "impa"] }
  and ($previous | edgeHost("link"; "192.168.6.6"))
  and ($previous.hosts.impa == null)
  and edgeHost("link"; "192.168.6.6")
  and edgeHost("impa"; "192.168.6.50")
' "$current_registry" >/dev/null

echo "!!! SERVICE_PUBLICATION_APPROVE_MOVE=link-to-impa accepted: reviewed Link-to-Impa ingress move with dual connectors attested" >&2
