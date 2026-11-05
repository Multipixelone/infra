---
name: package-add
description: Add or install packages declaratively in infra's NixOS or Home Manager configuration, choosing the correct host/user scope and making a minimal edit.
---

# Package addition

## Establish context and scope

1. Read repository `AGENTS.md` and load the [nix skill](../nix/SKILL.md) for
   module conventions. Current repository rules and this workflow take precedence
   over older search, validation, or deployment advice in that reference.
2. Identify the requested package, target host/user, and whether it belongs in
   system-wide NixOS configuration or Home Manager. Infer scope from an existing
   matching module and the request; ask if ambiguity would change who receives
   the package.
3. Locate existing package lists and program modules under `modules/`. Search for
   the package name, `environment.systemPackages`, `home.packages`, and relevant
   `programs` options before creating structure. Follow module composition to
   confirm the target actually imports/enables the chosen module.

Home Manager modules are not confined to `modules/home-manager/`: for example,
`modules/calculator.nix` defines `flake.modules.homeManager` package lists. Use
current source rather than assuming directory names determine scope.

## Confirm the package

- Use the **nixos MCP** package lookup tools: discover their current schemas,
  search the requested name, and inspect matching package details to choose the
  exact attribute. Use its NixOS/Home Manager option lookup when a program module
  is a better fit than a bare package entry. Do not default to `nix search` or
  `nh search`.
- Treat lookup results as discovery, not proof of availability in this flake's
  pinned nixpkgs or on the target platform. Check existing source/input context;
  hand unresolved pinned-availability questions to the validator.
- If no match exists, check alternate names, existing input packages, and the
  repository's `pkgs/` definitions and their wiring. Do not assume a derivation
  becomes available merely by placing it there. Propose custom packaging or an
  input change separately if it expands the requested scope.
- If MCP lookup is unavailable, report the limitation and use existing repository
  evidence where sufficient; otherwise ask for the missing package information.
  Do not guess an attribute or install through an imperative global installer.

## Make the smallest declarative change

- Prefer the existing relevant package list or program module. Avoid duplicate
  installation if a `programs.<name>.enable` option already supplies the package.
- Match neighboring ordering, qualification (`pkgs.foo` versus `with pkgs;`), and
  module style. Add only the requested package/configuration; do not refactor
  unrelated lists or widen host/user coverage.
- Follow repository rules for generated files and flake declarations. Stage any
  new source files by explicit path before handing off Nix validation so the
  Git-backed flake includes them; do not stage unrelated work.

## Review and hand off

- Review the focused diff for the package attribute, scope, duplicate entries,
  and unintended changes. Report the exact files and intended host/user impact.
- The **validator** owns Nix checks (including evaluations and builds), long
  checks, and full validation. Supply changed paths, target scope, and unresolved
  availability questions. Full checks stay in CI by default; if local validation
  is authorized, delegate it rather than running it here. Report skipped or
  unavailable validation accurately, without claiming the package builds.
- Adding a package is not authorization to activate or deploy. Only perform
  activation/deployment with explicit authorization for the intended target,
  after verifying current repository workflow and validation results. Do not
  launch a broad rebuild or remote deployment as a package-add check.
