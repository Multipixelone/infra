# Agent traps

- Never manually edit `flake.nix`: change `flake-file` declarations in modules, then run
  `nix run .#write-flake`.
- `README.md` is generated from `text.readme` contributions. Edit its Nix
  sources instead. `nix run .#generate-files` rewrites all `files.file` outputs
  and `flake.nix`; pre-commit also runs this generator, so review its diffs.
- Stage new source files before evaluation or regeneration. Git-backed flakes
  exclude untracked files even when imports discover files automatically.
- Keep input follows explicit. Do not reintroduce `allfollow` or
  `nix-auto-follow`; they caused lock churn.
- Never run `nix build` without an explicit installable, and never run
  `nixos-rebuild`.
- For boot logs on any systemd host, run `sudo journalctl --list-boots` on the affected machine, then `sudo journalctl -b BOOT_ID -o short-monotonic > ~/boot-debug.log` (add `-k` for kernel-only logs); persistent journals live in `/var/log/journal` when enabled, but very early freezes may leave no saved log.
- Leave full checks to CI by default. If local long-running or full validation
  is needed, delegate each validation task to a background `@fixer` and follow
  the inherited `agent-run-long` skill. Run it in the orchestrator foreground
  only when explicitly requested. If delegation is unavailable, report the
  limitation rather than silently running it there.
- `~/.ssh/colmena` is deliberately outside Nix and agenix. A rebuild restores
  SSH configuration, not this private key. Rotate it with overlapping public-key
  authorization until the new key works on every node.

## Grafana investigations

- When investigating a firing alert in this infrastructure, use Grafana to
  inspect the alert state and relevant metrics for the affected service and
  time range; inspect logs where relevant. Do this before presenting a diagnosis,
  and do not base conclusions solely on static configuration or assumptions.
  If Grafana access or required data is unavailable, state the limitation and
  clearly distinguish hypotheses from verified findings.
