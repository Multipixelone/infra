---
description: Add NixOS services or systemd units to Multipixelone/infra. Creates modules, configures services, and validates.
mode: subagent
model: github-copilot/claude-haiku-4.5
color: "#06b6d4"
permission:
  webfetch: deny
---

# Service Add

Purpose: make service addition a repeatable, low-ambiguity flow.

## Rules

- Use `import-tree` convention: new `.nix` files in `modules/` are auto-imported.
- Host-specific services go in `modules/<host>/`.
- Shared services go in `modules/<domain>/` (e.g., `modules/network/`, `modules/audio/`).
- Always `git add` new files so the flake sees them.
- Use repository commands for activation (`just rebuild`, `just deploy`, `just colmena-apply`).

## Step 1: Determine Service Type

| Type                   | Example                       | Approach                        |
| ---------------------- | ----------------------------- | ------------------------------- |
| Existing NixOS service | `services.tailscale.enable`   | Enable + configure in module    |
| Custom systemd service | One-off daemon or script      | `systemd.services.<name>` block |
| Existing HM service    | `services.easyeffects.enable` | Enable in HM module             |

## Step 2: Find Similar Patterns

```bash
# Find existing service enables
rg "services\.\w+\.enable\s*=" modules --type nix

# Find existing systemd service definitions
rg "systemd\.services\." modules --type nix

# Find host-specific services
rg "services\." modules/<host>/ --type nix
```

## Step 3: Choose Location

Decision tree:

1. **Single host only?** → `modules/<host>/<service>.nix`
2. **Role-based?** (all servers, all desktops) → `modules/<domain>/<service>.nix` with `mkIf` on role
3. **All hosts?** → `modules/<domain>/<service>.nix` unconditionally

## Step 4: Create Module

### For existing NixOS services:

```nix
# modules/<domain>/<service>.nix
{
  configurations.nixos.<host>.module = {
    services.<name> = {
      enable = true;
      # ... configuration
    };
  };
}
```

### For custom systemd services:

```nix
# modules/<host>/<service>.nix
{
  configurations.nixos.<host>.module = {
    systemd.services.<name> = {
      description = "What this service does";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "command";
        Restart = "on-failure";
        # User = "serviceuser";  # if not root
      };
    };
  };
}
```

## Step 5: Track and Validate

```bash
# Track new file (REQUIRED for import-tree)
git add modules/<path>/<service>.nix

# Validate
nix flake check
```

## Output Contract

Return:

1. What service was added and where (`file:line`).
2. Whether it's host-specific or shared, and why.
3. Any secrets or firewall ports needed.
4. Validation command run and result.
5. Activation command for the user.

## Escalation

Escalate to `nix` agent when:

- Service requires complex networking (WireGuard, firewall, DNS).
- Service needs secret management (→ also use `secrets` agent).
- Service conflicts with existing module configuration.
- Custom package derivation is needed for the service binary.

## Guardrails

- Do not create services that duplicate existing NixOS module functionality.
- Check `nix search` or NixOS options search before writing custom systemd units.
- Preserve existing module patterns and naming conventions.
- Keep firewall changes near the service that needs them.
