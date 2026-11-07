# Link distributed builds — superseded, never activated

**Superseded on 2026-11-07. This design was NEVER ACTIVATED.**

The owner rejected granting `impa`, `iot`, and `marin` root-equivalent trusted
Nix access to Link. The earlier repository implementation and scoped checks were
not deployment evidence or security acceptance. Its source module and reverse-trust
rollout instructions have been removed; do not restore or activate that configuration.

The accepted replacement is **Link CI prebuilds → private signed read-only cache
→ guarded exact-SHA `deploy` ref → later client pull/activation**. It adds no
trusted client access to Link. See the canonical
[Link prebuild/pull runbook](link-prebuild-pull.md) for implementation status,
security boundaries, provisioning gates, retention, and rollback.

The independent Fly cleanup remains in scope; Fly was reported stopped by the
owner. The [decision record](ci-build-cache-decision-record.md) preserves the
October incident evidence and the dated architecture changes. Comin activation
remains deferred.
