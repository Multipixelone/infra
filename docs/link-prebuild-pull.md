# Link prebuild, signed-cache pull, and promotion runbook

**Status — 2026-11-07:** The cache, preparation/promotion helper, workflow wiring,
and offline tests are implemented in source. Generated artifacts were reviewed;
17 helper tests, 13 status tests, and 97 scoped configuration/workflow predicates
passed, along with source formatting and lint checks. The Nix snapshots span
concurrent, unrelated CommuteCompass input/configuration edits; they are not a
single frozen-input validation and do not certify the latest whole tree. **The feature is disabled by default, not an
operational cache or deployment pipeline.** Signing-key provisioning, real system
builds, deployment, production-ref changes, and live probes require separate
authorization and have not been performed. Offline mocks and configuration
inspection do not establish live cache, signature, or promotion success.

This replaces the [never-activated distributed-build design](link-distributed-builds.md).
The [decision record](ci-build-cache-decision-record.md) preserves the dated
changes and October incident. Comin activation remains a later project. Fly
cleanup remains independent; the owner reported stopping Fly.

## Architecture and trust

```text
Forgejo checks on native Link runner
  -> build and root actual impa/iot/marin system closures in Link's /nix/store
  -> verify complete closures through private signed HTTPS cache
  -> guarded promotion of the exact tested SHA to refs/heads/deploy
  -> later: client resolves that SHA, copies complete closure, roots, activates
```

Only **`impa`, `iot`, and `marin`** are prebuild/pull clients. The replacement
grants no trusted Nix access to Link: no writable SSH store, new trusted user,
remote builder, or client SSH host-key authentication. Link does not substitute
from itself; GitHub and unrelated hosts receive no Link cache settings. Public
caches, private-input authentication, CI checks/status policy, ARM advisory
coverage, deployment tooling, and resource budgets must remain intact.

**Existing trust is not removed.** Forgejo on `impa` already controls the native
trusted Link runner. Its source still has conflicting registration comments:
global enrollment versus a repository-scoped trust rationale. Before enabling
promotion, the owner must verify actual repository-only enrollment and who can
submit trusted workflows. Native CI is not an untrusted-fork sandbox. Accepting
Link's signing key also means trusting its signed outputs on clients; a signature
is not independent proof of safe source or a successful release.

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
  configuration, and declares the offline check. Its `prepare`, `promote --run`,
  and `prune` entry points are CI/state-management operations, not activation.
- [`lib/ci.nix`](../lib/ci.nix) owns the fixed host list and `deploy` branch;
  [`modules/ci/forgejo.nix`](../modules/ci/forgejo.nix) owns workflow guards;
  [`modules/ci.nix`](../modules/ci.nix) excludes deployment-ref builds on GitHub.
- [`modules/configurations/nixos.nix`](../modules/configurations/nixos.nix)
  exposes system-toplevel checks;
  [`modules/link/forgejo-runner.nix`](../modules/link/forgejo-runner.nix) owns the
  native runner and resource controls.
  [`modules/ci/tests/prebuild_test.py`](../modules/ci/tests/prebuild_test.py)
  exercises offline control flow with mock Nix and disposable bare Git.

The withdrawn distributed-build module has been removed. Retention now counts
distinct release SHAs, with a same-SHA retry regression test; the workflow runs
lock-aware pruning after successful preparation. These are source observations,
not test results. The validator still needs to check evaluated configuration,
generated outputs, formatting/links, and focused tests after artifact review.

The module defaults to **`linkCache.enable = false`** and
**`linkCache.publicKey = null`**. Disabled means no new cache listener/firewall
rules, signing-secret declaration, client cache/job policy, or generated
preparation/promotion steps. Ordinary CI retains its checks, authentication, and
resource budgets; `deploy` trigger exclusions and default-branch cancellation
protection remain. Enabling asserts a correctly shaped public key and the
presence of encrypted `nix-cache/link.age`; credential/public-key agreement is a
separate startup check, not proven by file existence.

Promotion has another interlock: repository variable **`LINK_PREBUILD_PROMOTION`
must equal `true`**; absent/false leaves promotion off. This does **not** disable
preparation once enabled workflows are published. Coordinate source enablement,
workflow publication, and the Link-only activation gate below.

Track these states separately: **source implemented → provisioned → activated →
live-tested**. None follows automatically from the preceding one or from a green
mock test. Missing production prerequisites are gates, not evidence of a broken
running service.

## Endpoint and signing contract

- URL: **`https://link-cache.home.finnrut.is:5050`**.
- nginx binds only **`192.168.6.6:5050`**; nix-serve stays on
  **`127.0.0.1:5051`**, with no broad firewall opening.
