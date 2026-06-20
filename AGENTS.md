# Multipixelone/infra

NixOS + home-manager infra via flake-parts. Systems: `x86_64-linux` (all hosts) +
`aarch64-linux` (portable packages/wrappers only — built best-effort in CI on ARM
runners; no hosts are aarch64). Declared in `modules/systems.nix`.

## Build Commands

- `just rebuild` — local rebuild (`nh os switch`)
- `just deploy` — rebuild + push to attic
- `just colmena-apply` / `just colmena-apply-tag <t>` — deploy remote hosts
- `just debug` — rebuild with `--show-trace`
- `just update` — update flake lock + firefox addons
- `just fastb` — `nix-fast-build` + attic push
- `just iso` — build installer ISO
- `just gc` — garbage collect + wipe old generations
- `nix flake check` — run all checks (CI does this too)

**NEVER use bare `nix build` or `nixos-rebuild`.**

## Key Files

- `flake.nix` — **auto-generated**, NEVER edit. Regenerate: `nix run .#write-flake` (or `nix run .#generate-files` to regenerate everything)
- `outputs.nix` — flake entry point; imports `flake-file` and `import-tree ./modules`
- `modules/flake-file.nix` — core/shared flake inputs
- `modules/` — all `.nix` files auto-discovered via import-tree. **New files must be `git add`ed.**
- `pkgs/` — custom packages, referenced via `pkgs.callPackage "${rootPath}/pkgs/..." { }`
- `docs/` — skills, agents, documentation

Module style: each returns `{ flake = { ... }; }` and/or `{ perSystem = { ... }; }`.
NixOS configs: `configurations.nixos.<host>.module` with `imports = with config.flake.modules.nixos; [ ... ];`

## flake-file (Inputs)

Modules declare their own inputs inline — no need to touch `flake-file.nix` for feature-specific deps:

```nix
flake-file.inputs.beets-plugins.url = "github:Multipixelone/beets-plugins";
```

