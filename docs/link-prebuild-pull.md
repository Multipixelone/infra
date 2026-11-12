# Link prebuild, signed-cache pull, and promotion runbook

**Status — 2026-11-12: source fixes committed as `6ab6d34ab`; scoped validation
passed.** The feature remains disabled by default, not an operational cache.
Against unchanged lockfile SHA-256 `ade60923c46450fedf5ff0b1e6b41c5e80f0998baa582689041f89f0c52a87f0`,
19 helper tests, 14 status tests, targeted formatting/lint, generated-artifact
review, and synthetic configuration/workflow evaluations passed. These cover
source behavior, not the full suite or live operation. The earlier 7 November
report covered an older, changing-input snapshot and is historical; no result
from it is used to certify this revision.

This runbook is for the owner and authorized operator. The next rollout is
**cache-first, while retaining Colmena**: provision and activate Link, prove real
preparation and cold explicit-output copies, then stop. Do not enable strict
client policy, Comin, or promotion in this rollout. No provisioning, deployment,
real system build, production-ref update, or live probe is authorized by the
source/documentation work; all such evidence remains pending.

This replaces the [never-activated distributed-build design](link-distributed-builds.md).
The [decision record](ci-build-cache-decision-record.md) preserves the dated
changes and October incident. Fly cleanup remains independent; the owner reported
stopping Fly. Track **source implemented → provisioned → activated → live-tested**
separately: none follows automatically from the preceding state or a mock test.

## Architecture and trust

```text
Cache-first rollout (separately authorized, not yet demonstrated):
  verified repository-scoped native Link runner
    -> checks, then build and root actual impa/iot/marin system closures
    -> verify complete closures through private signed HTTPS cache
    -> cold copy of recorded output on impa, then iot and marin; NO activation

Deployment today: Link-side Colmena build -> SSH closure push -> target activation

Later, separate project only:
  guarded exact-SHA deploy ref -> Comin/pull adapter -> pending root -> activation
```

Only **`impa`, `iot`, and `marin`** are prebuild/pull clients. The replacement
grants them no new trusted Nix access to Link: no writable SSH store, new trusted
user, remote builder, or client SSH host-key authentication. Link does not
substitute from itself; GitHub and unrelated hosts receive no Link cache settings.
Public caches, private-input authentication, existing CI checks/status policy,
ARM advisory coverage, deployment tooling, and resource budgets remain.

**Keep Colmena today.** [`modules/configurations/nixos.nix`](../modules/configurations/nixos.nix)
sets `deployment.buildOnTarget = false` by default, passed into the hive by
[`modules/configurations/colmena.nix`](../modules/configurations/colmena.nix).
There is no target-build override in the inspected source. The established
[`Justfile`](../Justfile) recipes build on the invoking machine (Link for this
workflow) and push closures to targets over SSH. The signed cache does not replace
that deployment path, and a cache proof must not activate a client.

**Existing trust is not removed.** Forgejo on `impa` already controls the native
trusted Link runner. Its source has conflicting registration comments: global
enrollment versus a repository-scoped trust rationale. **Before any cache CI use,
not merely before promotion**, verify its actual enrollment is restricted to
`tunnel/infra`, and identify everyone who can submit trusted workflows. Stop if
scope is global, broader than intended, or unverified. Native CI is not an
untrusted-fork sandbox. Accepting Link's signing key also means trusting its
signed outputs; a signature is not independent proof of safe source or a
successful release.

Link is the owner's desktop, not an always-on cache service. That uptime tradeoff
is accepted: when it is off, new uncached updates needing Link cannot complete.
Already-running systems continue, and local store objects/public caches remain
usable; this is not a guarantee that every ordinary build succeeds during an
outage. The future explicit-copy path stops if its Link source is unavailable.

The cache is **private, not a release-only object store**. An authorized reader
can retrieve any known path in Link's store, including private sources/configs,
not just the three promoted closures. Signatures protect integrity, not
confidentiality. The source ACL and TLS are security boundaries; do not publish
this listener, widen its ACL, bypass TLS, or copy private contents into logs/docs.

## Source ownership and disabled defaults

Source ownership:

