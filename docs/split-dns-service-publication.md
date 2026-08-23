# Split DNS and service publication design

Status: accepted design; implementation has not started

This document is the implementation contract for publishing services from the
New York City site. It records the accepted target state, the decisions it
supersedes, and the facts that must still be discovered during bootstrap. It is
not a deployment report: none of the target registry, OpenTofu state, generated
Cloudflare resources, DNS cutovers, or ingress migrations described here should
be assumed to exist yet.

The words **must**, **must not**, **should**, and **may** are normative for the
eventual implementation. Examples are illustrative and deliberately non-final.
In particular, example applications do not authorize making Grafana, Homepage,
or any other service public.

## Goals and boundaries

The design has four goals:

1. Give every site, host, application, and route an explicit identity instead
   of deriving service behavior from the machine where it happens to run.
2. Give LAN and VPN clients the shortest trusted path while giving external
   clients a Cloudflare Tunnel and Access path only when publication is
   explicitly enabled.
3. Generate nginx, Blocky, certificates, probes, and Cloudflare infrastructure
   from one validated Nix registry.
4. Make publication fail closed: a partial deployment may leave an application
   private or unavailable, but must never leave it unexpectedly public or
   public without Access protection.

The first implementation is scoped to the NYC site and IPv4 LAN routing. The
model must not bake in NYC, Link, one subnet, observability, or NixOS-only
backends, so later sites and applications can use the same abstractions.

This is design documentation only. Exact resource identifiers, commands that
depend on those identifiers, final health endpoints, and the final Nix option
shape remain implementation/bootstrap work where explicitly marked below.
Authorization is limited to reviewing and grilling this design; implementation
requires separate later work.

## Current repository state

The following are observed starting facts, not the target architecture:

- `modules/observability/registry.nix` is a Link-only Phase 1 endpoint registry.
  It has no site/host/application/route hierarchy or per-application public
  setting. Its private endpoints implicitly map to Link.
- `modules/link/observability.nix` hardcodes Link's nginx virtual hosts, SAN
  certificate, backend bindings, probes, and the `home.finnrut.is` names.
- `modules/network/pihole.nix` derives Blocky records from that same endpoint
  registry and maps all private names to Link's address.
- `modules/network/cloudflared.nix` starts cloudflared with a per-host tunnel
  token. Link and IoT import this module, and their ingress is managed in the
  Cloudflare dashboard rather than from this repository.
- The ACME DNS-01 token is a separate agenix secret from the cloudflared tunnel
  token. That separation is correct and must be retained.
- There is no OpenTofu configuration, remote state backend, or state bootstrap
  in this repository today.
- Phase 1 assertions explicitly forbid public DNS and Tunnel exposure. Those
  assertions protect the current design, but conflict with opt-in publication
  and therefore must be deliberately replaced, never silently weakened.

The Phase 1 documentation and assertions remain historical truth until the new
design is implemented. They are not evidence that this design has been rolled
out.

## Accepted domain model

The registry hierarchy is explicit:

```text
site
└── host
    └── application identity
        └── route(s)
```

The hierarchy expresses ownership and validation, not forced co-location. An
application belongs to a site but is independent of a host. Each route selects
its backend and proxy separately, so moving either does not rename the
application.

### Site

A site owns:

- a stable key, initially `nyc`;
- the internal zone, initially `nyc.finnrut.is`;
- every routed LAN CIDR at the site;
- the hosts present at the site; and
- one movable `publicIngressHost` role, initially assigned to `link`.

The routed LAN CIDRs are the networks VPN clients receive as routes. They are
also the source networks used by firewall and proxy policy where appropriate.
The final CIDR list must be discovered and validated before rollout; the three
Phase 1 trusted networks must not be copied blindly into the new schema.

### Host

A host has an explicit site, addresses, management status, and capabilities.
Capabilities include at least reverse proxy, public connector, Blocky/DNS, and
whether the host can receive NixOS-generated configuration. A host used as a
backend must have an address reachable by its selected proxy. A proxy or
connector role must only be assigned to a host declaring the corresponding
capability.

Administrative host names are internal-only and use:

```text
<host>.hosts.nyc.finnrut.is
```

For example, `link.hosts.nyc.finnrut.is` identifies the machine, not an
application served by Link. These names resolve to the host's LAN address and
are not application aliases or public records.

### Application

