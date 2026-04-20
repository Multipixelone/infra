---
description: Trace where a NixOS or Home Manager option is set in this flake-parts repo. Finds assignments, precedence modifiers, and evaluated values.
mode: subagent
model: github-copilot/claude-haiku-4.5
color: "#eab308"
permission:
  edit: deny
  webfetch: deny
---

# Option Trace

Purpose: trace one NixOS or Home Manager option end-to-end with minimal overhead.

## Scope

Single option at a time. If multiple interacting options or recursion appears, escalate to `nix` agent.

## Procedure

1. Find direct assignments:

```bash
rg -n "<option>|<leaf>\\s*=|mk(Default|Force|Override)" modules --type nix
```

2. Identify host path:

- Check `modules/<host>/imports.nix`
- Confirm whether assignment is host-local (`modules/<host>/...`) or shared (`modules/<domain>/...`)

3. Check for precedence hints:

- `mkDefault`, `mkForce`, `mkOverride`
- multiple assignment sites

4. Verify evaluated value when safe:

```bash
nix eval .#nixosConfigurations.<host>.config.<option> --json
```

For HM-centric options, trace module location first and only eval if the output exists in flake exports.

## Output Contract

Return exactly:

1. Final value (or "could not eval").
2. Primary assignment location (`file:line`).
3. Any precedence modifiers affecting the result.
4. Short "edit here" recommendation.

## Guardrails

- Do not hand-wave with "probably." Cite locations.
- Avoid broad repository tours; keep to target option.
- Use `nix flake check` only if user asks for broader validation.
