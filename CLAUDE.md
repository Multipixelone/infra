# Multipixelone/infra

NixOS + home-manager infra via flake-parts. Single system: `x86_64-linux`.

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
