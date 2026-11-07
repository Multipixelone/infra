# CommuteCompass offline regression tests

These tests evaluate the real Nix contributors and import **Home Assistant
2026.10.2** from the installed `finalPackage` wrapper. They do not run an HA
server or daemon, load private commute settings, connect to devices, or deploy.
The runtime lane merges `homeassistant.nix`, `commutecompass-alarm.nix`,
`commutecompass-wake-window.nix`, `meds-reminder.nix` and `dashboard-home.nix` using `lib.evalModules`.
It intercepts only Nix YAML/TOML file generation and outbound device services.
Helper integrations, validators, Jinja, Script execution and trigger handling
are the pinned HA implementation.

## Reproduce

From the worktree root, first resolve the installed closure:

```sh
agent-run-long --label commute-test-package --timeout 5m -- \
  nix eval --offline --impure --json --expr \
  'let f = builtins.getFlake (toString ./.); in { nixpkgs = toString f.inputs.nixpkgs.outPath; package = f.nixosConfigurations.iot.config.services.home-assistant.finalPackage.outPath; }'
```

The closure used during implementation is:

- HA: `/nix/store/a1f50c1hahn3gmyfdm7rnw9yfyisgihz-homeassistant-2026.10.2`
- Python: `/nix/store/xahxrjs30p3mw0a42bqg9ikgkikskw8m-python3-3.14.8/bin/python3.14`
- nixpkgs: `/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source`

```sh
agent-run-long --label commute-runtime --timeout 5m -- \
  /nix/store/xahxrjs30p3mw0a42bqg9ikgkikskw8m-python3-3.14.8/bin/python3.14 \
  modules/iot/tests/commute_runtime_test.py \
  --ha-package /nix/store/a1f50c1hahn3gmyfdm7rnw9yfyisgihz-homeassistant-2026.10.2 \
  --nixpkgs /nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source
```

Use `--capture-only` to check Nix capture separately; `--test TEST_METHOD`
(repeatable) selects focused harness cases while writers are still working.
Do not interpret a selected case pass as the complete lane passing.
The shell tool's outer timeout must be at least 360000 ms for a 5m helper run.

`commute_controls_test.py --baseline 678a54d6b --ha-package <HA>` retains the
original first-button regression comparison and uses the real pinned YAML
serializer. Its unrelated dashboard and fallback/confirmation/Clock assertions
remain strict; wake-window-specific changes are checked in the runtime lane.

Link configuration is captured with a synthetic temporary `config.toml`; no real
origin or token is evaluated or printed. To catch effective lead divergence the
runtime tests derive L from the captured effective link alarm lead and exercise
the actual generated HA ownership boundary at L-70 and one second earlier, then
check the real 600-second fade. This detects effective lead divergence rather
than merely checking that both sources import one constants file.

## Explicit manual snooze policy

The deployed path remains `script.commute_publish_alarm` (legacy); this infra
tree does not install the app's optional v1 schedule relay. The publisher receives
an already-computed **first** `wake_at`, exact final `deadline_at`, and optional
integer `manual_snoozes` (0–12). It must not subtract the interval again. For
three snoozes ending at 10:00, first ring is 09:40:30 and the existing ten-minute
light fade starts at 09:30:30. The interval is exactly 390 seconds.

`input_text.commute_manual_wake_policy` restores across HA restarts, with no
`initial`, and stores raw JSON with exactly `wake_at`, `deadline_at`, and
`snoozes`. Its UTC pair must match the authoritative UTC helpers and satisfy
`deadline - wake = snoozes × 390 seconds`. Omitted/empty counts clear policy;
invalid counts or geometry must mutate no helpers. Rollover preservation applies
to the pair and policy together. A temporary `publishing` marker blocks pending
acquisition while the serialized pair writes are in flight; interruption leaves
it unknown until a successful retry commits policy. Unknown/malformed/mismatched
policy is not permission for a speculative pending light fade. Active daemon sessions remain
authoritative, including zero-length final windows.

New runtime cases cover native service-data JSON typing, counts 0/1/3/12,
validation before mutation, policy clearing and rollover, stale policy gates,
second-precision fade timing with real restore-file restart, and zero-final
phone/lighting/desktop completion. The full 36-case runtime lane passed against
HA 2026.10.2 (exit 0, 105.480 seconds) on the reconciled integration based on
`c40f10c7e`, using local app `0336257` for the separate real-module evaluation.
The log is `/tmp/opencode/agent-run-long.commute-final-runtime.VnnjaSrJBu/output.log`.
These offline results do not establish deployment or audibility.

The real iot/link/app scoped evaluation also passed with `--no-write-lock-file`
and a local input override. Its non-secret result is
`/tmp/opencode/commute-validator/real-scoped-modules.json`; the exact evaluation
expression is preserved in `scoped-apply.nix` alongside it. This verifies the
real app module/package source, daemon and timer, legacy contract, effective
60-minute default lead and 17-minute calendar/fallback advance, and generated
policy helper/publisher. The runtime capture itself uses synthetic app settings.

Nix formatting, Ruff lint, Python compilation, Markdown formatting and deadnix
passed. Two existing lint findings were reproduced against baseline sources:
Nixf's `builtins.removeAttrs` warning in the copied link edit, and Statix's
repeated dashboard `services` keys. They were not silently repaired as part of
this feature. Full infra checks and host builds remain CI work; no live HA
instance or devices were contacted.

The copied input pin is still `3fa0c8d`, predating app commit `0336257` with this
feature. Offline integration should use the local app input override; do not
commit a local filesystem path or treat the existing pin as activation-ready.
A portable compatible app revision must be published and pinned separately
before rollout. Existing `prep_advance_minutes = 17` is preserved for calendar
and fallback only, never subtracted from explicit manual deadlines.

## Known coverage limitations

- The generated `commute_wake_bootstrap` custom component (HA
  `restore_state.async_get(hass).last_states`, no filesystem parsing) is
  realised from Nix and set up against real `.storage/core.restore_state`
  files by the mechanism-specific `test_startup_bootstrap_owner_ledger`:
  native unknown with no saved owner entry (no file, unrelated entries only,
  unreadable file moved aside by HA) initialises to `v1:{}`; any saved entry
  (`v1:{}`, held, unknown, unavailable, blank, corrupt) is retained verbatim;
  a repeated setup never mutates; recovery mode is a no-op; a restart keeps
  the initialised ledger. It skips when no bootstrap integration is
  generated. Run it alone with `--test test_startup_bootstrap_owner_ledger`
  or exclude it with `--exclude test_startup_bootstrap_owner_ledger`. The mechanism-independent
  requirement (no manual `v1:{}` on first install; restart keeps the ledger)
  is covered by the first-install/restart and start-trigger tests. Lifecycle tests arm the
  generated `commute_alarm_wake_reconcile` / `commute_alarm_phone_action`
  automations before `hass.async_start`, so the real `homeassistant: start`
  trigger fires on (re)start; `Runtime.tick()` advances the patched clock and
  fires HA's due `time_pattern` timers. Other tests call
  `script.commute_alarm_reconcile` directly.
- The daemon is not run; status/terminal payloads are synthetic fixtures matching
  the commutecop `alarm-ha-contract.md` schema. Terminal `reason` values follow
  the pinned daemon (`adfc665`, `_cancellation_reason`: `schedule_cleared`,
  `schedule_replaced`), not the newer commutecop HEAD. A full second-ring lifecycle and
  daemon-side snoozed state are only represented by fixture transitions.
- Device services (WLED, notify, media) are intercepted; real device behaviour,
  Companion app delivery and HA HTTP/frontend rendering are out of scope.
