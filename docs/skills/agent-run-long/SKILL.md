---
name: agent-run-long
description: Use before executing long builds, tests, or Nix validation on Linux. Provides the canonical agent-run-long invocation, timeout headroom, captured-output behavior, and reporting requirements.
---

# `agent-run-long`

Use this skill before executing a long build, test, or Nix validation on Linux.
`agent-run-long` is a Linux-only, synchronous v1 helper: it is not
`systemd-run`, an MCP service, or an asynchronous job API.

## Invocation

```text
agent-run-long --label NAME --timeout NUMBER[s|m|h] [--excerpt-lines 0..80] -- COMMAND [ARG...]
```

- `--label` and `--timeout` are required. The timeout must use an `s`, `m`, or
  `h` suffix and may not exceed 24 hours.
- `--excerpt-lines` is optional and accepts 0 through 80 lines.
- `--` is required. Everything after it is literal command argv; the helper
  does not parse, interpolate, or run it through a shell.

The helper runs synchronously, gives the command no interactive stdin, and
captures output rather than live-streaming it. It atomically creates a private
run directory under `/tmp/opencode` with output and status files.

## Timeouts and wrappers

Use the helper without `time`, `tee`, or another logging/timing wrapper: it
owns logging, timing, status, bounded excerpts, and ordinary cleanup.

Set the harness's outer control timeout at least 60 seconds beyond the inner
helper timeout. In OpenCode's Bash tool, that outer timeout is milliseconds:
for `--timeout 30m`, set at least `1860000` milliseconds. Other harnesses must
also give their outer control at least 60 seconds of headroom.

Examples:

```bash
agent-run-long --label nh-os-build-link --timeout 30m -- nh os build -H link
agent-run-long --label nix-build-example --timeout 30m -- nix build --no-link .#packages.x86_64-linux.example
```

Avoid pipelines for validation. If one is unavoidable, pass an explicit shell
after `--`; its pipeline exit-status behavior is then that shell's behavior and
can obscure failures or complete output.

## Status, signals, and reporting

The helper returns the command's exit code when the command runs. `125` means
helper setup failed. Raw `124` is commonly associated with GNU `timeout`, but
is not unambiguous: a child command can itself return `124`. Consult the status
artifact and report context rather than treating that value alone as proof of a
timeout.

Before runner initialization, a direct signal termination can produce the
platform's signal status and no artifacts. After the runner announces its log
and is ready, mapped interruption and status cleanup applies. Do not claim that
the helper survives a hard caller kill or cleans up outside its ordinary process
group; daemonized children, Nix daemon or remote jobs, and uninterruptible tasks
may require separate inspection and cleanup.

Report the command, exit code, duration, pass/fail, smallest actionable
excerpt, and log path. Keep full validation delegated to background fixers; if
delegation is unavailable, report that limitation.

## Privacy and retention

The private files can still contain secrets. Never upload logs automatically.
They remain until manually removed or `/tmp` is cleared, so do not rely on them
for durable storage. The helper makes no FHS assumptions.
