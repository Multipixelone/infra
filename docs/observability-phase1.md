# Central observability on Link

Link remains the only Prometheus, Grafana, Loki, Alloy, Homepage, and alert-evaluation host. Link, Impa, IoT, and Marin are always-on; Zelda and Hylia are opportunistic WireGuard exporters whose absence never alerts. Darwin is never evaluated for systemd faults. Link directly probes both resolvers and scrapes Blocky with stable `resolver=link|impa` labels; cache gauges remain per resolver.

Phase 1 designates `link` as the observability hub without changing its
`desktop` role. It provisions Grafana, Prometheus, Loki, Alloy, Blackbox
Exporter, Homepage, nginx, Blocky records, and local read-only `mcp-grafana`.
Link remains the only Grafana and Prometheus host. The `iot` and `marin` hosts
run only node exporter with the systemd collector; port 9100 binds to each
host's LAN address and accepts connections only from Link (`192.168.6.6`).

## Activation gate

The stack is configured and included in the Link closure, but its systemd
services have `ConditionPathExists` checks for both of these agenix runtime
paths:

- `/run/agenix/cloudflare-acme-dns01`, sourced from
  `${inputs.secrets}/cloudflare/acme-dns01.age`. The encrypted file must contain
  `CF_DNS_API_TOKEN` for a Cloudflare token limited to DNS edit on the
  `finnrut.is` zone.
- `/run/agenix/grafana-admin`, sourced from
  `${inputs.secrets}/grafana/admin.age`. The encrypted file must contain
  shell-compatible `GRAFANA_ADMIN_PASSWORD=...` and `GRAFANA_SECRET_KEY=...`
  assignments.

The corresponding `age.secrets` entries are declared only when each encrypted
source exists, so evaluation remains green before they land. HTTPS is
TLS-only; no HTTP listener, public A/AAAA record, Cloudflare Tunnel, or public
ingress is configured. Do not reuse a tunnel credential for ACME.

The existing `telegram-deadman` environment is passed to Grafana only at
runtime. Its contact point is provisioned but intentionally has no notification
policy, so it cannot deliver during the seven-day review. Do not send a test or
dry-run message.

## Network rollout

Blocky generates only these Phase 1 records from the typed registry:

- `grafana.home.finnrut.is -> 192.168.6.6`
- `homepage.home.finnrut.is -> 192.168.6.6`

DNS TCP/UDP 53 and nginx TCP 443 are restricted to exactly
`192.168.5.0/24`, `192.168.6.0/24`, and `10.100.0.0/24`. Application backends
bind to `127.0.0.1`.

Manual step after the secrets exist and a reviewed deployment is approved:
advertise `192.168.6.6` as the DNS server in LAN DHCP. This repository does not
mutate the router or DHCP configuration.

## Retention and initial alert state

Prometheus retains 30 days **or** 2 GB of logical TSDB data, whichever limit is
reached first. Loki retains seven days. These are application retention
settings, not hard filesystem caps: Btrfs qgroups, partitions, loop devices,
and `StateDirectoryQuota` are intentionally absent.

The fleet dashboard derives its host selector from the typed observability node
registry and scopes all panels to the selected exporter. That same registry
generates node scrape jobs, missing-host rows, and alert policy. Every
Prometheus target normalizes its public `instance` label to a hostname or
endpoint FQDN; transport IP addresses, ports, and URLs remain scrape
implementation details and must not appear as dashboard names. The 15%-free
`RootDiskPressure` warning
applies independently to every required registered host; portable best-effort
nodes remain visible without paging when they are offline. Prometheus storage-growth
forecasting remains scoped to Link because Link owns the telemetry store.

Each service-publication route contributes one internal HTTPS probe to the
endpoint dashboards and rolling SLO. The direct backend check used before the
local cutover is not retained as a second `private` series for the same logical
endpoint. `SloErrorBudgetExhausted` also requires the live probe to have a
sample at the far edge of the seven-day window, so a new target cannot fire a
seven-day-budget alert from only a partial first week of data. Dashboard and
SLO queries collapse resolver-level copies to the logical endpoint FQDN using
the worst availability/latency result.

## Privacy boundary

