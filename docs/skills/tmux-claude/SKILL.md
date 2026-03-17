---
name: zellij
description: zellij terminal multiplexer configuration, key bindings, pane/tab/session management, and command orchestration in this infra repository.
tools: Bash, Read, Grep, Glob
---

# Zellij Configuration and Usage

## Overview

This repository uses **zellij** (not tmux) as the primary multiplexer.

Repository-specific implementation lives in:

- `modules/shell/zellij.nix` (program enablement + keybinds + layout)
- `modules/shell/fish/fish.nix` (tab renaming hooks and mode transitions)
- `modules/shell/helix.nix` (Helix popup execution through `zellij run`)

## Core Concepts

| Concept      | Description                                              |
| ------------ | -------------------------------------------------------- |
| Session      | Top-level zellij workspace, attachable/detachable        |
| Tab          | Workspace inside a session                               |
| Pane         | Split terminal in a tab                                  |
| Mode         | zellij input mode (`normal`, `locked`, etc.)             |
| Plugin panel | Embedded panel (eg `zjstatus`, `zjstatus-hints`, monocle) |

## Environment Detection

Always detect context before using pane/tab actions:

```bash
if test -n "$ZELLIJ"
  echo "Inside zellij"
else
  echo "Not inside zellij (actions may fail)"
end
```

## Session Operations

```bash
# list sessions
zellij list-sessions

# attach to session
zellij attach <session-name>

# create or attach named session
zellij -s <session-name>
```

## Repository Keybindings (from `modules/shell/zellij.nix`)

### Shared bindings

| Binding           | Action            |
| ----------------- | ----------------- |
| `Ctrl-Tab`        | Next tab          |
| `Ctrl-Shift-Tab`  | Previous tab      |
| `Alt-Enter`       | New pane to right |
| `Alt-Shift-Enter` | New pane below    |
| `Alt-Shift-Q`     | Close focused pane|

### Extra shared-except-locked binding

| Binding | Action |
| ------- | ------ |
| `Alt-m` | Launch monocle plugin in-place and return to normal mode |

## AI Workflow Commands

When already inside zellij, prefer `zellij action ...`:

```bash
# split for diff/log work
zellij action new-pane right
zellij action new-pane down

# rename tab while focusing task
zellij action rename-tab "diff"

# return mode to normal after scripted actions
zellij action switch-mode normal
```

Common command-run pattern in a new floating pane:

```bash
zellij run -c -f -x 10% -y 10% --width 80% --height 80% -- jj diff
```

(This exact style is used by Helix in `modules/shell/helix.nix`.)

## Fish Integration Behavior

`modules/shell/fish/fish.nix` wires zellij-specific hooks:

- On `fish_preexec`: rename tab to command name
- If command is `hx`: switch mode to `locked`
- On `fish_postexec`: switch back to `normal`
- On `z` command completion: rename tab to `prompt_pwd`

This means tab names and mode behavior are intentionally dynamic during interactive work.

## Where to Edit Zellij Behavior

| Need | File |
| ---- | ---- |
| Enable/disable zellij | `modules/shell/zellij.nix` |
| Keybindings and plugin config | `modules/shell/zellij.nix` |
| Status line plugin wiring | `modules/shell/zellij.nix` |
| Fish tab-name automation | `modules/shell/fish/fish.nix` |
| Helix popup terminal behavior | `modules/shell/helix.nix` |

## Investigation Checklist

For any "zellij is doing X" question:

1. Confirm inside zellij (`$ZELLIJ` set).
2. Check keybinds and plugin config in `modules/shell/zellij.nix`.
3. Check fish event hooks in `modules/shell/fish/fish.nix`.
4. If behavior occurs from Helix command launches, inspect `modules/shell/helix.nix`.