- Link and the three clients get a `networking.hosts` mapping to Link's LAN IP.
  There is no global flake `nixConfig` cache URL, public DNS record, publication
  registry entry, or Tunnel route. A dedicated DNS-01 ACME certificate uses the
  existing ACME credential; an HTTPS certificate is not permission to publish.
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
check without persistent roots is not enough. Preparation runs only after the
existing **Report verdict** succeeds, with cache enabled, in the authoritative
repository on a default-branch push or authorized dispatch. Checkout SHA must
match the event; tracked content, submodules, and lockfile must match that SHA.
The configured authority is `https://git.finnrut.is/tunnel/infra.git`, default
branch `main`, promotion target `refs/heads/deploy`—not the GitHub mirror.
It explicitly builds all three toplevels through Link's daemon with no remote
builders, no lockfile mutation, and stable per-host out-links, retaining existing
`NIX_CONFIG` budgets. Native builds reuse Link's store; there is no upload step.

Preparation records SHA, lock digest, run/attempt, Nix version, host output paths,
and verification. It compares complete local and HTTPS runtime-closure path sets
and invokes native `nix store verify` on **the remote HTTPS store recursively**,
including NAR contents, with `--sigs-needed 1` and only the expected trusted public
key. There is no custom signature/OpenSSL verifier. Native Nix can accept
content-addressed paths by their content identity; that is not signature proof.
Unsigned/wrong-key negative tests therefore need input-addressed objects. The
helper isolates verification configuration, clears extra keys/private signers,
enforces TLS verification, uses fresh metadata state and zero narinfo TTLs, and
bounds HTTP concurrency. A local warm-store check, a `Sig` grep, cache-info
response, or top-level signature is insufficient. Preparation/verification
failure leaves `deploy` unchanged; real signing/content verification is still a
live validation gate.

The separate promotion job also requires successful checks, a nonempty prepared
run, the same repository/ref guards, and `LINK_PREBUILD_PROMOTION == 'true'`.
Both forges exclude `deploy` from build triggers and retain defensive job guards;
lock updates remain on the default branch. Default-branch runs are not cancelled
in favor of newer runs; correctness must not depend on FIFO scheduling or token
trigger suppression.

Promotion uses the existing `FORGE_TOKEN` through temporary credentials, not an
argv token or a new CI secret, and removes checkout's competing authorization
header. **Verify the token's actual actor**, which may be the human owner, before
protecting `deploy`: only the intended actor may advance it, no force/delete or
human merges, and required statuses must already be complete. Do not require the
promotion job's own pending status for its push.

Under the persistent promotion lock, the helper reconciles any unresolved intent,
validates prepared state/roots, then discovers authoritative default/deploy refs.
A missing deploy ref is distinct from a network/authentication error. Candidates
must still be the default tip, and existing deploy must be their ancestor. The
push names the **exact tested SHA** with an explicit lease on the observed old
SHA (or absence); no unconditional force or API ref replacement is allowed.
Default can advance between its check and the one-ref push: the contract is
**tested, monotonically advancing deploy**, not an atomic update of two refs or
an assurance that deploy is always the newest default tip.

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
same-SHA retry behavior, but no passing result is asserted here.

The workflow calls lock-aware `prune` after successful preparation even when
promotion is off; promotion also prunes after durable finalization. This is not
an age-only tmpfiles rule or an independent timer: without a later successful
run or separately authorized maintenance, eligible runs can remain longer.
Never move registered roots, discard current roots before replacement, or wipe
the store. Existing GC thresholds stay unchanged; disk pressure is not permission
to evict protected releases. `keep-outputs` can retain more than runtime closures,
so this policy is no disk quota.

## Approval-gated rollout

Stop at any failed gate. The owner authorizes each live stage; Fixer implements
source changes; the orchestrator reviews artifacts; the background validator
collects scoped evidence after writers reconcile. Stage new sources before
Git-backed evaluation/regeneration. For this task, the background validator runs
regeneration, which rewrites all `files.file` outputs and `flake.nix`; the
orchestrator reviews the entire generated diff. Preserve external `flake.lock`
and `modules/marin/hardware-configuration.nix` changes.

1. **Reconcile disabled source.** Validate defaults, missing-prerequisite failure,
   and an isolated enabled test fixture with synthetic public material only.
   Check no reverse access, no unintended consumers/publication, CI guards and
   existing coverage/auth/budgets. Run focused offline tests and formatting/link
   checks; mocks prove control flow, not TLS/signing or live pushes.
2. **Provision only with separate approval.** The owner/secrets maintainer creates
   a real signing identity through the private secrets workflow, encrypts the
   one new file for Link, and supplies only its real public key to Fixer for
   `linkCache.publicKey`. Any private-input revision change is separately
   reviewed. Verify the existing ACME credential is usable without exposing it.
   Do not read/print private key bytes, track plaintext, or add CI signing secrets.