An application key is its durable identity. It owns naming, publication, Access
policy defaults, and one or more routes. Moving an application backend or proxy
must not change its canonical name.

For a private-only application (`public = false`), the canonical name is:

```text
<app>.nyc.finnrut.is
```

For a public application (`public = true`), the canonical name defaults to:

```text
<app>.apps.finnrut.is
```

An optional full `publicHostname` replaces that default and supports names such
as `git.finnrut.is` and `files.finnrut.is`. It is a full hostname, not a label
or suffix. Supplying `publicHostname` when `public = false` is invalid.

A public application's NYC name remains internal-only and redirects to the
public canonical name. Thus `git.nyc.finnrut.is` may redirect to
`git.finnrut.is`; it is not a second first-class URL, and it receives no public
DNS record. A private-only application's NYC name is canonical and serves the
application rather than redirecting.

There are no `*.home.finnrut.is` compatibility aliases. Those records, vhosts,
certificate SANs, and client references are removed during migration.

### Route

A route is the unit of traffic forwarding and health verification. It has:

- a unique match, normally a host plus path prefix;
- a backend host, scheme, and port;
- an optional explicit proxy host;
- inherited whole-application publication settings plus narrowly scoped
  advanced per-path overrides; and
- a mandatory health check with path, expected status, and timeouts.

`backend.host` and `backend.port` describe where the application listens.
`proxy.host` describes where TLS terminates and nginx routes the request. The
proxy host defaults to the backend host when that host is proxy-capable. For a
backend that cannot run the generated proxy, such as the Synology/non-NixOS
host, the resolver selects an explicitly capable fallback host at the same
site. The selected fallback must be deterministic and visible in evaluated
output; ambiguity is an evaluation error. An explicit `proxy.host` overrides
the default but is still capability- and reachability-checked.

Whole-application publication is the default. `public = true` publishes every
route unless an advanced route override narrows exposure for a particular path.
`public = false` means no route may opt itself into public exposure. This keeps
the common case auditable and prevents a hidden path override from publishing a
nominally private application. Advanced per-path rules may make paths of a
public application internal-only, select a stricter Access policy, or declare a
justified Access bypass. Overlapping or contradictory path rules are invalid.

## Illustrative Nix schema

The following shape demonstrates required concepts and inheritance. It is not a
final option declaration and must not be copied without completing discovery,
types, assertions, and naming review.

```nix
servicePublication = {
  sites.nyc = {
    internalZone = "nyc.finnrut.is";
    routedLanCidrs = [ "<discover-before-rollout>" ];
    publicIngressHost = "link";
    defaultProxyHosts = [ "link" ];
  };

  hosts = {
    link = {
      site = "nyc";
      addresses.lan = "192.0.2.10"; # Documentation address only.
      managedByNixOS = true;
      capabilities = {
        reverseProxy = true;
        publicConnector = true;
        internalDns = true;
      };
    };

    alexandria = {
      site = "nyc";
      addresses.lan = "192.0.2.20"; # Documentation address only.
      managedByNixOS = false;
      capabilities.reverseProxy = false;
    };
  };

  accessPolicies = {
    finn-only = { cloudflareImportKey = "<discover>"; };
    family = { cloudflareImportKey = "<discover>"; };
  };

  applications.files = {
    site = "nyc";
    public = true;
    publicHostname = "files.finnrut.is";
    access = {
      policy = "finn-only";
      serviceTokens = [ ];
      bypassAccess = false;
      bypassJustification = null;
    };

    routes.root = {
      match.pathPrefix = "/";
      backend = {
        host = "alexandria";
        scheme = "http";
        port = 5000;
      };
      # Null means alexandria when capable, otherwise the site's one
      # deterministic capable fallback (link in this illustration).
      proxy.host = null;
      public = null; # Inherit the application's true value.
      health = {
        path = "/health";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 5;
      };
    };

    routes.admin = {
      match.pathPrefix = "/admin/";
      backend = {
        host = "alexandria";
        scheme = "http";
        port = 5000;
      };
      proxy.host = "link";
      public = false; # Advanced narrowing of a public application.
      health = {
        path = "/admin/health";
        expectedStatuses = [ 200 204 ];
        timeoutSeconds = 5;
      };
    };
  };
};
```

An implementation may split site, host, application, and generated projections
across modules. It must preserve this semantic model and stable resource keys.
Application and route keys, rather than list indexes or hostnames, should key
generated OpenTofu resources so moves do not cause accidental destroy/create
operations.