- [`modules/nix/link-cache.nix`](../modules/nix/link-cache.nix): options, signer,
  HTTPS listener, firewall/ACL, hostname mapping, and client policy. Addresses
  correspond to [`modules/hosts.nix`](../modules/hosts.nix).
- [`modules/ci/prebuild.nix`](../modules/ci/prebuild.nix) packages
  [`lib/link-prebuild.py`](../lib/link-prebuild.py) as `link-prebuild`, supplies its
  configuration, and declares the offline check. Its `prepare --ledger`,
  `promote --run`, and `prune` entry points are CI/state-management operations,
  not activation.
- [`lib/ci.nix`](../lib/ci.nix) owns the fixed host list and `deploy` branch;
  [`modules/ci/forgejo.nix`](../modules/ci/forgejo.nix) owns workflow guards;
  [`modules/ci.nix`](../modules/ci.nix) excludes deployment-ref builds on GitHub.
- [`modules/configurations/nixos.nix`](../modules/configurations/nixos.nix)
  exposes system-toplevel checks;
  [`modules/link/forgejo-runner.nix`](../modules/link/forgejo-runner.nix) owns the
  native runner and resource controls.
  [`modules/ci/tests/prebuild_test.py`](../modules/ci/tests/prebuild_test.py)
  exercises offline control flow with mock Nix and disposable bare Git.

The withdrawn distributed-build module has been removed. The committed fixes
separate strict client policy from cache enablement, gate on the helper's own
check, and pin the ACME propagation resolver. Scoped validation covered all six
hosts at disabled defaults, synthetic enabled configurations with empty/one/all
strict-client selections, rejected disabled/invalid selections, and workflow
ledger/gating checks. Generation changed only the README gate list; disabled
workflows stayed unchanged. This does not establish activated configuration,
production signing material, or live cache behavior.

Defaults and independent gates:

- **`linkCache.enable = false`**: no new cache listener/firewall rules, signing
  secret declaration, client cache policy, or generated preparation/promotion
  steps. Ordinary CI remains, including the gating `link-prebuild` check, `deploy`
  trigger exclusions, and default-branch cancellation protection.
- **`linkCache.publicKey = null`**: enabling requires a correctly shaped real public
  key and encrypted `nix-cache/link.age`. File existence is not proof of usable
  material; the service checks secret/public-key agreement at startup.
- **`linkCache.pullOnlyHosts = [ ]`**: cache enablement alone gives the three
  clients the hostname mapping, substituter, trusted key, and `require-sigs = true`
  when their configurations are activated. It leaves their local-build and
  fallback settings unchanged. Only hosts explicitly selected in this list get
  `max-jobs = 0` and `fallback = false`. Values are restricted to `impa`, `iot`, and
  `marin`; selecting a host while the cache is disabled fails that host's
  assertion. **Keep the list empty throughout the cache-first rollout.**
- Repository variable **`LINK_PREBUILD_PROMOTION` must equal `true`** for promotion.
  Keep it absent/false until the separately reviewed Comin/pull-adapter pass;
  there is no current consumer requiring a `deploy` ref. This interlock does
  **not** disable preparation once enabled workflows are published.

Publishing an enabled workflow, activating Link, and activating any client are
separate actions. Require Link readiness before publishing enabled preparation;
do not combine them into a fleet switch. Missing production prerequisites are
gates, not evidence of a broken running service.

## Endpoint and signing contract

- URL: **`https://link-cache.home.finnrut.is:5050`**.
- nginx binds only **`192.168.6.6:5050`**; nix-serve stays on
  **`127.0.0.1:5051`**, with no broad firewall opening.
- Enabled configurations give Link and the three clients a `networking.hosts`
  mapping to Link's LAN IP. The module adds no global flake `nixConfig` cache URL,
  public A record, publication registry entry, or Tunnel route.
- A dedicated DNS-01 ACME certificate uses the existing
  `/run/agenix/cloudflare-acme-dns01` credential. Propagation checks are pinned to
  **`1.1.1.1:53`**, avoiding the internal split-DNS shadow. DNS-01 needs control of
  the public challenge TXT record, **not a public A record or inbound port 80**.
  DNS authority/propagation, private credential availability, certificate-key
  handling, and successful live issuance/renewal remain unproven. A resolver
  setting is not issuance evidence; an HTTPS certificate is not permission to
  publish the cache.
