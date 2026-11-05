---
name: commit
description: Use when staging or committing changes in the infra repo. Covers generated files, staging scope, Conventional Commits, and recovering from pre-commit hooks that rewrite files.
---

# Committing in infra

The pre-commit hooks (git-hooks.nix, installed by the dev shell) are
`00-generate-files` (runs `nix run .#generate-files`, which rewrites
`files.file` outputs such as `README.md`, `.gitleaks.toml`, and `flake.nix`),
`treefmt` (formats files), trailing-whitespace, end-of-file, and
mixed-line-ending fixers, shebang and large-file checks, and `gitleaks`. Hooks
that rewrite files make the commit fail. Expect this and recover as described below.

## Steps

1. Inspect `git status` and `git diff`. Identify which changes belong to
   your logical change. Leave unrelated user changes unstaged.
2. Stage new files explicitly with `git add PATH`. Git-backed flakes ignore
   untracked files, so evaluation and generation will not see them.
3. If you changed `flake-file` declarations or `text.readme`/`files.file`
   sources, run `nix run .#generate-files` and review its diff. Never
   hand-edit `flake.nix` or `README.md`.
4. Stage only the paths for this change, including the generated outputs it
   caused. Do not use `git add -A` or `git commit -a`.
5. Commit with a Conventional Commit:
   `type(scope): imperative summary`
   - types: feat/fix/refactor/perf/docs/test/build/ci/chore/revert
   - scope: a host or module, e.g. `link`, `iot`, `ai`, `minecraft`,
     `observability`
   - write the header in lowercase, with no trailing period and at most 72 characters
   - explain the reason in the body when it is not obvious; mark breaking changes with `!` or
     `BREAKING CHANGE:`
6. If a hook fails after modifying files, run `git diff` to review the edits. Re-stage
   only the files that belong to this change, then retry the commit once. If it
   fails again, or `gitleaks` flags something, stop and report the problem.
7. Never use `--no-verify`, and never skip or disable hooks.

## Stale hooks (direnv)

The dev shell's `shellHook` installs the hooks and points
`.pre-commit-config.yaml` at a Nix store path. After the hook definitions,
`flake.lock`, or nixpkgs change, the installed hooks can go stale until the
shell is re-entered. Signs of stale hooks: a hook is missing or outdated,
`.pre-commit-config.yaml` points at a store path that doesn't exist or was
garbage-collected, or you see `pre-commit: command not found`.

Fix (from the repo root): run `direnv reload && direnv exec . true` to
invalidate and load the environment, reinstalling the hooks. Keep stderr
visible and resolve errors or fallback warnings before proceeding. Check
that `.pre-commit-config.yaml` resolves to the expected hook configuration,
then retry with `direnv exec . git commit ...`. Environment updates in one
tool call do not propagate to later calls. Do not bypass the hooks.

Make one logical change per commit. Split unrelated changes into separate commits.
