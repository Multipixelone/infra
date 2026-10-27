{
  perSystem =
    { pkgs, ... }:
    {
      packages.rtk-rewrite = pkgs.writeShellApplication {
        name = "rtk-rewrite";
        runtimeInputs = [
          pkgs.jq
          pkgs.rtk
        ];
        text = ''
          #!/usr/bin/env bash
          # rtk-hook-version: 4
          # RTK hook for Claude Code and Codex: rewrite commands for token savings.
          # Requires: rtk >= 0.23.0, jq
          #
          # This is a thin delegating hook: all rewrite logic lives in `rtk rewrite`,
          # which is the single source of truth (src/discover/registry.rs).
          # To add or change rewrite rules, edit the Rust registry — not this file.
          #
          # Exit code protocol for `rtk rewrite`:
          #   0 + stdout  Rewrite found, no deny/ask rule matched → auto-allow
          #   1           No RTK equivalent → pass through unchanged
          #   2           Deny rule matched → pass through (Claude Code native deny handles it)
          #   3 + stdout  Ask rule matched → pass through for normal approval

          INPUT=$(cat)
          CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

          if [ -z "$CMD" ]; then
            exit 0
          fi

          # Delegate all rewrite + permission logic to the Rust binary.
          # writeShellApplication adds set -e, so we must capture the exit code
          # via || to avoid aborting when rtk signals "no equivalent" (exit 1).
          EXIT_CODE=0
          REWRITTEN=$(rtk rewrite "$CMD" 2>/dev/null) || EXIT_CODE=$?

          case $EXIT_CODE in
            0)
              # Rewrite found, no permission rules matched — safe to auto-allow.
              # If the output is identical, the command was already using RTK.
              [ "$CMD" = "$REWRITTEN" ] && exit 0
              ;;
            1)
              # No RTK equivalent — pass through unchanged.
              exit 0
              ;;
            2)
              # Deny rule matched — let Claude Code's native deny rule handle it.
              exit 0
              ;;
            3)
              # Codex accepts updatedInput only with permissionDecision: allow.
              # Keep approval-gated commands unchanged instead of granting them.
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac

          ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
          UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

          # Rewrite only when RTK's permission check allows the command.
          jq -n \
            --argjson updated "$UPDATED_INPUT" \
            '{
              "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "RTK auto-rewrite",
                "updatedInput": $updated
              }
            }'
        '';
      };
    };
}