- Both nginx and the early `nixos-link-cache` firewall chain restrict sources.
  The chain precedes broad `nixos-fw` accepts, including trusted `wg0`; simply
  opening TCP/5050 would not enforce this boundary. nginx ends with `deny all`.

| Reader  | Exact source IPv4 addresses          |
| ------- | ------------------------------------ |
| `impa`  | `192.168.6.50/32`                    |
| `iot`   | `192.168.8.111/32`, `192.168.5.3/32` |
| `marin` | `192.168.5.21/32`, `192.168.7.3/32`  |
| Link CI | `192.168.6.6/32`                     |

The firewall's loopback exception is restricted to `lo`, not a remotely allowed
loopback source range. Only GET/HEAD requests matching the configured
`nix-cache-info`, narinfo, and NAR protocol-path allowlist are proxied, without
response buffering. Writes, query strings, build logs, and unrelated paths are
denied. Live routes, NAT sources, TLS, protocol compatibility, and negative ACL
behavior still need evidence; never widen the allowlist to make a probe pass.

One **new signing secret** is required: encrypted `nix-cache/link.age` in the
existing private input. Its agenix name is `link-nix-cache-signing-key`, with
runtime path `/run/agenix/link-nix-cache-signing-key`, owner/group `root:root`,
mode `0400`. Keep `secretKeyFile` a runtime string, never a Nix path import or
`readFile`. The integration relies on upstream `LoadCredential` and an untrusted
DynamicUser using daemon `allowed-users`, not `trusted-users`; the validator must
confirm the locked nixpkgs module's effective unit. The new module adds a startup
public-key comparison, read-only hardening, and resource bounds. Missing/invalid
signing material must block this endpoint, not existing nginx sites globally.

No signing key is passed through CI secrets/environment; the cache service gets
**no Git/CI credentials**. This separation does not remove the native runner's
existing trusted-Nix authority over Link. On-demand narinfo signing must cover
dependencies, including paths obtained from public caches; signing only a system
toplevel is insufficient. The real public key is provisioned later, not invented
here.

## Preparation, promotion, and retained state

Existing system checks already reference actual NixOS toplevels, but a cached
system check without persistent roots is not enough. Preparation runs only after
**Report verdict** succeeds, with cache enabled, in the authoritative repository
on a default-branch push or authorized dispatch. Checkout SHA must match the
event; tracked content, submodules, and lockfile must match that SHA. The authority
is `https://git.finnrut.is/tunnel/infra.git`, default branch `main`, eventual
promotion target `refs/heads/deploy`—not the GitHub mirror.

**The controller check is a gate, not advisory.** `lib/ci.nix` includes
`link-prebuild` in `gatingCheckPatterns`. The workflow passes the status reporter's
`resolved` ledger to `prepare --ledger`. Before building any host, the helper:

1. Requires exactly one `link-prebuild` ledger row with state `success`.
2. Evaluates this checkout's `checks.<checkSystem>.link-prebuild.outPath` and
   requires the check build's output to equal that exact path. The packaged
   `checkSystem` is the package's system (`x86_64-linux` on the native Link runner).
   An already-realized or substituted successful output is valid; a success label
   for an unsupported/skipped check without its realized output is insufficient.
3. Records `checkEvidence` in the prepared manifest; promotion rejects a manifest
   without that record. Older prepared manifests are incompatible: prepare again
   through the gated workflow, never hand-edit evidence into them.

The check confirmation uses `nix build --max-jobs 0 --builders ''` with lockfile
updates forbidden. **The evidence is the exact evaluated/realized output match,
not proof that the command never built anything or freshly reran the tests.**
This is a control-flow safeguard inside the already-trusted runner, not a new
security boundary against malicious workflows.

Preparation explicitly builds all three system toplevels through Link's daemon
with no remote builders, no lockfile mutation, and stable per-host out-links,
retaining existing `NIX_CONFIG` budgets. Native builds reuse Link's store; there
is no upload step. Native builds, closure queries, and verification stream stderr
for progress while capturing stdout for parsing; explicit Git commands keep their
output captured. Nix still inherits private-input authentication and may invoke
Git internally, so streamed diagnostics are not guaranteed credential-free.
Review logs before sharing; do not add shell tracing or dump inherited credentials
to diagnose a quiet job.