## Name and route resolution

“Internal DNS” means Blocky reached from either a NYC LAN or a VPN client.
VPN clients route the full NYC LAN subnets, so both contexts receive the proxy
host's LAN address. A WireGuard address is not returned merely because the
querying client is on VPN.

| Application and client context           | Queried name                                   | DNS answer                                  | HTTP/TLS path                                                              | Access behavior                              |
| ---------------------------------------- | ---------------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------- |
| Private app, NYC LAN                     | `app.nyc.finnrut.is`                           | Selected proxy's LAN IP                     | Client -> proxy nginx -> backend                                           | No Cloudflare Access                         |
| Private app, VPN                         | `app.nyc.finnrut.is`                           | Same proxy LAN IP as LAN                    | VPN routes NYC LAN -> proxy nginx -> backend                               | No Cloudflare Access                         |
| Private app, external DNS                | `app.nyc.finnrut.is`                           | No public record                            | No route                                                                   | Unreachable externally                       |
| Public app, NYC LAN                      | canonical `app.apps.finnrut.is` or custom name | Blocky shadows public DNS with proxy LAN IP | Client -> proxy nginx -> backend                                           | Bypasses Tunnel and Access by being internal |
| Public app, VPN                          | canonical public name                          | Same proxy LAN IP as LAN                    | VPN routes NYC LAN -> proxy nginx -> backend                               | Bypasses Tunnel and Access by being internal |
| Public app, LAN/VPN alias                | `app.nyc.finnrut.is`                           | Proxy LAN IP                                | Alias vhost redirects to canonical public name, which resolves internally  | Redirect only; no second application URL     |
| Public app, external browser             | canonical public name                          | Cloudflare-managed public record only       | Cloudflare -> Tunnel connector -> selected proxy HTTPS over LAN -> backend | Access challenge, then selected policy       |
| Public app, external machine             | canonical public name                          | Cloudflare-managed public record only       | Same Tunnel path                                                           | Access service token preferred               |
| Public app, external query for NYC alias | `app.nyc.finnrut.is`                           | No public record                            | No route                                                                   | Unreachable externally                       |
| Host administration, LAN/VPN             | `host.hosts.nyc.finnrut.is`                    | That host's LAN IP                          | Direct host administration path                                            | Internal controls, never app publication     |
| Host administration, external            | `host.hosts.nyc.finnrut.is`                    | No public record                            | No route                                                                   | Unreachable externally                       |

Blocky therefore owns two kinds of internal mapping:

- private canonical and host-administration names under `nyc.finnrut.is`; and
- shadows of canonical public application names.

Cloudflare DNS owns only the canonical hostname of an application with
`public = true` and at least one effective public route. A private application
has no externally resolvable record. An internal-only path override on an
otherwise public application does not change DNS; Tunnel/nginx routing must
reject that path externally while the hostname remains public. Public resolvers
must never be used as a fallback for an internal name.

## Data-plane architecture

### Internal traffic

LAN and VPN requests terminate HTTPS on the selected proxy host. nginx then
forwards directly to the declared backend host and port. Co-located backends may
remain loopback-only; remote backends must bind an address reachable from their
proxy and restrict that port to the required proxy source addresses.

The generated firewall, nginx ACL, Blocky mapping, probe targets, and VPN route
expectations must derive from the same site and route data. They must not each
carry independent copies of CIDRs or addresses.

### Public traffic

There is one central, movable Cloudflare connector role. Link holds that role
initially, but “Link” must not be encoded into public resource identity or
Tunnel ingress configuration.

For each public route, Cloudflare sends traffic through the central connector
directly to the selected proxy host's HTTPS listener over the LAN. The connector
does not pass traffic through a central nginx re-proxy. In particular, when the
connector and selected proxy are different hosts, the path is:

```text
external client
  -> Cloudflare DNS / Access / Tunnel
  -> movable cloudflared connector
  -> https://<selected-proxy-LAN-IP> with canonical SNI
  -> route backend.host:backend.port
```

The connector must validate the proxy's origin certificate and use the
canonical hostname for SNI/Host routing. Disabling origin TLS verification is
not an accepted shortcut.

For a public application with an internal-only path override, generated Tunnel
and proxy rules must omit or deny that path and end in a fail-closed catch-all.
DNS remains a hostname-level resource and cannot enforce path exposure.

### TLS and certificates

