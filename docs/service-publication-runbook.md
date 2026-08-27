# Service publication implementation and bootstrap runbook

Impa is the NYC active ingress and default proxy. The adopted Cloudflare account, zone, provider identity, and Tunnel name `link` remain unchanged. During overlap, generated wiring runs the same existing encrypted Tunnel credential on Link and Impa. Follow [`impa-edge-bootstrap-cutover.md`](impa-edge-bootstrap-cutover.md); retirement and provider operations are manual.

This runbook implements the accepted contract in
[`split-dns-service-publication.md`](split-dns-service-publication.md). The Nix
registry and all non-secret projections exist, and Finn has accepted the
Cloudflare adoption plan. Declarative wiring is enabled, while live rollout
still requires the separate authorization and prerequisites below. The accepted remote-state bucket
is recorded below. No command in this runbook has been run against a live host,
AWS account, or Cloudflare account as part of the implementation.

## Source and generated boundaries

- `modules/service-publication/registry.nix` is the typed intent registry.
- `lib/service-publication.nix` resolves proxy hosts and produces Blocky,
  nginx, SAN, probe, Tunnel, DNS, and Access projections. Evaluation rejects
  invalid or inconsistent projections before a NixOS or Cloudflare mutation.
- `infra/service-publication/registry.json` is generated, deterministic, and
  contains no credentials or Cloudflare account/resource IDs.
- `modules/service-publication/nixos.nix` consumes the projections on managed
  NixOS hosts. `rollout.enableLocalCutover` and `rollout.enableConnector` are
  false until their prerequisites are confirmed.
- `infra/service-publication/*.tf` consumes the generated JSON, Nix-packaged
  non-secret Cloudflare identifiers and adoption gate, and runtime secrets.
  OpenTofu owns adopted Cloudflare resources after bootstrap.

Application and route resources use stable `application` and
`application/route` keys. A backend or proxy move therefore changes an origin
value without changing resource identity.

## Required discovery inputs

Do not enable either rollout gate until this list is reviewed:

1. Confirm every NYC routed LAN CIDR, the VPN client source CIDR(s), and that
   VPN peers actually route the full NYC LAN inventory. The old observability
   list is not accepted as discovery evidence by itself.
2. Confirm each host LAN address, all proxy-capable hosts, and backend firewall
   reachability from every selected proxy.
3. Confirm each route's unauthenticated health path, accepted statuses, and
   timeout. Authenticated health endpoints need a reviewed runtime probe design
   before registration.
4. Inventory all existing public DNS records, Tunnel ingress entries,
   connectors, Access applications, reusable policies, application policies,
   and machine caller credentials. Record provider resource import IDs only in
   an operator's protected temporary environment. The stable Cloudflare account
   ID, `finnrut.is` zone ID, and existing Tunnel name belong in the typed Nix
   registry options documented below.
5. Select the first public application and policy explicitly. Seerr at
   `requests.finnrut.is` behind the `family` policy is the explicitly selected
   first public application; Grafana and Homepage remain private.
6. Use the accepted AWS S3 backend recorded under **Remote state bootstrap**.
   Its storage features are confirmed, but OpenTofu lock contention and stale
   lock recovery are not yet tested. Complete those tests before treating the
   backend bootstrap as operationally verified.

Fill `sites.nyc.routedLanCidrs`, `vpnClientCidrs`, `trustedClientCidrs`, and
`networkInventoryConfirmed = true` only after item 1. `routedLanCidrs` records
destinations pushed to VPN peers; only `trustedClientCidrs` grants inbound
access to the generated DNS, firewall, and nginx policy, and it must match
`observability.trustedClientCidrs`. Evaluate and deploy the
new local names, run LAN and VPN smoke tests, update clients/bookmarks, and only
then set `rollout.enableLocalCutover = true`. With that flag, the legacy
`*.home.finnrut.is` Blocky mappings, vhosts, SANs, and probe names are replaced;
no compatibility aliases are generated.

## Runtime secrets and declarative bootstrap values

The Link NixOS configuration conditionally references these encrypted files in
the private secrets input:

| Encrypted source                                  | Runtime path                                        | Contract                                                                                                                                 |
| ------------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `cloudflare/service-publication-api.age`          | `/run/agenix/service-publication-cloudflare-api`    | shell assignment for the separately scoped `CLOUDFLARE_API_TOKEN` only                                                                   |
| `cloudflare/service-publication-tunnel-token.age` | `/run/agenix/service-publication-tunnel-token`      | raw connector token, readable only by `cloudflared`                                                                                      |
| `aws/service-publication-state-credentials.age`   | `/run/agenix/service-publication-state-credentials` | shell assignments for `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; sourced and exported by the OpenTofu wrapper without logging them |

The two OpenTofu runtime files declared in
`modules/service-publication/runtime.nix` are owned by the repository operator
and installed with mode `0400`. The separately managed connector token is
declared by `modules/service-publication/nixos.nix` and remains readable only
by `cloudflared`.

The non-secret OpenTofu values have one source of truth in
`servicePublication.cloudflare` in `modules/service-publication/registry.nix`:

| Nix option                                       | Current value                      | Required value                                   |
| ------------------------------------------------ | ---------------------------------- | ------------------------------------------------ |
| `servicePublication.cloudflare.accountId`        | `4b74fb7e0a35c9c1148bf0434d7fdffa` | the existing Cloudflare account ID               |
| `servicePublication.cloudflare.zoneId`           | `d8bb324032c2738ff17efde63e9a7988` | the existing `finnrut.is` zone ID                |
| `servicePublication.cloudflare.tunnelName`       | `link`                             | the exact name of the adopted Tunnel             |
| `servicePublication.cloudflare.adoptionComplete` | `true`                             | accepted after review of the adoption plan below |

The wrapper receives these values from a generated Nix-store file. It refuses
to initialize OpenTofu when any identifier is still `null`. Enabling
`adoptionComplete` also makes Nix evaluation assert that all three identifiers
are declared. Credentials never enter that file or the Nix store.

The provider lock selects Cloudflare provider v5.23.0. Its
[Tunnel resource schema](https://registry.terraform.io/providers/cloudflare/cloudflare/5.23.0/docs/resources/zero_trust_tunnel_cloudflared)
makes `tunnel_secret` optional and defines it as the password for a locally
managed Tunnel. The adopted Link Tunnel is remotely managed
(`config_src = "cloudflare"`), so the OpenTofu configuration intentionally
omits `tunnel_secret` and does not provision a corresponding agenix secret. The
dashboard-created connector token is a different credential: it is consumed
only by `cloudflared` and must not be supplied as `tunnel_secret`.

The ACME DNS-01 credential remains the existing, separate
`cloudflare/acme-dns01.age`. A cloudflared connector token and ACME token must
never be reused as the OpenTofu API credential.

As of the provider version selected here, the separately scoped API token needs
only Cloudflare Tunnel edit and Access Apps and Policies edit at the account,
plus DNS edit for the `finnrut.is` zone. Recheck those scopes against the
[Cloudflare Tunnel Terraform guide](https://developers.cloudflare.com/tunnel/deployment-guides/terraform/)
and the exact resources in the reviewed plan before minting it.

## Remote state bootstrap

Current checklist (checked items are confirmed inputs, not evidence of a live
OpenTofu initialization):

- [x] AWS S3 bucket `finntf-557459769096-us-east-1-an` accepted in
      `us-east-1` (`arn:aws:s3:::finntf-557459769096-us-east-1-an`).
- [x] Bucket versioning enabled.
- [x] S3 Object Lock enabled.
- [x] The Nix-generated backend config selects key
      `service-publication/cloudflare.tfstate`, `encrypt = true`, and
      `use_lockfile = true`.
- [ ] Conditional-write lock contention tested with two OpenTofu processes.
- [ ] Failed/stale OpenTofu lock recovery tested without `-lock=false`.

S3 Object Lock and OpenTofu locking solve different problems. Object Lock is an
S3 retention/WORM feature for object versions; it does not coordinate OpenTofu
writers. With `use_lockfile = true`, OpenTofu coordinates writers through a
separate lock object and conditional S3 writes. The enabled Object Lock setting
therefore does not prove that lock contention works, and those tests remain
unchecked above.

1. Do not recreate or reconfigure the accepted bucket from this OpenTofu state.
2. The wrapper package carries the accepted non-secret backend settings in a
   Nix-store file and passes that file to `tofu init -backend-config`. Store
   backend authentication only in
   `aws/service-publication-state-credentials.age`; the wrapper requires its
   runtime path and exports both AWS variables before initializing OpenTofu.

   ```bash
   cd /home/tunnel/Documents/Git/nix-secrets
   agenix -e aws/service-publication-state-credentials.age -i /home/tunnel/.ssh/agenix
   ```

3. Before the backend is operationally accepted, prove that two simultaneous
   test operations contend on the same lock object and that a failed lock holder
   can be recovered without `-lock=false`. OpenTofu recommends native S3
   locking with `use_lockfile = true`; see the
   [OpenTofu S3 backend documentation](https://opentofu.org/docs/language/settings/backends/s3/).
4. Leave `servicePublication.cloudflare.adoptionComplete = false` while
   inventory/import work is in progress. The packaged configuration blocks
   normal plans, applies, and outputs; only imports and the explicit
   `adoption-plan` review path are available.
5. Initialize only through
   `nix run .#service-publication-tofu -- ...`; it rejects unreadable secret
   files, missing declarative identifiers, missing credential variables, or a
   packaged backend without the lock flag. It never falls back to local state
   or an ambient AWS credential chain.

