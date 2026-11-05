---
name: service-add
description: "Add or configure declarative services in infra: NixOS or Home Manager service modules, custom systemd system/user units, and OCI containers."
---

# Service addition

## Establish context

1. Read repository `AGENTS.md` and load the [nix skill](../nix/SKILL.md) for
   module conventions. Current repository rules and this workflow take
   precedence over older search, validation, or deployment advice there.
2. Identify the service, target host(s) or role, and whether it runs system-wide
   or per user. Ask only when ambiguity changes which hosts run it.

## Choose the packaging

Prefer an upstream module when one exists; otherwise choose by what the service
actually needs (packaged in nixpkgs or `pkgs/`, upstream ships only an image,
state and user requirements):

| Option                                                            | Fits when                                                           |
| ----------------------------------------------------------------- | ------------------------------------------------------------------- |
| NixOS `services.<name>`                                           | Upstream NixOS module covers the need                               |
| HM `services.<name>` / `programs.<name>`                          | Per-user service with an upstream HM module                         |
| `systemd.services.<name>` / HM `systemd.user.services.<name>`     | Packaged binary or script without a module                          |
| `virtualisation.oci-containers.containers.<name>` (digest-pinned) | Upstream distributes only an image, or Nix packaging is impractical |

- Use the **nixos MCP** option lookup tools (discover their current schemas) to
  find and inspect NixOS and Home Manager options before writing a custom unit.
  Treat results as discovery, not proof for this flake's pinned nixpkgs;
  hand unresolved pinned-availability questions to the validator.
- Search `modules/` for the service name, its options, and similar units
  before creating structure; extend an existing module rather than duplicating
  one.

## Choose the location

`import-tree` auto-imports every `.nix` file under `modules/`. Confirm current
layout from source; do not trust a remembered host directory map.

- **One host**: `modules/<host>/<service>.nix` declaring
  `configurations.nixos.<host>.module` (see `modules/marin/`, `modules/link/`).
- **A role**: a domain directory (`modules/network/`, `modules/media/`, …)
  declaring `flake.modules.nixos.<role>`. `modules/roles.nix` maps host roles to
  modules; the desktop role's module is named `pc`. Check `modules/hosts.nix`
  for which hosts carry the role.
- **Per-user service**: `home-manager.users.tunnel` inside a host module
  (see `modules/link/ledfx.nix`), or a `flake.modules.homeManager.<name>`
  module only if that module is actually imported for the targets
  (see `modules/home-manager/nixos.nix`).

## Write the module

For a custom unit, model on a nearby existing one such as
`modules/iot/choreops-todoist-sync.nix` (oneshot on a timer, dedicated user,
hardening), and add only the ordering, dependencies, and user model the
service needs.

- Reference binaries via `lib.getExe`/store paths, never `$PATH` lookups.
- Prefer upstream module hardening; for custom units add sandboxing
  (`DynamicUser`, `StateDirectory`, `ProtectSystem`, …) suited to the service.
- Keep `networking.firewall` openings in the same module as the service, and
  scope them (e.g. `interfaces.<if>.allowedTCPPorts`) when possible.
- Secrets: use agenix `age.secrets.<name>.file = "${inputs.secrets}/<name>.age"`
  and pass `config.age.secrets.<name>.path` (see `modules/marin/grocy.nix`).
  Never write secret values into the repository.
- Public/split-DNS exposure goes through the service-publication registry; read
  `docs/service-publication-runbook.md` before touching it.
- Data needing backup: check `modules/backup/` and note gaps.

## Stage and validate

- `git add` new files immediately; flake evaluation ignores untracked files.
- Builds, evaluations, and checks belong to the background `@validator`; give it
  the exact installable (e.g. the host's `nixosConfigurations.<host>` toplevel
  or a specific `checks` attribute). Full `nix flake check` stays in CI.
- Hand evaluation, build, or runtime failures you cannot resolve from the
  error to `@diagnostician`; do not guess-fix repeatedly.
- Never deploy, switch, or restart units without explicit authorization. Never
  run `nixos-rebuild` or an unqualified `nix build`.

## Report

1. Service added and where (`file:line`), and the approach chosen.
2. Scope (host/role/user) and why.
3. Secrets, firewall ports, publication, or backup needs.
4. Validation requested or run, and its result.
5. Activation path for the user (e.g. `just colmena-apply <host>`,
   `just rebuild`; `just deploy-services` for publication hosts).
