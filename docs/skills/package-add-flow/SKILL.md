---
name: package-add-flow
description: Deterministic workflow for adding packages in Multipixelone/infra with correct scope and safe validation.
tools: Read, Grep, Glob, Bash, Edit, Write
---

# Package Add Flow

Purpose: make package addition a repeatable, low-ambiguity flow suitable for lighter models.

## Rules

- Never suggest `apt`, `brew`, `pip`, or imperative global installers.
- Prefer existing package lists/modules over creating new structure.
- Use repository commands (`just rebuild`, `just deploy`, `just colmena-apply`) for activation workflows.

## Step 1: Confirm Package Availability

```bash
nh search <name>
nix search nixpkgs#<name>
```

If not found, check:

- alternate package name
- flake input package
- `pkgs/` custom derivation path via `pkgs.callPackage`

## Step 2: Choose Scope

- **Host/system-wide**: edit NixOS module under `modules/`
- **User/HM scope**: edit Home Manager module under `modules/home-manager/` or related program module
- **Custom package needed**: add derivation under `pkgs/`

Locate existing lists first:

```bash
rg -n "environment\\.systemPackages|home\\.packages|with pkgs" modules --type nix
```

## Step 3: Apply Minimal Edit

- Add package near related entries.
- Keep ordering/style consistent with neighboring code.
- Do not refactor unrelated lists.

## Step 4: Validate

Primary validation:

```bash
nix flake check
```

If user asked for activation/deploy:

- local: `just rebuild`
- local + cache push: `just deploy`
- remote: `just colmena-apply`

## Output Contract

Return:

1. What package was added and where (`file:line`).
2. Why that scope was chosen.
3. Validation command run and result.
4. Follow-up command user can run next.

## Escalation

Escalate to `nix` skill/agent when:

- package requires overlay overrides
- platform incompatibility appears
- derivation fetch/hash debugging is needed