## Adoption without replacement

First fill the reviewed non-secret policy rules in the Nix registry. Set each
policy's `cloudflareImportKey` to a stable logical key such as `finn-only`; the
actual UUID remains runtime-only. Regenerate `registry.json`, then import every
matching live resource using placeholders resolved during inventory:

```bash
nix run .#service-publication-tofu -- import \
  'cloudflare_zero_trust_access_policy.managed["<policy-key>"]'

nix run .#service-publication-tofu -- import \
  'cloudflare_zero_trust_access_application.managed["<application-key>"]'

nix run .#service-publication-tofu -- import \
  cloudflare_zero_trust_tunnel_cloudflared.managed

nix run .#service-publication-tofu -- import \
  cloudflare_zero_trust_tunnel_cloudflared_config.managed

nix run .#service-publication-tofu -- import \
  'cloudflare_dns_record.public["<application-key>"]'
```

The wrapper prompts without echo for each provider import ID. Supplying
`SERVICE_PUBLICATION_IMPORT_ID` from a protected operator environment is also
supported; do not put real IDs in shell scripts, committed tfvars, or runbooks.
The import subcommand overrides the hard `bootstrap_complete` variable
validation only for that non-apply operation. For Cloudflare provider v5.23.0,
both the Tunnel resource and its Tunnel configuration use the same
`<account_id>/<tunnel_id>` pair; there is no separate configuration import ID.
Normal plans, applies, and outputs remain blocked until
`servicePublication.cloudflare.adoptionComplete` is `true`.

