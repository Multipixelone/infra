# CI build offload and binary-cache discussion record

**Date:** 11 October 2026
**Status:** Discussion record; architecture and implementation approval pending
**Purpose:** Preserve the incident evidence, alternatives, recommendations, and open decisions as an internal source for a future technical portfolio writeup.

## 1. Current direction and decision boundaries

The latest request changes the direction of the discussion:

> “wait hang on i'm analyzing having blacksmith ci on github build everything and push everything to the attic cache so link doesn't have to always do everything, and then I could do a writeup about it and apply for a job with the writeup. Write a doc with everything we discussed and decided”

Earlier discussion favored consolidating builds on `link`, potentially removing Attic publishing and eventually retiring the cache. That was an evolving preference, not an implemented retirement. The current hypothesis is **GitHub Actions with Blacksmith builds the agreed workload and publishes closures to Attic, allowing `link` to substitute instead of repeatedly compiling**.

Migration is paused. No provider trial, architecture selection, workflow replacement, cache retirement, deployment, or resource-budget change is approved by this documentation request. Fly, Neon, and R2 remain intact. Existing unrelated changes to `flake.lock` and `modules/virt/libvirt.nix` are outside this work.

The useful distinction is between three responsibilities: CI decides what to validate; builders perform compilation; a binary cache distributes completed store objects. Moving compilation can reduce load on `link`, but does not repair an unreliable distribution service.

## 2. Attic incident: evidence and limits

All findings below are **11 October 2026 snapshots**, combining the host diagnosis and the separate Fly investigation supplied during the discussion. They are not fresh availability guarantees.

### Failed build

The user ran:

```text
nh os build -H link -o ~/.local/state/openclaw-nixos/pending ~/Documents/Git/infra
```

Evaluation reached the system derivation:

```text
/nix/store/r3yjnwvdk3w268xxl5dj5ryqxnl55fn3-nixos-system-link-26.11.20261008.e7439b6.drv
```

The recorded run lasted **117 seconds**, from **17:02:39 to 17:04:36 UTC**, or **13:02:39 to 13:04:36 EDT**, and exited with status 1. Its fatal error was:

```text
https://attic-cache.fly.dev/system/2a531ldhcxmdj4g221h4z7c6nwgs46m7.narinfo
Server returned nothing (no headers, no data) (52) Empty reply from server
```

Evidence is in `/tmp/opencode/agent-run-long.nh-os-build-link.J4XZo8B7y7/output.log`, particularly lines 11, 14, and 16–19, and the adjacent `status` file. These are temporary local artifacts, not durable repository fixtures. The failure establishes a metadata-transfer error, not a failed compilation, corrupt NAR, signature mismatch, or HTTP authentication rejection.

### Fly timeline

The separate lane reported one `iad` machine, `e829e11a1d1508`:

| UTC time          | Reported event                                |
| ----------------- | --------------------------------------------- |
| 16:42:11          | Requested autostop; clean exit 0, `oom=false` |
| 17:04:32.585      | Wake began                                    |
| 17:04:33.833      | Application logged `Running migrations...`    |
| 17:04:33–34       | Six connection-refused events during startup  |
| 17:04:35.532      | Application listening                         |
| 17:04:36.063      | Health check passed                           |
| 17:04:36.811/.813 | EOF events                                    |

The overlap strongly supports investigating wake-up/proxy behavior. Fly TLS termination followed by raw TCP forwarding provides a plausible mechanism for an empty reply, but absent request IDs or URL correlation, the exact failing request cannot be assigned to those events. There was no reported OOM or crash evidence. Startup proceeded from migrations to listening; that does not prove ongoing database health or R2 object availability.

Later, an anonymous cache-info request returned 401 and the exact narinfo returned 404. A user-run probe using the daemon's configured netrc returned **404 `NoSuchObject` in 59.737 ms**. This establishes a complete HTTP response and a reported cache miss at that moment. It does not independently establish accepted authentication or comprehensive R2 health. A retry might progress because Nix normally treats missing narinfo as a cache miss; a complete rebuild was not verified.

