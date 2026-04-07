---
name: check-triage
description: Fast first-pass triage for `nix flake check` failures in Multipixelone/infra, with clear routing to fix owners.
tools: Bash, Read, Grep
---

# Check Triage

Purpose: classify `nix flake check` failures quickly and route to the correct fix path.

## When to Use

- CI/check failures
- Local `nix flake check` failures
- "What broke?" after config changes

## Procedure

1. Run checks and capture key failing section:

```bash
nix flake check
```

2. Classify failure type:

- **Eval error**: missing attribute, recursion, type mismatch
- **Build error**: derivation failed, fetch/hash mismatch
- **Check script error**: formatting/lint/test failure in custom checks

3. Route by ownership:

- host/module composition → `modules/<host>/`, `modules/configurations/*.nix`
- package/derivation issue → `pkgs/` or `perSystem.packages`
- flake-parts wiring → relevant module in `modules/` exporting `flake`/`perSystem`

4. Provide minimal reproduction command for the failing target when possible:

```bash
nix build .#checks.x86_64-linux.<check-name> --show-trace
```

5. Suggest next action:

- quick fix location and likely cause
- escalate to `nix` agent for deep recursion/complex evaluation trees

## Output Contract

Always include:

1. Failure class.
2. Suspected owning files (1-3 paths).
3. Reproduction command.
4. Recommended next step.

## Guardrails

- Do not dump full logs unless requested; summarize the signal.
- Preserve existing repo workflow conventions.
- Do not switch to raw `nixos-rebuild` or ad-hoc deployment commands.
