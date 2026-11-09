# Lichii package and updates

`packages.x86_64-linux.lichii` builds Lichii from the non-flake `lichii` input.
The input targets the upstream `nx2` development branch, but `flake.lock`
selects an exact revision and NAR hash. It does **not** automatically follow HEAD.
The package is not installed on any host by this module.

## Current source and release reference

- Official repository: <https://github.com/zortos293/Lichii>
- Development branch: `nx2` (not `master`).
- Source revision: `cbb512ee7a9de9d9dbe2f865ec2e468888503214`.
- Source NAR hash: `sha256-kHXFnYkvuNjorCKvfhvMI9x12hfpUx4OeTVtEo1GUqQ=`.
- Matching release reference: `build-125`, a prerelease.
- Official non-PGO reference asset: `lichii-linux-x86_64.AppImage` from
  <https://github.com/zortos293/Lichii/releases/tag/build-125>.
- Independently verified reference payload: 111946232 bytes;
  SHA-256 `877d8b9e00b809b2ea643b7862df319cdcc5a5e8d43bff3630f0acef3a586b74`.

The AppImage hash is **not** the source input's NAR hash. This package compiles
`inputs.lichii`; it does not install the reference AppImage. A source revision
matching a release does not imply byte-identical binaries or game compatibility.
Only use the official repository; upstream warns against unrelated download sites.

## Deliberate update procedure

1. Start in an isolated infra worktree and inspect `git status --short`.
   Preserve unrelated changes and record the existing lock graph.
2. Query the official repository's `nx2` HEAD (for example,
   `git ls-remote https://github.com/zortos293/Lichii.git refs/heads/nx2`).
   Record the full commit SHA; never infer HEAD from the latest stable release.
3. Inspect recent official releases, including prereleases. Resolve their tags
   to commits and compare with the recorded branch HEAD. If no release matches,
   explicitly report **release assets lag nx2 HEAD**, including both SHAs.
   Continue with a reviewed source build at the chosen HEAD, or stop for a
   decision; never silently substitute an older binary. An AppImage wrapper,
   if separately introduced later, would remain pinned and would not follow HEAD.
4. If checking a release asset, download the matching build's exact official
   asset and independently compute its payload hash and size. Compare with
   published metadata. Never carry over a previous build's hash or confuse it
   with a source NAR hash.
5. Keep the input declaration in `modules/gaming/lichii.nix`; do not hand-edit
   generated `flake.nix`. If the declaration changes, stage new source files
   and run `nix run .#write-flake`. Update **only** the `lichii` input
   (`nix flake update lichii`), and verify `flake.lock` records the selected
   exact revision and NAR hash. If HEAD moved during the update, reconcile it
   explicitly rather than accepting an unreviewed commit.
6. Inspect upstream `cpmfile.json`, patches, CMake download paths and dependency
   gitlinks. Update local fixed-output dependency sources as needed. Keep
   required submodules pinned; do not enable configure-time downloads or CI
   binary fallbacks. Do not update nixpkgs or other lock nodes incidentally.
   Review the semantic lock diff: only the intended `lichii` node/root edge
   may change. Update the version/build metadata and this reference record.
7. Delegate a scoped `nix build --no-link .#packages.x86_64-linux.lichii` through
   `agent-run-long` (see `docs/skills/agent-run-long/SKILL.md`). Verify the package
   consumes `inputs.lichii`, package/check identity, metadata and runtime library
   resolution. Do not run a full flake or host build for this package update.
8. Smoke-test only noninteractive CLI help/version with fresh temporary HOME
   and all XDG directories, empty working directory, no display/DBus sockets,
   and network isolation. Upstream initialization can write configuration even
   for help/version. Never point tests at real Eden/Lichii data.
9. Run repository hooks, review generated files and lock scope, and commit the
   logical change using Conventional Commits. Report exact pins, validation
   results and limitations. No activation, deployment or push is part of this
   procedure.

## Runtime boundaries

The updater is disabled at source build time; updates are managed through Nix.
Upstream retains Eden's XDG configuration/data locations. Normal application
launches can therefore access existing emulator data; the package is not a
security sandbox or a data migration. It provides no firmware, keys, ROMs,
save configuration, host enablement, or gameplay verification.