The host lane's earlier attempt at 17:31:42 UTC was blocked before HTTP: `/run/agenix/attic` was root-only and `sudo -n` required a password. It did not substitute another credential. The subsequent user-supplied result is therefore distinct evidence, not a result produced by that blocked command.

### Service configuration and proposed improvements

The separate Fly checkout's `/home/tunnel/Documents/Git/fly/fly.toml` described TLS-only TCP routing from 443 to 8080, one shared CPU, 2 GiB RAM, `auto_stop_machines = "stop"`, autostart enabled, and zero minimum running machines. Connection limits were soft 200/hard 250; the TCP check used a 30-second interval, 10-second timeout, and 120-second grace period.

Its `server.toml` described monolithic Attic, Neon PostgreSQL, R2 storage, chunking, presigned redirects, a 32 MiB small-NAR threshold, and 90-day retention. Garbage-collection behavior while sleeping needs review. A public HTTP handler had intentionally been removed after earlier large-upload failures: approximately 2.1 GB uploads, 32–667-second attempts, HTTP 502, and low CPU usage. Reintroducing it casually could restore that problem.

Suggestions, **not applied**, were keeping one machine warm, evaluating stronger internal HTTP readiness against a proven endpoint, and restricted authenticated external probes of known-good metadata plus a small NAR. Warm capacity adds cost and does not guarantee availability. This is not a claim that monitoring is absent or that scaling is necessary. See [Fly autostop/autostart](https://fly.io/docs/apps/autostop-autostart/) and [health checks](https://fly.io/docs/reference/health-checks/).

## 3. Nix behavior and fallback recommendation

Local hostname was confirmed as `link`. Nix was **2.35.2**, matching the daemon package. Filtered client configuration and a user-config-disabled query reported:

| Setting                                             | Snapshot                                   |
| --------------------------------------------------- | ------------------------------------------ |
| `fallback`                                          | `false`                                    |
| `connect-timeout`                                   | 15 seconds                                 |
| `stalled-download-timeout`                          | 300 seconds                                |
| `filetransfer-retry-attempts` / `download-attempts` | 5                                          |
| Positive narinfo TTL                                | 30 days                                    |
| Negative narinfo TTL                                | 1 hour                                     |
| `netrc-file`                                        | `/run/agenix/attic`, mode 0400, root-owned |

`/etc/nix/nix.conf` resolved to `/nix/store/n3k8an0i91zyh57dfrgayqp48xv7m0is-nix.conf`. Lines 16, 20, and 28 respectively set netrc, substituters, and the optional `/run/agenix/nix` include. User configuration resolved to `/nix/store/wglzirhz6z3s2sr1hsl6p9dh2fwqc6vb-nix.conf`; no requested-setting overrides were found. The systemd unit and drop-in did not configure `NIX_CONFIG` or proxy variables. The daemon's complete in-memory environment was inaccessible, so these are client and on-disk/startup findings, not absolute proof of every running-daemon setting.

Attic was configured as `https://attic-cache.fly.dev/system?priority=50`, alongside cache.nixos.org and several Cachix caches. [The cache module](../modules/nixpkgs/substituters.nix), lines 22–24 and 32–41, supplies the Attic URL, flake cache settings, and NixOS base settings. [The authentication module](../modules/nixpkgs/attic.nix), lines 10–23, declares secrets and netrc/include consumers.

Subsequent version-specific review of [Nix 2.35.2's substitution goal](https://github.com/NixOS/nix/blob/2.35.2/src/libstore/build/substitution-goal.cc) clarified the initial uncertainty: `PathSubstitutionGoal` catches `queryPathInfo` failures and tries other caches. With fallback disabled, a saved error can become fatal if no substitute succeeds; fallback permits source building on that path. This does **not** prove cache.nixos.org was skipped. Content-addressed realisation queries and other query APIs have separate paths; fallback is not a universal error suppressor.

The recommendation was **system-only `nix.settings.fallback = true`**, separately reviewed and not applied, while retaining connect timeout 15 and retry count 5. A connection timeout does not bound every established connection or cure curl 52. Hosted GitHub CI already uses fallback true, connect/stalled timeouts 15/15, and 100 attempts ([CI source](../modules/ci.nix), lines 27–34); copying 100 attempts onto `link` is not recommended.

[Shared settings](../modules/nix/settings.nix), lines 18–37, have custom option declarations and exports into both NixOS and Home Manager. A system-only addition must respect that structure rather than accidentally changing both scopes. Source fallback also has resource costs: the snapshot showed `/nix/store` 96% used with about 64 GiB available. See the [versioned configuration reference](https://nix.dev/manual/nix/2.35/command-ref/conf-file.html).

## 4. Existing build, deployment, and CI arrangement

The NixOS fleet's Colmena path builds on `link` and copies missing closure objects over SSH. The reviewed configuration had no `buildOnTarget` override or fleet remote-builder arrangement; Colmena's default is false. Targets do not need an HTTP store merely to receive a deployment. A future dedicated physical compiler could accept Nix builds over SSH, return results to `link`, and leave evaluation and Colmena orchestration there. This is separate from hosted CI; see [distributed builds](https://wiki.nixos.org/wiki/Distributed_build).

Native Forgejo currently uses [the link runner module](../modules/link/forgejo-runner.nix): `nix:host`, capacity 2, DynamicUser, persistent HOME, and an eight-hour runner timeout. `batch-ci.slice` has MemoryHigh 8 GiB/MemoryMax 12 GiB. Actual daemon builders live separately in `batch-nix.slice`, so runner memory controls do not bound all compilation. Job injection sets `max-jobs = 3` and `cores = 4`; the workflow uses nix-fast-build concurrency 2, one evaluator, and an 8 GiB evaluation budget.

[The Forgejo workflow source](../modules/ci/forgejo.nix) sets a 420-minute build timeout. Per-ref cancellation is best effort; different branches can overlap. Ordinary pushes build the selected `checks.x86_64-linux`, including host system configurations; ISO work is manual. [Per-check status handling](../modules/ci/status.nix) seeds the expected checks and reconciles outcomes, including evaluation failures. Config, generated-file, and formatting gates also matter. Moving to manual fleet builds alone changes coverage.

The runner is a trusted Nix client with private-input SSH/token access. Native host execution is not an untrusted-fork sandbox. Comments conflict about global versus repository-scoped registration: the registration comment says global, while the trust rationale assumes repository scope. Verify live scope before relying on that boundary. See [Forgejo Actions security](https://forgejo.org/docs/v16.0/admin/actions/security/) and [workflow reference](https://forgejo.org/docs/latest/user/actions/reference/).

Store GC thresholds are 10–40 GiB; workspace cleanup is three days. Current nix-fast-build creates no default output links, and nh cleanup participates in maintenance. This is opportunistic reuse, not guaranteed retention of build intermediates. Reducing capacity to 1 for a heavy-build budget was recommended, not applied.

GitHub retains an advisory native `aarch64-linux` portable-package subset ([package checks](../modules/package-checks.nix), [CI source](../modules/ci.nix)). `link` has no equivalent native ARM coverage; ARM coverage should not disappear incidentally.

## 5. Provider alternatives discussed

These are prior research snapshots; prices, eligibility, and integration details require rechecking before purchase or experimentation. No trial established comparative speed.

| Option                              | Fit and caveats                                                                                                                                                                                                                     |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blacksmith                          | Documented GitHub App/organization and GitHub runner integration, with enterprise support; not a verified native Forgejo add-on. A GitHub mirror is a separate integration. YAML similarity does not supply the control plane.      |
| Garnix                              | GitHub App with Nix-native builds, private-input support, and cache. Earlier pricing research found 1,500 free minutes and Individual $25/10,000 minutes; not universal workflow compatibility.                                     |
| Hercules CI                         | Documented GitHub integration; native Forgejo support unverified. Self-hosted agents are an option. Earlier research found free public usage and a €29/active-user private plan with compute extra, not unlimited included compute. |
| Cachix                              | Binary-cache service rather than a builder; pricing was not verified in this discussion.                                                                                                                                            |
| Persistent VPS/physical Nix builder | Works through Nix SSH independently of Forgejo's runner marketplace. Adds machine operations; hardware and persistent-store benefits need benchmarking.                                                                             |

Blacksmith's earlier pricing snapshot was **$0.004/minute for a 2-vCPU Ubuntu runner with 3,000 free minutes/month**, with sticky-disk costs separate. Generic sticky disks are not automatically a correctly persistent Nix store; static egress is not a VPN. Official references: [GitHub App administration](https://docs.blacksmith.sh/blacksmith-administration/github-app), [runner overview](https://docs.blacksmith.sh/blacksmith-runners/overview), [sticky disks](https://docs.blacksmith.sh/blacksmith-caching/dependencies-sticky-disks), [Garnix CI](https://garnix.io/docs/ci), [Garnix pricing](https://garnix.io/pricing), and [Hercules CI](https://hercules-ci.com/).

## 6. Why retirement required more than deleting uploads

The earlier architectural review accepted exploring consolidation, but separated **publishing**, **substitution/trust**, and **private-input authentication**. Those are not interchangeable removals.

[Shared build recipes](../lib/ci.nix), lines 82–135, publish intermediate build closures through nix-fast-build. The Forgejo workflow adds Attic configuration/login and bounded upload retries. [Justfile](../Justfile), lines 22–42, separates local deploy-plus-push from Colmena build/deploy; `fastb` is another Attic consumer.

Deleting [the Attic module](../modules/nixpkgs/attic.nix) wholesale would also remove a private GitHub-token include. Likewise, GitHub's “Create attic netrc” step includes private GitHub authentication, not only cache authentication. Tracked `.github/workflows/eval.yaml` and `update-lock.yml` appeared absent from current generator declarations; they may still execute, and lock-writer behavior needs reconciliation. Static generator intent does not prove runtime workflow inactivity.

Any future retirement would require auditing consumers, approving edits to source declarations, generating rather than manually editing the flake, reconciling statuses and generated files, validating representative checks without Attic, observing resources and correct failures, explicitly authorizing deployment, and finally approving retirement. This sequence is conditional; it is not the current plan.

## 7. Proposed Blacksmith experiment and portfolio writeup

First define **“everything”**: exact host closures, check attributes, architectures, packages, and whether ISOs belong on every push or manual dispatch. Preserve existing required checks and recommended ARM coverage unless a separate coverage decision says otherwise.

Compare the native-link baseline with GitHub/Blacksmith cold and warm runs at the **same commit and lockfile**. Record runner hardware, environment, evaluator/build concurrency, cache state, and repetition count. Measure evaluation, compilation, substitution, upload, link download/closure-verification time, transferred bytes, failures/retries, total wall time, cost per verified closure, and link CPU relief. Account for runner, disk, egress, and cache storage costs. Separate compilation bottlenecks from Fly/upload reliability; Blacksmith cannot fix an unreliable Attic endpoint.

The experiment needs restricted cache-write credentials and private-input authentication, no fork-secret exposure, explicit signing-key/trust scope, and completed closures verified from `link` through authenticated narinfo and bounded NAR checks. Distinguish valid signature trust from trustworthy build provenance and cache-poisoning risk. Define mirror commit identity, required-status ownership, timeout/resource budgets, and cleanup before treating a green mirrored job as deployment evidence. Fallback changes remain separately approved.

A public case study could cover the problem, current architecture, incident timeline, alternatives, hypothesis, experiment method, measured results, cost/security tradeoffs, limitations, and a future dedicated builder. No experiment has run: publish no invented speedups, reliability improvements, or employment outcomes. Review tokens, private URLs, configuration excerpts, and operational identifiers before publication. This internal record is source material, not an application submission.

## 8. Questions still open

- Which exact workload and architectures should Blacksmith build, and at what trigger frequency?
- Is GitHub authoritative, a mirror, or an experimental lane, and where do required statuses land?
- Will hosted compute demonstrably reduce link load at acceptable end-to-end cost?
- Should existing checks and ARM coverage remain? The recommendation is yes; confirmation is pending.
- Do macOS, WSL, or external consumers depend on Attic? Consumer auditing is incomplete.
- Are system fallback, capacity 1, warm Fly capacity, or readiness changes approved? None are applied by this request.
- If retirement returns later, is removing the substituter/key authorized separately from uploads?

**Recorded outcome:** preserve evidence, pause migration, and evaluate GitHub + Blacksmith + Attic as an offload hypothesis before choosing an architecture or implementation.