Preparation records SHA, lock digest, run/attempt, Nix version, check evidence,
host output paths, and verification. It compares complete local and HTTPS
runtime-closure path sets and invokes native `nix store verify` on **the remote
HTTPS store recursively**, including NAR contents, with `--sigs-needed 1` and
only the expected trusted public key. There is no custom signature/OpenSSL
verifier. Native Nix can accept content-addressed paths by their content identity;
that is not signature proof.
Unsigned/wrong-key negative tests therefore need input-addressed objects. The
helper isolates verification configuration, clears extra keys/private signers,
enforces TLS verification, uses fresh metadata state and zero narinfo TTLs, and
bounds HTTP concurrency. A local warm-store check, a `Sig` grep, cache-info
response, or top-level signature is insufficient. Preparation/verification
failure leaves `deploy` unchanged; real signing/content verification is still a
live validation gate.

### Promotion safety, retained but not enabled

**Promotion is not a prerequisite for cache use.** Keep its interlock off for this
rollout; the following safeguards must survive the later Comin/promotion pass.
The separate job requires successful checks, a nonempty prepared run with
controller-check evidence, the same repository/ref guards, and
`LINK_PREBUILD_PROMOTION == 'true'`. Both forges exclude `deploy` from build
triggers and retain defensive job guards; lock updates remain on the default
branch. Default-branch runs are not cancelled in favor of newer runs; correctness
must not depend on FIFO scheduling or token trigger suppression.

Promotion uses the existing `FORGE_TOKEN` through temporary credentials, not an
argv token or a new CI secret, and removes checkout's competing authorization
header. Before later enabling it, **verify the token's actual actor**, which may
be the human owner, and protect `deploy`: only the intended actor may advance it,
no force/delete or human merges, and required statuses—including
`checks / link-prebuild`—must already be successfully complete for the candidate.
Do not require the promotion job's own pending status for its push. These are
branch-protection prerequisites, not a claim that the helper queries Forgejo
statuses or configures protection itself.

Under the persistent promotion lock, the helper reconciles any unresolved intent,
validates prepared state/roots, then discovers authoritative default/deploy refs.
A missing deploy ref is distinct from a network/authentication error. Candidates
must still be the default tip, and existing deploy must be their ancestor. The
push names the **exact tested SHA** with an explicit lease on the observed old
SHA (or absence); no unconditional force or API ref replacement is allowed.
Default can advance between its check and the one-ref push: the contract is
**tested, monotonically advancing deploy**, not an atomic update of two refs or
an assurance that deploy is always the newest default tip.

### Roots, retention, and disk headroom

Persistent state is outside workspace cleanup:

```text
/var/lib/forgejo-runner/link/prebuild/
  runs/<unique-run-id>/{lock,manifest.json,roots/<host>}
  promotion.lock
  promotion-intent.json
  promoted.json
```

Never move root directories/filenames after Nix registers indirect roots. Their
visibility to the daemon across the runner's DynamicUser namespace and restart
must be demonstrated, not inferred from a symlink in a CI workspace. No manifest
commit is added: changing the source revision would change the tested closure.

Intent is durably recorded **before** push; recorded promotion is finalized
**before** pruning. Lost acknowledgement/cancellation keeps intent and roots.
On recovery, remote equal to candidate permits finalization; remote equal to old
permits safe re-evaluation/retry; unexplained state stops without pruning or
overwriting. Git and local files are not one transaction. Bookkeeping can fail
after the ref advances, so a red job does not imply rollback; inspect both states.

Retention keeps the latest promoted run for each of the **three most recent
distinct SHAs**—current plus two predecessor releases—**and every promoted run
younger than 24 hours**, plus active locks and unresolved intent. Same-SHA retries
do not consume predecessor slots. Unprotected directories must also be at least
24 hours old by directory mtime before deletion; unlocked failed/unpromoted runs
can then be cleaned. The test source covers count/grace/lock/intent retention and
same-SHA retry behavior; the focused offline suite passed, without proving live
root visibility, storage capacity, or production promotion.