nginx and NixOS `security.acme` DNS-01 issuance remain the origin TLS mechanism.
Each proxy host gets its own certificate whose SAN set is generated from only
the canonical and redirect names served by that proxy. Private keys are not
shared between proxy hosts, and there is no shared private wildcard key.

DNS-01 allows certificates for internal names without publishing address
records. The ACME credential remains separate from both tunnel runtime
credentials and the OpenTofu Cloudflare API credential. All credentials are
read from agenix runtime paths and never enter the Nix store, generated OpenTofu
inputs, logs, or committed files.

## Access policy

Every public application gets a Cloudflare Access application. Its default
binding is the existing imported Finn-only policy. An application may explicitly
select the imported family policy instead. A route may select a stricter valid
policy as an advanced override, but a public route without a resolvable policy
is rejected.

Non-interactive callers should use Cloudflare Access service tokens. Service
token identifiers may be declared, but secrets must remain in agenix or the
appropriate secret system and outside generated plans/state wherever the
provider permits. `bypassAccess` is exceptional and requires a non-empty,
reviewable `bypassJustification`. A bypass still belongs to an explicitly
managed Access application/policy ordering; it must not be represented by
omitting Access resources. Validation rejects an unjustified bypass.

Policy precedence must be generated deterministically so an internal-only path,
a service-token path, or a justified bypass cannot accidentally widen adjacent
paths. The default catch-all Access policy remains last and protective.

## Control-plane ownership

Nix is the source registry and generates all derived local configuration plus
machine-readable OpenTofu inputs. OpenTofu owns Cloudflare resources after
bootstrap.

| Concern                                           | Authority after bootstrap             | Notes                                               |
| ------------------------------------------------- | ------------------------------------- | --------------------------------------------------- |
| Sites, hosts, applications, routes, health checks | Nix registry                          | Single accepted source of intent                    |
| nginx vhosts/routes and host firewalls            | Nix/NixOS                             | Generated on each capable proxy host                |
| Blocky internal records/shadows                   | Nix/NixOS                             | Generated from effective proxy selection            |
| Origin ACME certificates                          | NixOS `security.acme`                 | Per-proxy-host SAN certificate                      |
| Public DNS records                                | OpenTofu                              | Only applications with `public = true`              |
| Tunnel ingress                                    | OpenTofu                              | Connector forwards to selected HTTPS proxy directly |
| Access apps and policy bindings                   | OpenTofu                              | Default Finn-only; optional family/advanced policy  |
| Cloudflare dashboard edits                        | Neither                               | Emergency observation only; edits are drift         |
| OpenTofu state                                    | Encrypted remote backend with locking | Never committed or stored unencrypted               |

The Nix evaluation should emit a deterministic, non-secret JSON or `.tf.json`
artifact containing site, route, DNS, Tunnel, Access, and origin selections. A
small reviewed OpenTofu module consumes that artifact or generated resources.
The exact file boundary is an implementation detail, but hand-maintained copies
of the registry in HCL are not acceptable.

Cloudflare resource dependencies must enforce fail-closed ordering: a public
DNS/ingress route depends on its Access application and bindings. Destruction
uses the reverse dependency order, removing reachability before removing Access
protection. Stable keys and lifecycle review must make replacement behavior
visible in plans.

After import/bootstrap, repository intent plus OpenTofu state is authoritative.
Dashboard edits are drift and must be reverted through the repository. Import
or adoption is required for matching existing DNS, Tunnel, Access application,
and policy resources; the first apply must not create duplicates.

## OpenTofu execution and state

OpenTofu initially runs from Link. It uses a new, separately scoped Cloudflare
API credential delivered through agenix. It must not reuse a cloudflared tunnel
token or the ACME DNS credential. Scope the token only to the zone/account
resources the generated configuration manages, and document the final scopes
after provider requirements are verified.

State is encrypted at rest in a remote S3-compatible backend with locking.
Whether Cloudflare R2 is suitable remains undecided until its locking semantics
with the selected OpenTofu backend are demonstrated. Use R2 only if locking is
sufficient; otherwise use an S3 service that provides the required lock
behavior. Backend bootstrap credentials are secrets and stay in agenix/runtime
configuration.

