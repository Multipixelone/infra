# Service publication implementation and bootstrap runbook

This runbook implements the accepted contract in
[`split-dns-service-publication.md`](split-dns-service-publication.md). The Nix
registry and all non-secret projections exist, but rollout remains deliberately
disabled until the remaining discovery and Cloudflare adoption inputs below
are supplied by Finn. The accepted remote-state bucket is recorded below. No
command in this runbook has been run against a live host, AWS account, or
Cloudflare account as part of the implementation.

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
- `infra/service-publication/*.tf` consumes only the generated JSON plus
  runtime bootstrap variables. OpenTofu owns adopted Cloudflare resources after
  bootstrap.

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
   and machine caller credentials. Record IDs only in the agenix bootstrap file or
   an operator's temporary shell, never in this repository.
5. Select the first public application and policy explicitly. The current
   registry makes Grafana and Homepage private; neither is implicitly a pilot.
6. Use the accepted AWS S3 backend recorded under **Remote state bootstrap**.
   Its storage features are confirmed, but OpenTofu lock contention and stale
   lock recovery are not yet tested. Complete those tests before treating the
   backend bootstrap as operationally verified.

Fill `sites.nyc.routedLanCidrs`, `vpnClientCidrs`, and
`networkInventoryConfirmed = true` only after item 1. Evaluate and deploy the
new local names, run LAN and VPN smoke tests, update clients/bookmarks, and only
then set `rollout.enableLocalCutover = true`. With that flag, the legacy
`*.home.finnrut.is` Blocky mappings, vhosts, SANs, and probe names are replaced;
no compatibility aliases are generated.

## Runtime secrets and non-committed bootstrap values

The Link NixOS configuration conditionally references these encrypted files in
the private secrets input:

| Encrypted source                                   | Runtime path                                        | Contract                                                                                                                                     |
| -------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `cloudflare/service-publication-api.age`           | `/run/agenix/service-publication-cloudflare-api`    | shell assignment for the separately scoped `CLOUDFLARE_API_TOKEN` only                                                                       |
| `cloudflare/service-publication-bootstrap.age`     | `/run/agenix/service-publication-bootstrap`         | shell assignments for `TF_VAR_cloudflare_account_id`, `TF_VAR_cloudflare_zone_id`, `TF_VAR_tunnel_name`, and `TF_VAR_bootstrap_complete`     |
| `cloudflare/service-publication-tunnel-secret.age` | `/run/agenix/service-publication-tunnel-secret`     | raw existing Tunnel secret; never echo it                                                                                                    |
| `cloudflare/service-publication-backend.age`       | `/run/agenix/service-publication-backend`           | partial S3 backend HCL with the accepted non-secret settings; AWS authentication is supplied separately through the runtime credential chain |
| `cloudflare/service-publication-tunnel-token.age`  | `/run/agenix/service-publication-tunnel-token`      | raw connector token, readable only by `cloudflared`                                                                                          |
| `aws/service-publication-state-credentials.age`    | `/run/agenix/service-publication-state-credentials` | shell assignments for `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; sourced and exported by the OpenTofu wrapper without logging them     |

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
- [x] Backend template selects key
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
2. Copy the exact payload from
   `infra/service-publication/backend.hcl.example` into
   `cloudflare/service-publication-backend.age` in the private secrets input.
   Keep AWS credentials out of both backend files. Store them only in
   `aws/service-publication-state-credentials.age`; the wrapper requires its
   runtime path and exports both AWS variables before initializing OpenTofu.

   ```bash
   cd /home/tunnel/Documents/Git/nix-secrets
   agenix -e cloudflare/service-publication-backend.age -i /home/tunnel/.ssh/agenix
   ```

3. Before the backend is operationally accepted, prove that two simultaneous
   test operations contend on the same lock object and that a failed lock holder
   can be recovered without `-lock=false`. OpenTofu recommends native S3
   locking with `use_lockfile = true`; see the
   [OpenTofu S3 backend documentation](https://opentofu.org/docs/language/settings/backends/s3/).
4. Leave `TF_VAR_bootstrap_complete=false` while inventory/import work is in
   progress. The configuration check blocks plans and applies.
5. Initialize only through `scripts/service-publication/tofu.sh`; it rejects an
   unreadable runtime file, missing runtime variables, or a backend without the
   lock flag. It never falls back to local state or an ambient AWS credential
   chain.

## Adoption without replacement

First fill the reviewed non-secret policy rules in the Nix registry. Set each
policy's `cloudflareImportKey` to a stable logical key such as `finn-only`; the
actual UUID remains runtime-only. Regenerate `registry.json`, then import every
matching live resource using placeholders resolved during inventory:

```bash
scripts/service-publication/tofu.sh import \
  'cloudflare_zero_trust_access_policy.managed["<policy-key>"]'

scripts/service-publication/tofu.sh import \
  'cloudflare_zero_trust_access_application.managed["<application-key>"]'

scripts/service-publication/tofu.sh import \
  cloudflare_zero_trust_tunnel_cloudflared.managed

scripts/service-publication/tofu.sh import \
  cloudflare_zero_trust_tunnel_cloudflared_config.managed

scripts/service-publication/tofu.sh import \
  'cloudflare_dns_record.public["<application-key>"]'
```

The wrapper prompts without echo for each provider import ID. Supplying
`SERVICE_PUBLICATION_IMPORT_ID` from a protected operator environment is also
supported; do not put real IDs in shell scripts, committed tfvars, or runbooks.
The import subcommand overrides the hard `bootstrap_complete` variable
validation only for that non-apply operation; normal plans and applies remain
blocked until the runtime bootstrap file says `true`.

Provider import formats can change; confirm them against the pinned provider's
resource documentation immediately before use. Application-scoped Access
policies in Cloudflare provider v5 are inline on the Access application. Follow
the provider's
[v5 migration guidance](https://github.com/cloudflare/terraform-provider-cloudflare/blob/main/docs/guides/version-5-migration.md)
and never apply an intermediate plan that detaches policies.

After all imports, run `just deploy-services plan-only`. The first plan must be
no-op or an explicitly understood non-destructive delta. Any replacement is
rejected by the wrapper. Set `TF_VAR_bootstrap_complete=true` only after this
review and enable the Nix connector only after the existing and new connector
instances can overlap safely.

## Deployment and verification

`just deploy-services` is the only normal mutation flow. It regenerates and
checks artifacts, formats Nix/OpenTofu, scans for secrets, evaluates the flake,
builds focused checks, and stops on the first failure. Additions deploy and
probe the local origin before the locked OpenTofu plan is applied. Removals
withdraw Cloudflare reachability first. Mixed add/remove changes are rejected
so the ordering cannot be ambiguous.

Required runtime probe inputs are:

- `SERVICE_PUBLICATION_BLOCKY_ADDRESS` for LAN probes;
- `SERVICE_PUBLICATION_VPN_PROBE_COMMAND`, executed on a genuine VPN client and
  expected to run the generated inventory's VPN checks; and
- `SERVICE_PUBLICATION_EXTERNAL_PROBE_COMMAND` for public routes, executed
  outside Blocky/VPN. Access service-token values must be passed through that
  runner's secret environment and never printed.

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

## Rollback

Use the same registry and `just deploy-services` flow with a reviewed previous
revision. Never edit the Cloudflare dashboard as a normal rollback. If state
locking, Access, certificate readiness, or smoke verification fails, leave
Access protection intact and stop. Restore the previous origin or withdraw new
DNS/Tunnel reachability through a reviewed plan; never use local state,
`-lock=false`, `no_tls_verify`, or a legacy `home.finnrut.is` alias as a repair.
