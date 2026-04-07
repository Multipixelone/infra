---
name: secrets-flow
model: haiku
description: Deterministic workflow for managing agenix secrets in Multipixelone/infra. Use for adding, referencing, or rotating encrypted secrets.
tools: Read, Grep, Glob, Bash
---

# Secrets Flow

Purpose: make agenix secret management a repeatable, low-ambiguity flow.

## Rules

- NEVER commit unencrypted secrets or plaintext credentials.
- Secrets live in the private `inputs.secrets` repo (git+ssh), not in this repo.
- Reference secrets via `config.age.secrets."path/to/secret".path` in NixOS modules.
- Reference secrets via `hmArgs.config.age.secrets."name".path` in Home Manager modules.
- Identity key: `/home/tunnel/.ssh/agenix`
- Secrets dir (HM): `/home/tunnel/.secrets`

## Step 1: Identify Secret Type and Scope

| Type | Scope | Pattern |
|------|-------|---------|
| NixOS service credential | System-wide | `age.secrets."name".file = "${inputs.secrets}/path.age";` |
| HM program credential | User-level | `age.secrets."name".file = "${inputs.secrets}/path.age";` |
| Environment file | Service | `environmentFiles = [ config.age.secrets."name".path ];` |
| Config file | Service | `rcloneConfigFile = config.age.secrets."name".path;` |

## Step 2: Find Existing Patterns

```bash
# Find all secret references in modules
rg "age\.secrets" modules --type nix

# Find all secret file declarations
rg "\.file\s*=.*secrets" modules --type nix

# Find environment file usage
rg "environmentFiles.*age\.secrets" modules --type nix
```

## Step 3: Add Secret Reference

In the relevant NixOS or HM module:

```nix
# NixOS module (system service)
age.secrets."service/credential" = {
  file = "${inputs.secrets}/service/credential.age";
  owner = "serviceuser";  # optional, defaults to root
  group = "servicegroup"; # optional
};

# Then reference:
services.myservice.passwordFile = config.age.secrets."service/credential".path;
```

```nix
# Home Manager module (user program)
age.secrets."program-token".file = "${inputs.secrets}/program/token.age";

# Then reference in activation or program config:
# hmArgs.config.age.secrets."program-token".path
```

## Step 4: Validate

```bash
# Check that the module evaluates (secret file must exist in inputs.secrets)
nix flake check --no-build

# Full validation
nix flake check
```

## Output Contract

Return:

1. What secret was added and where (`file:line`).
2. How the secret is referenced (NixOS vs HM, which service/program).
3. What file needs to exist in `inputs.secrets`.
4. Validation result.

## Escalation

Escalate to `nix` agent when:

- Secret decryption fails at activation time
- Complex multi-host secret sharing is needed
- agenix module integration issues (identity paths, key management)
- Need to work with the `inputs.secrets` repo itself

## Guardrails

- Do not create secret files — only reference them.
- Do not modify `modules/security/secrets.nix` unless adding base infrastructure.
- Preserve existing secret naming conventions (slash-separated paths).