The repository must add OpenTofu-aware ignore rules, formatting, and checks when
implementation begins. At minimum, ignore state, state backups, crash logs,
plans, local backend metadata, override files, and provider/plugin working
directories. Commit only reviewed configuration and lock files as appropriate;
never commit state, plan files containing sensitive values, backend credentials,
API tokens, tunnel tokens, or rendered secret inputs. Add `tofu fmt -check` and
`tofu validate` to the applicable treefmt/flake/CI path, and retain existing
treefmt and gitleaks checks.

## Validation and assertions

Validation happens during Nix evaluation before any host or Cloudflare mutation.
Errors should name the site/application/route and conflicting value. The final
module must reject at least:

- duplicate site, host, application, route, canonical, alias, or admin names;
- hostname and path collisions, including overlapping path exposure rules whose
  precedence is ambiguous;
- `publicHostname` when `public = false`;
- a private application with a route override that attempts public exposure;
- a public application with no effective public route;
- `bypassAccess = true` without a non-empty justification;
- a public application or effective public route without a known Access policy;
- a route without a health check, valid expected statuses, or usable path;
- an unknown/missing site or host, a host without its site LAN address, or a
  cross-site backend/proxy relationship not explicitly supported;
- a selected proxy lacking reverse-proxy capability;
- a `publicIngressHost` lacking connector capability or belonging to another
  site;
- a non-NixOS backend being selected as the proxy without proxy capability;
- zero or multiple implicit fallback proxy hosts;
- an unreachable backend/proxy address relationship;
- a public route whose connector origin lacks an HTTPS vhost and matching SAN;
- invalid path-exposure combinations, including a public child below an
  internal-only parent or a bypass that shadows broader protected paths; and
- generation of any Cloudflare DNS/Tunnel route without its Access dependency.

Cross-projection assertions must also prove:

1. Every Blocky application answer equals the effective proxy host's LAN IP.
2. LAN and VPN views produce the same answer for a given application name.
3. Every public canonical has one internal shadow, one external DNS intent, one
   Tunnel ingress rule, and one Access application/binding set.
4. Every private canonical and NYC redirect alias has no external DNS intent.
5. Every nginx vhost name appears on that proxy host's SAN certificate.
6. Every Tunnel origin is HTTPS on the selected proxy, never a central nginx
   hop introduced by the connector host.
7. Each route produces internal probing, and each public route also produces
   external Access-aware probing.
8. No `home.finnrut.is` name remains in the target registry, generated config,
   certificates, or verification inventory.

The current Phase 1 `!enablePublicDns && !enableTunnel` assertions must be
removed only in the same reviewed change that introduces the new opt-in
assertions above. Until then, they remain active safeguards.

## One deployment flow

The user-facing operation is one `just deploy-services` flow. It must stop at
the first failed stage and report the whole deployment unsuccessful unless all
stages pass:

1. Evaluate the flake and registry; run schema assertions, collision checks,
   generated-artifact checks, treefmt, OpenTofu formatting/validation, gitleaks,
   and relevant flake checks.
2. Build and deploy Nix/Colmena changes for proxy hosts, certificates,
   firewalls, health probes, and Blocky DNS. Follow repository conventions:
   generated `flake.nix` is never edited, input changes are regenerated with
   `nix run .#write-flake` (or `nix run .#generate-files`), and remote NixOS
   application uses Colmena/`just` rather than bare `nix build` or
   `nixos-rebuild`.
3. Re-evaluate or verify the exact artifact used for OpenTofu, acquire the
   remote state lock, show a reviewable plan, and apply Cloudflare changes.
4. Run internal and external smoke tests for every affected route.
5. Mark success only when all required checks pass and record enough non-secret
   detail to identify the registry revision, plan/apply result, and probes.

For a new public route, local proxy/TLS/DNS readiness precedes Cloudflare
publication. Within OpenTofu, Access exists and binds before external DNS and
Tunnel ingress become reachable. Removal reverses this: external reachability
is withdrawn before Access protection is destroyed, then local configuration
may be removed. Moves use an overlap/cutover sequence described below.

The flow should support a plan-only mode and an affected-route filter for
diagnostics, but those do not redefine success or bypass validations. Exact
commands, locking flags, and add/remove transaction mechanics remain to be
settled after provider/backend discovery.

## Rollout and migration

### 0. Discovery and inventory

- Confirm NYC LAN CIDRs, VPN route distribution, every host LAN address, proxy
  capability, backend reachability, and initial application inventory.
- Inventory existing public DNS, tunnel ingress, connector tokens, Access apps,
  policy bindings, and any machine callers.
