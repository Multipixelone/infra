# Multipixelone/infra

NixOS + home-manager infrastructure managed with flake-parts.

## Build Commands

| Command              | Purpose                              |
| -------------------- | ------------------------------------ |
| `just rebuild`       | Local rebuild via `nh os switch`     |
| `just deploy`        | Rebuild + push to attic cache        |
| `just colmena-apply` | Deploy to remote hosts               |
| `just debug`         | Rebuild with verbose trace           |
| `just update`        | Update flake lock + firefox addons   |
| `just gc`            | Garbage collection + history cleanup |
| `nix flake check`    | Run all checks (CI does this too)    |

**NEVER use bare `nix build` or `nixos-rebuild` directly.**

## Repository Structure

```
modules/           # Flake-parts modules (auto-imported via import-tree)
├── <host>/        # Host-specific configs (link, zelda, marin, iot)
├── shell/         # Shell tools, AI config, terminal setup
├── hyprland/      # Window manager
├── theme/         # Styling (Stylix)
├── hardware/      # CPU, GPU, RAID
├── network/       # DNS, WireGuard, firewall
├── home-manager/  # HM base, GUI, gaming, checks
├── boot/          # EFI, boot options
└── *.nix          # Feature modules (backup, ci, locale, etc.)
pkgs/              # Custom package definitions
docs/              # Skills, agents, documentation
```

## Flake-Parts Patterns

- **import-tree**: All `.nix` files in `modules/` are auto-discovered. New files MUST be `git add`ed to be visible.
- **Module style**: Each module returns `{ flake = { ... }; }` and/or `{ perSystem = { ... }; }`.
- **NixOS configs**: Defined via `configurations.nixos.<host>.module` with imports from `config.flake.modules.nixos`.
- **Single system**: `systems = [ "x86_64-linux" ]` — no Darwin.

## Host Conventions

- Hosts named after Zelda characters: `link` (desktop), `zelda` (laptop), `marin` (server), `iot` (server)
- Each host has: `imports.nix`, `facter.nix`, `hardware-configuration.nix`, `hostname.nix`, `state-version.nix`
- Host imports compose feature modules: `imports = with config.flake.modules.nixos; [ efi pc gaming ];`

## Secrets

- Managed via `agenix` — encrypted in private `inputs.secrets` repo
- Access pattern: `config.age.secrets."path/to/secret".path`
- NEVER commit unencrypted secrets

## Custom Packages

- Defined in `pkgs/` directory
- Referenced via `pkgs.callPackage "${rootPath}/pkgs/..." { }`
