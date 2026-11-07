---
name: infra-navigation
description: Use when locating or deciding where something belongs in the Multipixelone/infra flake-parts repo — which file defines or should own a NixOS/Home Manager/darwin option, host, service, package, check, generated file, or deploy target. Gives the ownership rules and discovery commands, not a full inventory.
---

# Infra navigation

Find ownership by searching the live tree; this skill gives the rules, not a map. Do not trust any cached host/module table (including old agent docs): grep the current files.

## How modules load

- `outputs.nix` → `flake-parts.lib.mkFlake` with `(inputs.import-tree ./modules)`: every `.nix` under `modules/` is a flake-parts module, auto-imported. There is no central import list. New files must be `git add`ed before evaluation sees them.
- `flake.nix` is generated. Inputs live in `flake-file` declarations inside modules (`rg 'flake-file.inputs' modules`).
- Modules contribute reusable fragments via `flake.modules.<class>.<name>`, where class is `nixos`, `homeManager` or `darwin`. Names such as `base`, `pc`, `gaming` are aspects, and many files may merge into one name.

## Ownership rules

| Looking for                                                        | Where it lives / find it with                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host list, metadata (IPs, WireGuard, roles)                        | `modules/hosts.nix` (`hosts.<name>`)                                                                                                                                                                                                                                        |
| Role-injected aspects (`server`, `laptop`, `edge`, `desktop`→`pc`) | `modules/roles.nix`: NixOS hosts get the module for each `hosts.<name>.roles` entry                                                                                                                                                                                         |
| Host-specific aspect imports                                       | `modules/<host>/imports.nix` → `configurations.nixos.<host>.module` (darwin hosts: `configurations.darwin`)                                                                                                                                                                 |
| Host-only config (hardware, host services)                         | `modules/<host>/*.nix`                                                                                                                                                                                                                                                      |
| How hosts become `nixosConfigurations` / colmena / darwin          | `modules/configurations/{nixos,colmena,darwin}.nix`                                                                                                                                                                                                                         |
| Shared feature for several hosts                                   | domain dir (`modules/network/`, `modules/media/`, `modules/shell/`…) defining a `flake.modules.nixos.<aspect>`                                                                                                                                                              |
| Home Manager user config                                           | `flake.modules.homeManager.<aspect>` in the domain module; wiring in `modules/home-manager/{base,nixos,darwin}.nix`                                                                                                                                                         |
| Local package                                                      | derivation in `pkgs/<name>/`; consumed via `callPackage "${rootPath}/pkgs/<name>"` in the module that uses it (`rg 'pkgs/<name>' modules`)                                                                                                                                  |
| Flake checks                                                       | `perSystem.checks` in any module (`rg -l 'checks' modules`); e.g. `modules/package-checks.nix`, `modules/home-manager/checks.nix`. CI check selection/build wiring lives in `modules/ci.nix`, `modules/ci/forgejo.nix`, and `lib/ci.nix`; active workflow YAML is generated |
| Generated files (`README.md`, `flake.nix`, …)                      | `text.readme` / `files.file` contributions (`modules/readme.nix`, `modules/files.nix`); edit sources, never output                                                                                                                                                          |
| AI agent/skill config                                              | `modules/shell/ai/`; skills in `docs/skills/<name>/SKILL.md`                                                                                                                                                                                                                |
| Credential / agenix workflow                                       | private `nix-secrets` repo; see `modules/shell/ai/prompts/secrets.md`                                                                                                                                                                                                       |
| Repeatable procedures                                              | `docs/skills/*/SKILL.md` (e.g. `package-add`, `service-add`)                                                                                                                                                                                                                |
| Runbooks                                                           | `docs/*.md` (e.g. `docs/new-host.md`, `docs/service-publication-runbook.md`)                                                                                                                                                                                                |
| Deploy / task commands                                             | `Justfile`                                                                                                                                                                                                                                                                  |

## Discovery

- Who sets an option: `rg -n 'services\.foo\b' modules`.
- What an aspect contains: `rg -ln 'flake.modules.nixos.<aspect>\b' modules`.
- Which hosts get an aspect: `rg -n '<aspect>' modules/*/imports.nix`, plus role injection (`modules/roles.nix` + `roles = ` in `modules/hosts.nix`).
- Upstream option/package semantics: the `nix` skill / nixos MCP, not this repo.

## Placement

Put new config in the narrowest owner. One host means `modules/<host>/`. Several hosts means a domain module exposing an aspect. If it follows a role, extend that role's aspect (or `roleModules` in `modules/roles.nix`); otherwise add the aspect to each host's `imports.nix`. Prefer one concern per file; import-tree picks it up automatically.