- Choose health endpoints/statuses and initial publication/policy selection per
  application. Examples in this document make no publication decision.
- Determine state backend locking and final credential scopes.

No resource is imported, modified, or deleted during inventory.

### 1. Registry and local generation

- Add typed site, host, application, and route options with the assertions in
  this document.
- Generate evaluated route inventory, nginx, Blocky, ACME SANs, firewall rules,
  probes, and OpenTofu inputs.
- Establish full NYC LAN routing over VPN and verify that VPN clients can reach
  proxy LAN addresses before changing their DNS answers.
- Replace the Link-only Phase 1 public-ingress prohibition deliberately with
  opt-in fail-closed assertions.
- Run old and new local generation in comparison where possible, but do not
  publish new records during parity testing.

### 2. OpenTofu bootstrap and adoption

- Create the encrypted remote state bucket/backend and prove state locking.
- Create the separately scoped Cloudflare API credential and deploy it to Link
  with agenix.
- Import the existing Tunnel, Finn-only policy, family policy, matching Access
  applications/bindings, and DNS records that are safe to adopt.
- Establish stable resource addresses and reconcile the first plan to no-op or
  an explicitly reviewed delta. Never apply a surprise replacement.
- Add ignore, formatting, validation, flake/CI, and gitleaks coverage before any
  stateful apply.

The exact account, zone, Tunnel and policy identifiers and import commands are
bootstrap outputs, not values guessed in this document.

### 3. Internal naming cutover

- Deploy per-proxy certificates and nginx vhosts for the new canonical names.
- Publish Blocky private canonicals, public-canonical shadows, NYC redirect
  aliases for public apps, and host administration records.
- Verify LAN and VPN resolution, TLS, redirects, response, and route health.
- Update known clients/bookmarks and then remove every `home.finnrut.is` record,
  SAN, vhost, and reference. Do not retain or create old-name aliases.

### 4. First opt-in public application

- Select an application and policy only after inventory review; do not infer
  that Grafana is the pilot.
- Deploy its local origin first, then plan/apply its imported/default Access
  policy, Tunnel route, and external DNS through the one deployment flow.
- Verify from a genuinely external resolver and client, including Access
  challenge and service-token behavior where declared.
- Expand application by application only after drift and rollback exercises.

### 5. Connector migration

To move the `publicIngressHost` role:

1. Prepare the target host, credentials, firewall path, and route to every
   selected HTTPS proxy.
2. Start a new connector instance for the existing managed Tunnel while the old
   connector remains healthy.
3. Confirm both connector instances are registered and exercise routes through
   the new instance without changing origin identity.
4. Switch the registry role and normal traffic, then run all internal/external
   smoke tests.
5. Retire the old connector only after the new connector and routes remain
   healthy for the agreed observation interval.

There is no central nginx move in this procedure because the connector always
forwards directly to each selected proxy.

## Failure and rollback behavior

Fail closed is an invariant, not merely pipeline ordering.

- **Evaluation or validation failure:** make no deployment or OpenTofu change.
- **Nix/Colmena failure:** do not run OpenTofu. Existing public state remains
  Access-protected; a new application remains unpublished.
- **Certificate or proxy readiness failure:** do not create external DNS or
  Tunnel ingress for the affected route. Keep the last valid origin active when
  possible.
- **OpenTofu plan/apply failure:** mark the flow failed and run smoke tests only
  as diagnostics. Dependency ordering may leave the new app private or produce
  a protected error, but must never expose an unprotected origin.
- **Smoke-test failure:** mark the flow failed even if Nix and OpenTofu applied.
  Freeze unrelated changes, retain Access protection, and choose the smallest
  reviewed rollback: restore the previous route target, withdraw new external
  reachability, or redeploy the previous registry revision.
- **Removal interrupted midway:** a stale removed route may remain
  Access-protected or return an error until reconciliation. It must not become
  an unprotected public route. The next plan reconciles it from authoritative
  state.
- **Connector migration failure:** keep or restore the old connector; never
  retire it until the new connector passes verification.
- **Access or Cloudflare outage:** external service may fail. Internal canonical
  resolution and direct proxy paths remain independent and should continue.
- **Blocky failure:** internal resolution fails closed; clients must not fall
  through to public DNS for private names. Repair/roll back Blocky rather than
  weakening split DNS.