3. **Activate Link only after approval.** Prepare reviewed enable/public-key
   values and regenerate, but coordinate publishing the enabled default-branch
   workflow: it schedules real preparation builds even with promotion off.
   Deploy only Link from the approved candidate using existing single-host
   tooling; leave clients unactivated. Verify actual bindings, untrusted service
   user/credential handling, public-key match, TLS, exact source ACLs, denied
   methods/paths, and unauthorized LAN/WireGuard sources. Verify missing-signer
   isolation without interrupting unrelated nginx sites. Never bypass TLS.
4. **Prove preparation before promotion.** Separately authorize publishing/running
   the enabled workflow and real three-host builds. Require remote full-closure
   signature/content verification, daemon-visible roots across runner restart,
   and retention/recovery evidence. Record runner scope, trusted contributors,
   token actor, branch protection, and completed required statuses. Enable
   promotion last, only after those prerequisites and a production-ref update
   are approved.
5. **Activate client policy one host at a time.** `impa`, then `iot`, then `marin`:
   verify hostname resolution and `ip -4 route get 192.168.6.6`, then observed
   source/return path to TCP/5050. Require the exact allowlist above, never a
   guessed NAT source. Test cold whole-closure fetch and fail-closed negatives
   without activation before proceeding to the next client.
6. **Comin remains deferred.** Design and validate the activation/rooting adapter
   separately; neither publication nor a successful fetch activates a system.

Keep the approved SHA/lock digest, provisioned public-key identity, per-host output
paths, remote closure/signature/content results, stable-root observations,
old/candidate/observed deploy refs, and each client's route/ACL/cold-fetch results.
Record failed gates as well as successes; review reports for private contents.

Live stages are pending authorization; repository checks belong to the validator
after writers reconcile. Linux Nix validation/long-running commands use the
approved background validator and inherited `agent-run-long` procedure, with fresh
`direnv exec .` when a dev shell is needed. For a separately approved local
system build, use the `agent-run-long` skill's wrapped, raw-output NH host-build
form (`--no-nom --log-format raw -L`), not raw `nix build` or `nixos-rebuild`.
If execution/delegation is unavailable, record the limitation.

## Future client no-build contract

Enabled clients add the real cache URL/key and require signatures, with
`max-jobs = 0`, `fallback = false`, and no distributed builders. Public caches
remain. **`max-jobs = 0` is not an absolute no-build guarantee**: in particular,
`preferLocalBuild` derivations can still execute. Ordinary evaluation also stays
local. Disabled defaults leave pre-existing local settings unchanged.

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

For the later authorized fetch proof, using already installed Nix rather than
loading a dev shell that might itself build, an `impa` evaluation payload is:

```fish
nix eval --no-update-lock-file --no-write-lock-file \
  --option allow-import-from-derivation false --raw \
  .#nixosConfigurations.impa.config.system.build.toplevel.outPath
```

After checking that result against the release record, a copy-only payload is:

```fish
set toplevel /nix/store/REPLACE_WITH_VERIFIED_SYSTEM_OUTPUT
nix copy --from https://link-cache.home.finnrut.is:5050 --to daemon "$toplevel"
```

Replace the placeholder; require the provisioned trusted public key and
`require-sigs = true`. Do not use `--no-check-sigs`, disable TLS, substitute a
flake installable, or treat these two commands as a complete activation workflow.
Use an initially cold client/output for proof; copying into a warm Link store is
not evidence of publication. Missing-dependency, unsigned-input-addressed-path,
and wrong-key tests must fail without building or activating. No such live proof
has been supplied.

## Recovery and rollback

First **disable promotion**, preserve the current ref, manifests, roots, and any
unresolved intent, and reconcile ambiguous push outcomes before retrying. Do not
manually delete intent to force progress or prune to recover disk space. Fix the
cause and use the guarded helper only after review; source comments and a failed
job alone cannot establish the actual remote ref.

For a planned shutdown, restore client cache/local-build policy one client at a
time before removing the Link endpoint/key. Do not strand clients at
`max-jobs = 0` or remove a key still needed for a pending closure. Preserve current
and rollback roots; endpoint shutdown need not delete store contents. A reviewed
revert on the default branch followed by fresh preparation/forward promotion is
preferred to rewinding `deploy`. Emergency ref rewind is separate authorized
break-glass work, not a normal helper operation.

Signer compromise requires stopping publication/promotion and revoking affected
client trust under an incident plan. Removing a key does not repair a compromised
Link or prove previously signed outputs safe. Keep Fly retired throughout;
rollback does not restore dead Fly consumers or authorize provider/credential
deletion.