The workflow calls lock-aware `prune` after successful preparation even when
promotion is off; promotion also prunes after durable finalization. **Do not add a
standalone pruning timer or age-only tmpfiles cleanup.** During cache-only use,
the last good prepared run is unpromoted, so promotion history does not protect it
permanently. A later prune may remove it once it is old and unlocked; without a
later successful prepare or separately authorized maintenance, eligible runs can
remain longer. A failed prepare does not invoke the workflow's subsequent prune.
Reconfirm that the chosen run's roots still exist before scheduling client copies.

**Three releases plus 24 hours is a retention rule, not a disk budget.**
[`modules/nix/settings.nix`](../modules/nix/settings.nix) sets `keep-outputs = true`,
which can retain more than runtime closures. Existing Link GC thresholds remain
10–40 GiB; they cannot reclaim rooted data or guarantee space for the next build.
Before approving recurring preparation, measure closure sizes, actual free space,
and peak headroom during a representative three-host run, then confirm that
post-prepare pruning leaves room for another run. No such measurement is supplied.
Stop new preparation on inadequate headroom; do not evict protected releases,
move registered roots, discard current roots before replacement, or wipe the
store to make a build pass.

## Approval-gated rollout

**Stop at any failed gate.** The owner authorizes each live stage. Repository
work is not permission to provision secrets, build real systems, deploy, alter
production refs, or probe services. Keep `pullOnlyHosts = [ ]`, promotion off, and
Colmena as the deployment path throughout this rollout.

### 1. Reconcile source and verify runner enrollment

- Complete the scoped source review and current-lock validation: disabled
  defaults; enabled cache with no strict clients; one selected client; invalid
  client/disabled-cache selection; missing-prerequisite failures; no reverse
  access or unintended consumers; preserved coverage/authentication/budgets;
  ACME resolver; helper-check gating and realized evidence; focused offline tests.
  Use synthetic public material only in fixtures. Mocks do not prove TLS,
  signatures, daemon roots, or live promotion.
- Before **any cache CI use**, the owner verifies actual `tunnel/infra`-only native
  runner enrollment and trusted workflow contributors in Forgejo. Resolve the
  contradictory registration comments against live enrollment, not assumptions.
  An unknown or global registration scope is a stop condition.
- Fixer owns source wiring; Validator executes regeneration and final scoped
  checks, including documentation formatting/links. The orchestrator reviews the
  entire generated diff. `nix run .#generate-files` rewrites all `files.file`
  outputs and `flake.nix`, and pre-commit also invokes it. Stage new source files
  before Git-backed evaluation/regeneration; never hand-edit generated outputs.
  Repository review and commits do not authorize live rollout.

### 2. Provision the signing identity, then activate Link only

- With separate approval, the owner/secrets maintainer creates a real signing
  identity through the private secrets workflow, encrypts `nix-cache/link.age`
  for Link, and supplies only its public key for `linkCache.publicKey`. Review
  the private-input revision change separately. Do not print private bytes,
  track plaintext keys, or put the signer in CI secrets/environment.
- Verify the existing ACME credential, public DNS challenge authority, and
  public-resolver reachability without exposing credentials. DNS-01 does not
  require opening port 80 or publishing a public cache A record.
- Prepare reviewed `enable = true`, the real public key, and **an empty
  `pullOnlyHosts` list**. Activate **Link only** with the established single-host
  deployment procedure from the approved candidate. Leave all three client
  systems unchanged. Coordinate workflow publication: merging enabled generated
  workflow steps can start real preparation even with promotion off. Do not
  publish them before Link and the runner gates are ready and builds authorized.
- Verify runtime bindings, untrusted service user/credential handling,
  public-key agreement, valid TLS/hostname/chain, exact nginx and early-firewall
  ACLs, allowed cache protocol paths, and denied writes/query strings/log paths.
  Include unauthorized LAN and WireGuard sources. Demonstrate missing/invalid
  signer isolation under an approved failure test without disrupting unrelated
  nginx sites. Never bypass TLS or widen the ACL to make a probe pass.

### 3. Prove real three-host preparation and storage headroom