Provider import formats can change; confirm them against the pinned provider's
resource documentation immediately before use. The imported Tunnel retains
`config_src = "cloudflare"`; its lifecycle has `prevent_destroy = true`, and the
wrapper rejects every plan containing a replacement. Treat any proposed Tunnel
replacement as an adoption blocker rather than applying it. Application-scoped
Access policies in Cloudflare provider v5 are inline on the Access application.
Follow the provider's
[v5 migration guidance](https://github.com/cloudflare/terraform-provider-cloudflare/blob/main/docs/guides/version-5-migration.md)
and never apply an intermediate plan that detaches policies.

After all imports, review the pre-adoption state through the only plan command
allowed while the gate remains false:

```bash
nix run .#service-publication-tofu -- adoption-plan
```

This command temporarily satisfies the OpenTofu validation for that plan only;
it has no apply path. Reconcile imports and declarative configuration, then
repeat `adoption-plan` until the result is no-op or an explicitly understood
non-destructive delta. Any replacement is rejected by the wrapper.

The current registry publishes one public Tunnel route (`seerr/root` at
`requests.finnrut.is`), so its desired ingress is that route followed by the
terminal `http_status:404` catch-all. If an adoption plan proposes removing
other existing live ingress entries, treat that as destructive operational
drift: reconcile the registry and do not apply the removal.

The wrapper enforces that rule instead of trusting review. Every `plan`,
`adoption-plan`, and `apply` compares the planned Tunnel configuration's
`before` and `after` ingress: hostnames that disappear abort an `apply` before
its approval prompt, and both plan paths print the same list as a warning.
`service-publication-deploy` passes the canonical hostnames of the public
routes it withdraws in `SERVICE_PUBLICATION_EXPECTED_INGRESS_REMOVALS`
(comma- or space-separated), so a registry-modelled unpublish still applies.
Set that variable by hand only for a reviewed removal of ingress the registry
never modelled.

Only after the adoption plan is accepted, change
`servicePublication.cloudflare.adoptionComplete` to `true`. Then run
`just deploy-services plan-only` for the final normal gated plan. Apply only
through the separately authorized normal deployment flow, and enable the Nix
connector only after the existing and new connector instances can overlap
safely.

## Deployment and verification

`just deploy-services` is the only normal mutation flow. It regenerates and
checks artifacts, formats Nix/OpenTofu, scans for secrets, evaluates the flake,
builds focused checks, and stops on the first failure. Additions deploy and
probe the local origin before the locked OpenTofu plan is applied. Removals
withdraw Cloudflare reachability first. Mixed add/remove changes are rejected
so the ordering cannot be ambiguous.

Runtime probe inputs are:

- `SERVICE_PUBLICATION_BLOCKY_ADDRESS` optionally overrides the declarative
  internal-DNS host address for diagnostic LAN probes;
- `SERVICE_PUBLICATION_VPN_PROBE_COMMAND`, optional, executed on a genuine VPN
  client and expected to run the generated inventory's VPN checks. No VPN client
  is guaranteed to be up, so leaving it unset is allowed: the deploy prints that
  the VPN view stays unproven and continues on the LAN proof alone. Set it (for
  example an `ssh <client>` wrapper around `service-publication-smoke vpn`) for
  any change where the VPN path has to be verified before publication;
- `SERVICE_PUBLICATION_EXTERNAL_RESOLVER` optionally overrides the public
  resolver (default `1.1.1.1`) that the external probe resolves published
  hostnames through and asserts private names against; and
- `SERVICE_PUBLICATION_EXTERNAL_PROBE_COMMAND`, optional, an off-network runner
  for the external checks. Access service-token values must be passed through
  that runner's secret environment and never printed. Left unset, the deploy
  runs `service-publication-smoke external` locally: the probe resolves each
  published hostname through the public resolver and pins curl to that address,
  so Blocky's split-horizon record cannot short-circuit it and Access is proven
  at the real edge. The probe fails rather than passing quietly if the public
  resolver has no answer, or answers with a private address. Only the source
  address remains local, so set the variable for changes that must also prove a
  foreign client path. External verification runs only when the registry
  publishes at least one public route, or when this deployment withdraws one; a
  registry with no public routes skips it and says so.

Useful diagnostic forms are:

```bash
just deploy-services plan-only
just services-smoke lan grafana/root
just services-smoke vpn grafana/root
just services-smoke external '<public-app>/<route>'
```

The successful registry revision is recorded outside the repository at
`/var/lib/service-publication/last-successful-revision`. The next deployment
uses it to distinguish additions from removals. A proxy/connector move is not
automated: use the accepted overlap procedure, keep the old connector healthy,
verify both paths, then change the role and retire the old instance only after
the separately agreed observation interval.

Because the flow applies the working tree but can only record a commit, the
apply mode refuses to start while tracked files are modified or staged: commit
them first. Untracked files do not block. `SERVICE_PUBLICATION_ALLOW_DIRTY=1`
is the deliberate escape hatch for an emergency apply from an uncommitted tree;
it skips that gate and then refuses to record a revision, so the recorded
revision never claims to describe a tree that was never committed.

## Rollback

Use the same registry and `just deploy-services` flow with a reviewed previous
revision. Never edit the Cloudflare dashboard as a normal rollback. If state
locking, Access, certificate readiness, or smoke verification fails, leave
Access protection intact and stop. Restore the previous origin or withdraw new
DNS/Tunnel reachability through a reviewed plan; never use local state,
`-lock=false`, `no_tls_verify`, or a legacy `home.finnrut.is` alias as a repair.