Alloy drops journal entries carrying `_SYSTEMD_USER_UNIT` before they reach
Loki and redacts common authorization, token, password, secret, API-key,
Bearer, and Telegram-bot patterns. OpenClaw contributes no logs or payloads;
the only OpenClaw data is a textfile metric set containing service active,
failed, restart count, CPU, and memory values.

`mcp-grafana` is local stdio, connects only to loopback Grafana, and starts with
`--disable-write --enabled-tools=prometheus,loki`. PromQL and LogQL query scope
is otherwise unrestricted.

## Private media observability

Link also hosts a private media-observability slice. Plex and the existing
Alexandria applications are selected by their stable `application/root` route
identities in the service-publication inventory. Their direct API URLs are
derived from each route's backend scheme, resolved address, and port, while
Homepage links remain the inventory's canonical HTTPS names. Do not add a
second Alexandria host/port table. Plex is private and `/identity` is its
unauthenticated health target; neither Plex nor either exporter receives public
DNS, Tunnel ingress, nginx publication, or a firewall opening.

Scraparr and Tautulli exporter bind only to `127.0.0.1:7100` and
`127.0.0.1:8000`. Prometheus scrapes those loopback endpoints and probes the
Tautulli exporter's `/ready` endpoint through the existing local Blackbox
Exporter. Metric relabeling is a strict aggregate allowlist: user, title,
request, issue, path, provider, server, quality, genre, and per-item series are
dropped before ingestion. The dashboards use only aggregate service labels.
Alexandria storage, Node Exporter, Kometa, Watchtower, SAB failed-job alerting,
Tube Archivist, and qBittorrent remain deferred or excluded because Link has no
reliable bounded signal for them.

## Media credential bundle

The one encrypted source is `observability/media.age` in the private secrets
input. On Link it becomes `/run/agenix/media-observability`, owned by root with
mode `0400`. The declaration is optional until the encrypted source exists, so
pure evaluation does not require the bundle. Never put URLs in it; URLs are
route-derived. Create it manually on an authorized workstation using the
repository's normal agenix recipient workflow, then include exactly these
shell-compatible assignments:

```text
HOMEPAGE_VAR_PLEX_TOKEN=
HOMEPAGE_VAR_RADARR_KEY=
HOMEPAGE_VAR_SONARR_KEY=
HOMEPAGE_VAR_SEERR_KEY=
HOMEPAGE_VAR_BAZARR_KEY=
HOMEPAGE_VAR_SABNZBD_KEY=
HOMEPAGE_VAR_TAUTULLI_KEY=
RADARR_API_KEY=
SONARR_API_KEY=
SEERR_API_KEY=
BAZARR_API_KEY=
SABNZBD_API_KEY=
TAUTULLI_API_KEY=
```

The repeated application credentials are intentional: Homepage and exporters
use consumer-specific names so neither can accidentally consume the other's
contract. NZBHydra2 has no widget and needs no key. Homepage and the two media
exporters are conditioned on this file; Prometheus, Grafana, Loki, Alloy,
Blackbox, and Node Exporter are not.

## Images, validation, and operations

Exporter images are pinned by release tag and Linux/amd64 manifest digest.
For an update, read the tagged configuration/metric reference, reverify the
platform digest, review the relabel allowlist against every emitted metric,
and update the fixtures and documentation in the same commit. Never follow a
floating tag.

Before cutover, run formatting, generated-file consistency, focused Link
evaluation, service-publication safety checks, Prometheus rule/config tests,
Homepage and dashboard JSON checks, and repository-text secret scans. These are
non-deploying checks: do not read the runtime bundle. Deployment remains a
separate reviewed operation using the repository's Link deployment command;
this implementation does not deploy. After an approved Link deployment,
confirm loopback listeners, exporter readiness, scrape targets, and
aggregate-only labels. Roll back by deploying the previous known-good revision;
removing the bundle also stops only Homepage and the two media exporters through
their conditions.

Keep Grafana's notification policy null. Enabling delivery is future work and
requires at least 24 hours of clean aggregate telemetry plus deliberate firing
and recovery tests for each media alert. Do not route or test Telegram during
this cutover. Routine maintenance consists of digest review, checking exporter
release notes for metric/schema changes, and repeating the privacy fixtures.