Binary caches: set `caches` per-module; aggregated into `flake-file.nixConfig` by `modules/nixpkgs/substituters.nix`.
Transitive input follows must be declared explicitly on each input in `modules/flake-file.nix` (no auto-pruning — `allfollow`/`nix-auto-follow` both caused lock churn because nix's dedup disagrees with theirs).
After any `flake-file` change: **`nix run .#write-flake`**. To regenerate all auto-generated files at once (flake.nix + files from `mightyiam/files`), use **`nix run .#generate-files`**.

## Wrappers (Portable Apps)

`nix-wrapper-modules` (`inputs.wrappers`) produces self-contained packages runnable on **any Nix device** via `nix run`:

```nix
perSystem.wrappers.packages.helix = true;
flake.wrappers.helix = { pkgs, wlib, ... }: {
  imports = [ wlib.wrapperModules.helix ];
  package = inputs.helix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  settings = { /* app config */ };
};
```

Consume in home-manager: `withSystem pkgs.stdenv.hostPlatform.system (ps: ps.config.packages.helix)`

## Hosts

Zelda characters: `link` (desktop), `zelda` (laptop), `marin` (server), `iot` (server).
Each has: `imports.nix`, `facter.nix`, `hardware-configuration.nix`, `hostname.nix`, `state-version.nix`.

## Secrets

agenix — encrypted in private `inputs.secrets` repo. Access: `config.age.secrets."path/to/secret".path`. NEVER commit unencrypted.

## Home Assistant (iot)

Native `services.home-assistant` on `iot` (192.168.8.111). External URL `https://ha.finnrut.is` (cloudflared). HA config dir: `/var/lib/hass`.

**Module layout** — HA config is split across `modules/iot/*.nix`. Each file contributes to `configurations.nixos.iot.module`:

- `homeassistant.nix` — service, `extraComponents`, `extraPackages`, `customComponents`, `services.home-assistant.config`, `iotHass.nixAutomations` option, and the bulk of nix-managed automations.
- `todoist.nix`, `foodtown-sort.nix`, `ha-mcp.nix` — feature slices. Each adds its own `services.home-assistant.config.*`, automations, secrets, shell_commands.

**Declarative automations** — use the `iotHass.nixAutomations` option (defined at `homeassistant.nix:123`). Append a HA automation attrset to the list; it serialises to `/etc/home-assistant/automations_nix.yaml` and is loaded via `automation manual: !include`. UI-created automations coexist in `/var/lib/hass/automations.yaml` (`automation ui: !include`).

```nix
iotHass.nixAutomations = [{
  alias = "Foo when bar";
  mode = "single";
  triggers = [{ trigger = "state"; entity_id = "binary_sensor.bar"; to = "on"; }];
  actions  = [{ action = "light.turn_on"; target.entity_id = "light.foo"; }];
}];
```

Use `triggers`/`actions`/`conditions` (HA 2024.10+ keys), not legacy `trigger`/`action`. `!secret foo` works — the YAML generator un-quotes tag strings (`homeassistant.nix:113`). Nix conventions: `''…''` for multi-line templates, triple-quoted `''' '''` inside Jinja to escape single quotes (see CTA train sensors at `homeassistant.nix:1379`).

**HA secrets** — token-based integrations use the existing `homeassistant-token` LLAT (`modules/iot/foodtown-sort.nix:44`, owner=hass, mode=0400). Shell commands that call the HA REST API follow the `writeShellApplication` wrapper pattern in `foodtown-sort.nix`: read the token from `config.age.secrets."homeassistant-token".path` at runtime, never bake into the store.

**Custom components** — install via `services.home-assistant.customComponents` (`homeassistant.nix:1333`). Prefer `pkgs.home-assistant-custom-components.<name>` from nixpkgs; fall back to a `pkgs.stdenv.mkDerivation` with `isHomeAssistantComponent = true` + `domain = "..."` if not packaged (see HACS at `homeassistant.nix:22`). HA's `preStart` symlinks them under `/var/lib/hass/custom_components/`. **Caveat**: HACS sometimes replaces those symlinks with real dirs, which makes the next `ln -fns` fail with `cannot overwrite directory` — fix by `sudo rm -rf /var/lib/hass/custom_components/<name>` and restarting `home-assistant.service`.

After changing HA config: `just colmena-apply-tag iot` (or restart `home-assistant.service` on the host for config-only changes).

## ha-mcp (Home Assistant MCP server)

Runs on iot at `http://192.168.8.111:8086/mcp` (LAN-only, firewalled at the network edge). Module: `modules/iot/ha-mcp.nix`. Talks to local HA via loopback + the `homeassistant-token` LLAT. Companion HA custom component `ha_mcp_tools` (in nixpkgs) provides the 5 filesystem/YAML tools; without it ~87 of ~92 tools still work.

**Client registration** — declarative under `mcp-servers.settings.servers.<name>` in home-manager. Already wired on `link` (`modules/link/openclaw.nix:78`); copy that block for new hosts:

```nix
mcp-servers.settings.servers.ha-mcp = {
  type = "http";
  url  = "http://192.168.8.111:8086/mcp";
};
```

**Use it for HA work** when an agent needs live entity state, service-call dry-runs, or to inspect existing automations/entities before proposing declarative changes. Workflow:

1. Query HA state via `ha_*` tools (entities, services, areas, devices).
2. **Author the change as Nix in this repo** — extend `iotHass.nixAutomations`, `services.home-assistant.config.*`, or a feature module — _not_ via `ha_config_set_yaml` or `ha_write_file`, which would silently drift from Nix.
3. `just colmena-apply-tag iot` to deploy. The MCP server has no authority over `/etc/home-assistant/configuration.yaml` (it's a read-only nix-store symlink); only `/var/lib/hass/automations.yaml` and UI-managed entities are mutable from the MCP side.

The filesystem/YAML tools (`ha_write_file`, `ha_config_set_yaml`, etc.) are sandboxed to `www/`, `themes/`, `custom_templates/`, `dashboards/`, and a small allowlist of top-level YAML keys — they're useful for one-off UI/dashboard tweaks but should not be used for anything that belongs in Nix.
