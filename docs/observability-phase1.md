# Phase 1 Link observability

Phase 1 designates `link` as the observability hub without changing its
`desktop` role. It provisions Grafana, Prometheus, Loki, Alloy, Blackbox
Exporter, Homepage, nginx, Blocky records, and local read-only `mcp-grafana`.

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

Link root was already 89% used during implementation. The 15%-free
`RootDiskPressure` warning is therefore expected to fire on first activation
and must not be silenced. Review disk capacity before any rebuild, switch, or
deployment.

## Privacy boundary

Alloy drops journal entries carrying `_SYSTEMD_USER_UNIT` before they reach
Loki and redacts common authorization, token, password, secret, API-key,
Bearer, and Telegram-bot patterns. OpenClaw contributes no logs or payloads;
the only OpenClaw data is a textfile metric set containing service active,
failed, restart count, CPU, and memory values.

`mcp-grafana` is local stdio, connects only to loopback Grafana, and starts with
`--disable-write --enabled-tools=prometheus,loki`. PromQL and LogQL query scope
is otherwise unrestricted.
