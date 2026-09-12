# Central observability on Link

Link remains the only Prometheus, Grafana, Loki, Alloy, Homepage, and alert-evaluation host. Link, Impa, IoT, and Marin are always-on and are the only scrape targets; the laptops Zelda and Hylia are deliberately not scraped, because a target that is off the network most of the time is down by design and reports nothing when it is. Darwin is never evaluated for systemd faults. Link directly probes both resolvers and scrapes Blocky with stable `resolver=link|impa` labels; cache gauges remain per resolver.

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
applies independently to every registered host, all of which are always-on.
Prometheus storage-growth
forecasting remains scoped to Link because Link owns the telemetry store.

Each service-publication route contributes one internal HTTPS probe to the
endpoint dashboards and rolling SLO. The direct backend check used before the
local cutover is not retained as a second `private` series for the same logical
endpoint. The recorded effective probe status treats either a completed-probe
failure or a failed Prometheus scrape of the Blackbox job as downtime.
Seven-day budget and latency alerts also require the live probe to have a sample
at the far edge of the window, so a new target cannot fire a full-window alert
from only a partial first week of data. Dashboard and SLO queries collapse
resolver-level copies to the logical endpoint FQDN using the worst
availability/latency result.

## Duration semantics: evaluator state versus durable incident history

Treat `ALERTS` and `ALERTS_FOR_STATE` as Prometheus evaluator state, not an
incident ledger. `Longest evaluator age` and `Firing alerts (evaluator age)` calculate
`time() - ALERTS_FOR_STATE...`; their displayed age is the age of the current
matching rule evaluation state, including pending time and the rule's `for`
period, rather than authoritative outage age. A reload can preserve matching
state in memory and does not inherently reset alerts. Restart recovery depends
on retained state, matching identity, and bounded restoration; rule, group, or
label changes and state loss may reset or adjust its timestamp. The repository
does not explicitly override Prometheus recovery flags: upstream defaults are a
one-hour outage tolerance and ten-minute grace period. `NixOSHostExporterDown`
has `for = "5m"`, and short-`for` rules may therefore not restore. These are
semantics, not a claim that every restart resets state or that recovery proves
continuous incident history.

| Panels                                                                 | Intended semantics                                  | Do not use as / remediation                                                                                                                                     |
| ---------------------------------------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Longest evaluator age`, `Firing alerts (evaluator age)`               | Evaluator-state age, including pending/`for`        | Incident or outage age; label the value as evaluator state/age.                                                                                                 |
| `Alert evaluator state over time`, `Firing alert count over time`      | Retained evaluator history                          | Confirmed recovery or uninterrupted history; gaps can also reflect missing series or evaluator interruption.                                                    |
| `Evaluator timestamp changes`                                          | Observed changes to evaluator activation timestamps | Durable incident-episode count. It excludes first observations and pending-to-firing when the timestamp is unchanged, and can include reactivation or rebasing. |
| `Load and host uptime`, `NixOS hosts`, `Host uptime`, `Blocky process` | Host/process uptime and restart telemetry           | Service-incident duration. Keep them for restart diagnosis.                                                                                                     |

Use this vocabulary in dashboards and runbooks: **evaluator-state age** is the
age of current rule state; **host/process uptime** is time since boot or process
start; **event freshness** is age since an application-recorded successful
event; **retained-window availability** is availability computed from retained
samples; and **durable incident age** is elapsed time for an incident held in a
durable event system. Survival across telemetry loss requires state persisted
outside telemetry history; a persisted last-success timestamp is event
freshness, not incident lifecycle.

For a bounded “time since last successful observation” over retained samples,
use a query such as:

```promql
time() -
max_over_time(
  (
    timestamp(up{job="example"})
    and (up{job="example"} == 1)
  )[30d:1m]
)
```

The scrape timestamp becomes a value before success filtering. This is time
since the latest successful scrape selected by the subquery, not incident
duration; grid resolution, scrape jitter, and short successes matter. No
success returns no series, label changes split history, and removed identities
need separate handling. The lookback is not guaranteed retention, and a broad
30-day subquery must not run on an auto-refresh dashboard. Do **not** use
`timestamp(last_over_time((up == 1)[30d:]))`: `last_over_time` returns the
selected value, and the outer `timestamp()` describes its instant-vector result
rather than reliably preserving the selected sample timestamp. The 30-day range
is an upper bound, not a guarantee: the 2 GB retention limit may shorten it.
Pair freshness with an expected-target/missing-target signal (for example, a
suitably scoped `absent(up{...})`); `absent` cannot distinguish an intentionally
removed target from a failed one, and a target removed beyond the retained
window has no history to query.

For user-impact availability, prefer the existing blackbox or
application-health signals over exporter `up`: `up` establishes that Prometheus
scraped an exporter, not that users could use the service. For a durable
successful-event age, follow the backup precedent: record a last-success
timestamp only after the application operation succeeds, rather than deriving
it from rule state.

Marin evidence, audited 2026-09-11 over the preceding seven days, illustrates
the distinction: retained `up == 0` samples begin at approximately
2026-09-05 06:50 UTC; the Prometheus process start timestamp is
2026-09-10 13:27:56 UTC; and the evaluator timestamp rebased about two seconds
later. The window contains 13 observed process-start timestamp changes. These
are observed changes, not crash determinations, and gaps do not establish an
uninterrupted real-world outage.

Prometheus defines pending and `for` alert-rule behavior in its
[alerting-rule documentation](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/).
Its [`--rules.alert.for-outage-tolerance` and
`--rules.alert.for-grace-period` controls](https://prometheus.io/docs/prometheus/latest/command-line/prometheus)
provide bounded recovery behavior, not durable incident history. See also the
[PromQL function reference](https://prometheus.io/docs/prometheus/latest/querying/functions/),
[staleness semantics](https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness),
and Grafana's [target-down and missing-target guidance](https://grafana.com/docs/grafana/next/datasources/prometheus/alerting.md).

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
`127.0.0.1:8000`. Prometheus scrapes those loopback endpoints; exporter-process
health comes from Prometheus `up`. Tautulli API collection health has no signal:
the exporter emits no `plex_up` or scrape-failure metric and keeps serving the
last value of its `plex_*` gauges when a collection fails, so nothing separates a
stalled collector from an idle Plex. Metric relabeling is a strict aggregate
allowlist: user, title, request, issue, path, provider, server, quality, genre,
and per-item series are dropped before ingestion. The dashboards use only
aggregate service labels.
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

## DNS diagnostic telemetry

`blackbox-dns` remains the canonical private-record availability signal.
`blackbox-dns-checks` is a separate, bounded public-positive diagnostic contract
labelled by `resolver`, `layer`, `vantage`, `transport`, `ip_family`, and
`check`; dashboard and alert expressions keep that complete identity instead of
collapsing different checks on one resolver. Its assertion result and exporter
scrape reachability are shown separately, so missing telemetry is never shown as
healthy. The Unbound exporter is additionally checked with `unbound_up` only
when its own scrape is reachable.

The pinned unbound_exporter exposes `unbound_request_list_current_*` gauges and
`unbound_request_list_exceeded_total`, but the configured Unbound request-list
capacity is not exported as a matching bounded signal. A sustained request-list
pressure alert is deferred: a raw occupancy threshold or a single counter
increment would not be a defensible no-traffic/reset-safe incident condition.
No dnscrypt-proxy blocked-query metric or resolver operational-log claim is
used; secure Impa journal delivery remains blocked pending dedicated
TLS/client-auth secrets.