Separately authorize an enabled default-branch CI run for the approved SHA/lock.
Require completed gating checks, including `link-prebuild` and its exact realized
output evidence. The run must build/root **all three actual host toplevels**, not
only a package subset, then verify complete remote closure equality, trusted
signatures, and NAR contents. Cache-info success, a `Sig` grep, or a warm local
store is not sufficient.

Prove the indirect roots are visible to the daemon **before and after an
authorized runner restart**, outside workspace cleanup. Record measured disk
headroom for the three-host preparation and the next run, considering
`keep-outputs`; the retention count is not a capacity estimate. Inspect
lock-aware prune behavior without deleting protected roots. Keep promotion off:
this stage neither creates nor advances `deploy`.

### 4. Cold-copy one client, then all three, without activation

Start with **`impa`**. Use an approved prepared manifest's immutable SHA, lock
digest, and exact host output; no deployment ref is needed. Verify that run's
roots still exist and that the chosen output is initially absent on the client.
Do not delete current or rollback objects to manufacture a cold test.

Link-only activation does not install the client hostname mapping or signing
trust. Before a copy, separately approve and establish scoped client resolution
and trusted-key configuration using the already-installed Nix; do not activate a
new NixOS generation or select `pullOnlyHosts` merely to set up this proof. If the
operator cannot establish that prerequisite without a client activation, stop
and return the missing setup to Fixer. Verify `ip -4 route get 192.168.6.6` and the
observed source/return path to TCP/5050 against the exact ACL—not a guessed NAT
address.