- **State lock/backend failure:** do not apply. Never fall back to unencrypted
  local state or `-lock=false` as a deployment workaround.
- **Drift detected:** stop the apply, identify/import or revert the dashboard
  change, and produce a reviewed plan. Do not normalize emergency dashboard
  edits by ignoring them.

Rollback uses the same `just deploy-services` stages and validation as forward
rollout. There is no ad hoc dashboard rollback. Exact recovery runbooks for
add/remove/move operations remain a discovery item and must be tested before
broad publication.

## Verification contract

Every route has a declared health check. The deployment flow generates checks
from the effective route rather than relying on a hand-maintained list.

For every route, verify from both a NYC LAN client and a VPN client:

1. The private canonical, public canonical shadow, or NYC redirect alias (as
   applicable) resolves to the selected proxy host's LAN IP.
2. The VPN answer exactly matches the LAN answer and the proxy LAN address is
   reachable through the routed NYC subnet.
3. TLS validates for the requested hostname and the certificate comes from the
   selected proxy host's per-host SAN set.
4. The health path returns one of its declared statuses within its timeout.
5. A public application's NYC alias redirects to the canonical public hostname;
   a private canonical does not redirect merely to invent a public URL.

For every effective public route, additionally verify from outside Blocky/VPN:

1. Public DNS exists and resolves through Cloudflare.
2. An unauthenticated browser request receives the expected Access challenge,
   not the origin response.
3. A declared machine caller succeeds with its Access service token.
4. After authentication, the response and health behavior reach the selected
   proxy/backend through Tunnel.
5. Origin and response checks do not reveal an alternate unprotected hostname
   or address.

For every private-only application, verify from an external resolver that no
public DNS record exists. For an internal-only path of a public application,
verify that external requests receive the configured Access-protected denial or
error and never reach the backend. Also verify that `*.home.finnrut.is` returns
no intentional legacy record after cutover.

Illustrative commands (hostnames, resolvers, status codes, and endpoints must be
filled from evaluated inventory) include:

```bash
dig @<blocky-lan-ip> +short <canonical-name>
dig @<external-resolver> +short <canonical-name>
curl --fail --show-error --resolve <name>:443:<proxy-lan-ip> https://<name>/<health-path>
curl --head --show-error https://<public-canonical>/<health-path>
curl --fail --show-error \
  --header 'CF-Access-Client-Id: <runtime-value>' \
  --header 'CF-Access-Client-Secret: <runtime-value>' \
  https://<public-canonical>/<health-path>
```

Commands must consume service-token values at runtime without echoing them,
putting them in the Nix store, or persisting them in logs. Automated output
should redact secret-bearing headers.

## Explicitly superseded decisions

| Superseded design                                               | Accepted replacement                                                           |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| No public DNS for any service                                   | Opt-in publication with `public = true`; private remains the default           |
| `home.finnrut.is` for every service                             | NYC private canonicals plus `apps.finnrut.is`/full custom public canonicals    |
| LAN clients receive LAN IP and VPN clients receive WireGuard IP | Both internal contexts receive the proxy host's LAN IP over routed NYC subnets |
| Two first-class private/public URLs                             | One public canonical for a public app plus an internal NYC redirect alias      |
| Keep `home.finnrut.is` aliases                                  | Remove the zone's service names without aliases                                |
| Link-specific public ingress                                    | A movable connector role, assigned to Link initially                           |

These replacements are final design decisions. Reintroducing a superseded
behavior requires a new design review rather than an implementation shortcut.

## Still to discover or bootstrap

The following are intentionally unresolved and must not be presented as
accepted facts in implementation changes:

- S3 versus R2, after verifying that the chosen backend has sufficient locking;
- Cloudflare account, zone, Tunnel, policy, Access application, and record IDs,
  plus the exact safe import commands;
- which existing records can be safely imported, replaced, or deleted;
- the health endpoint, accepted statuses, timeouts, and authentication behavior
  for each route;
- the exact routed NYC LAN CIDRs and complete proxy-capable host set;
- precise transaction and recovery mechanics for adding, removing, and moving
  applications/routes;
- which applications are initially public and whether each uses Finn-only,
  family, service-token, or an exceptional justified bypass policy; and
- the observation interval and test mechanism for retiring an old connector.

Discovery fills these values under the constraints above; it does not reopen
the accepted naming, split-DNS, direct-origin, Access, credential separation,
ownership, or fail-closed decisions.