Use the [explicit-output payload below](#copy-only-payload-for-an-authorized-proof).
It writes to the client's store, but must not build, switch profiles, or activate
a system. Record whole-closure availability and native signature/content evidence,
not just a successful no-op on an already-warm store. In approved disposable
negative fixtures, missing dependencies, unsigned input-addressed objects, wrong
keys, TLS failure, and unavailable Link must fail without build fallback or
activation; never damage the live cache to create a negative test.

Only after `impa` passes, repeat for **`iot`**, then **`marin`**, using each host's
recorded output and observed route. A single-host pass is not proof of all three
network paths. **Keep Colmena for actual deployments.**

### 5. Stop here

Do **not** enable strict clients, Comin, or `LINK_PREBUILD_PROMOTION` after a
successful cache proof. A later, separately authorized pass must design and test
the exact-output copy/root/activation adapter and its recovery, review Git actor
and branch protections, and only then consider per-host strict policy and
promotion. Cached objects and successful copies are not activation evidence.

For the cache-first rollout, retain the approved SHA/lock digest, real public-key
identity, runner-scope evidence, ready manifest/check output, per-host paths,
remote verification, daemon-root/restart observations, disk measurements, and
per-client route/ACL/cold-copy/negative results. Record failed gates too; review
reports for private contents. Old/candidate/observed `deploy` refs are evidence
for the later promotion pass, not a prerequisite here.

For authorized Linux Nix validation or long-running work, the background
validator follows the inherited `agent-run-long` procedure; use fresh
`direnv exec .` when a development shell is needed. For a separately approved
local system build, use the established wrapped, raw-output NH host-build form
(`--no-nom --log-format raw -L`), not raw `nix build` or `nixos-rebuild`. This does
not change the helper's explicit CI builds or authorize a target-local rebuild.
If execution/delegation is unavailable, report that limitation.

## Future client no-build contract

**A cached NixOS toplevel does not make an ordinary target-side NH rebuild a
pull-only update.** The pinned-source review supplied for this reconciliation
identifies `preferLocalBuild = true` and `allowSubstitutes = false` on the upstream
[NixOS toplevel](https://github.com/NixOS/nixpkgs/blob/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/nixos/modules/system/activation/top-level.nix).
With the output absent locally, the normal derivation build path is therefore
not a cache-copy contract. The reviewed **Nix 2.35.3** native local-build path
rejects local builds at `max-jobs = 0`; do not repeat the generic claim that
`preferLocalBuild` bypasses that limit. These are pinned-source findings, **not a
runtime NH/client proof**, nor a blanket guarantee about every Nix execution
path. Recheck the selected Nix package and upstream behavior when the lock changes.

Cache enablement alone does not set those strict job/fallback values. The optional
`pullOnlyHosts` policy applies them per host, with no distributed builders and
public caches retained. Leave it empty until the adapter below is approved and
tested. The no-build contract comes from **evaluation with IFD disabled followed
by copying an explicit output**, not from passing a flake installable to a build
command with different settings.

For a future pull/Comin adapter, the required sequence is:

1. Resolve `deploy` once to an immutable SHA and use an authenticated, clean
   checkout/lockfile for exactly it. Evaluate the selected host's system output
   with IFD disabled and lockfile updates forbidden; reject evaluation failure.
2. Require the evaluated path to match the prepared release. It must be an
   explicit `/nix/store/...-nixos-system-...` **output**, not `.drv` or a flake
   installable. Copy its complete closure from the HTTPS cache; never call a
   build/realise fallback to fill gaps.
3. Only after the entire copy succeeds, establish and verify a daemon-visible
   pending GC root. Keep the current system rooted while preparing its successor.
   Client pending-root ownership and activation are not implemented by this pass.
4. Activate only through the later approved adapter. Missing/unsigned paths,
   wrong keys, TLS failures, or unavailable Link must leave the current system
   active. Already-running services do not depend on the next cache fetch.

### Copy-only payload for an authorized proof

For rollout stage 4, use the prepared manifest's immutable SHA directly; do not
create `deploy` just to test the cache. On the approved client, prerequisites are
an authenticated clean checkout at that SHA/lock, installed Nix, verified hostname
resolution/route, the real signing public key trusted by the destination daemon,
and signature/TLS checking enabled. Use installed tools rather than loading a dev
shell that might itself build. This `impa` evaluation payload must match its
manifest entry; use the corresponding host attribute on `iot` or `marin`:

```fish
nix eval --no-update-lock-file --no-write-lock-file \
  --option allow-import-from-derivation false --raw \
  .#nixosConfigurations.impa.config.system.build.toplevel.outPath
```

After checking that result against the ready manifest, the copy-only payload is:

```fish
set toplevel /nix/store/REPLACE_WITH_VERIFIED_SYSTEM_OUTPUT
nix copy --from https://link-cache.home.finnrut.is:5050 --to daemon "$toplevel"
```

Replace the placeholder with the verified non-`.drv` system output. This copies
its closure into the target store; it does **not** create a system generation,
establish the future pending root, or activate anything. Require
`require-sigs = true` and `ssl-verify = true`. Do not use `--no-check-sigs`, disable
TLS, substitute a flake installable, or fall back to `nh`/`nix build` if it fails.
Failure may leave partially copied store objects but must not change the running
system. A successful copy into an already-warm store proves no transfer; use the
cold proof and negative cases from stage 4. No such live proof has been supplied.

## Recovery and rollback

During cache-only rollout, **leave promotion off and keep using Colmena**. Stop
new preparation/copy attempts at a failed gate; preserve current and rollback
roots. Link downtime blocks new Link-dependent uncached work, not running
services or the existence of public caches. Do not switch a target to local
rebuilds or weaken signature/TLS checks just to finish a cache proof.

If promotion was enabled in a later authorized pass, **disable it first**,
preserve the current ref, manifests, roots, and unresolved intent, and reconcile
ambiguous push outcomes before retrying. Do not manually delete intent to force
progress or prune to recover disk space. Fix the cause and use the guarded helper
only after review; a red job does not establish the remote ref. A reviewed revert
on the default branch followed by fresh preparation/forward promotion is
preferred to rewinding `deploy`. Emergency ref rewind is separate authorized
break-glass work, not a normal helper operation.

For a planned shutdown, inventory which client settings were actually activated.
If a later rollout selected strict clients, remove them from `pullOnlyHosts` and
restore their approved build/fallback policy one host at a time before disabling
the cache. Remove client endpoint/trust configuration only after pending copies
are resolved; do not strand clients at `max-jobs = 0` or remove a key still needed
for a pending closure. Preserve current and rollback roots. Endpoint shutdown
need not delete store contents or restore the withdrawn reverse-trust design.

Signer compromise requires stopping publication/promotion and revoking affected
client trust under an incident plan. Removing a key does not repair a compromised
Link or prove previously signed outputs safe. Keep Fly retired throughout;
rollback does not restore dead Fly consumers or authorize provider/credential
deletion.
