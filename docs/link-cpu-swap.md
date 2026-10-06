# Link: Ryzen 9 5900XT swap

Keep this branch parked until Finn finishes burning in the replacement CPU.
No deployment, activation, merge, or push is part of preparing it.

`link.cpu.threads` defaults to 32. Nightly xtractor uses 12 workers at 800%
CPUQuota; embedding uses 4 threads at 400%. Both run as tunnel in the system
manager's `batch-beets.slice`, a direct child of `batch.slice`, with a default
aggregate quota of 1200% and CPU/IO weights of 10. The aggregate
quota follows the two job quota options and may be overridden through
`services.beets.nightly.cpuQuotaPercent`. `memoryHigh` defaults to null until
measured. These quotas limit CPU time, not reserved cores or guaranteed
interactive headroom; the GPU embedding load is outside the CPU budget.

Import xtractor gets 5 workers, conversion/ReplayGain 8 each, and Euphony 4,
derived from the host capacity. Host Nix keeps max-jobs=auto and cores=0;
CI's existing job/core and memory budgets stay unchanged. GameMode's CI fence
now selects two complete online physical cores from runtime topology.

System `batch.slice` has CPUWeight=20 and IOWeight=20. Its `batch-ci.slice`
child contains the Forgejo runner and retains the 8G/12G memory thresholds;
`batch-nix.slice` contains nix-daemon and its builders without those memory
limits. Neither batch nor the Nix child has a CPU quota: idle builds can use
the whole CPU. GameMode fences the CI and Nix children to two complete physical cores
and sets their weights to 1, then clears the masks and restores CI weights
to 20 and Nix weights to 100 on exit. The nightly jobs share `batch-beets.slice`;
one slice is sufficient for their common quota and target, so there is no
intermediate Beets parent. Backfills retain their quota and low weights without
joining the gaming affinity fence. Album export and user-manager units are not moved.

Sandboxed builders inherit nix-daemon's cgroup. If Nix's `use-cgroups` setting
is enabled, its per-build cgroups remain descendants of the daemon service,
inside `batch-nix.slice`. Daemon delegation is enabled when `use-cgroups` or
the `cgroups` experimental feature is enabled; this change enables neither.

ucodenix uses automatic CPU/stepping selection and still provides early AMD
microcode loading. Active amd_pstate stays enabled. Idle policy is powersave
plus balance_performance EPP; GameMode selects performance and reapplies idle
EPP on exit. There is no explicit build boost or competing power manager.
The separate Limine boot-debug entry stays available.

## Nightly controls and eventual migration

The nightly jobs retain their 01:00 America/New_York schedule, wall-clock cutoff,
per-job quotas, kill escalation, and private scratch handling. Xtractor keeps
its shared import lock, DB-only analysis, and read-only music sandbox; it can
write its SQLite state, import lock, and disposable analysis output. Embedding
keeps its own sandbox and GPU access.

Before Finn eventually activates this generation, stop the old user units so
an old xtractor process or timer cannot overlap the new system units:

```console
systemctl --user stop beets-xtractor-backfill.timer beets-xtractor-backfill-stop.timer beets-xtractor-backfill.service beets-xtractor-backfill-stop.service
```

The updated Home Manager configuration removes those user units. Subsequently:

```console
sudo systemctl start beets-nightly-now.target
sudo systemctl stop beets-nightly-now.target
sudo systemctl status beets-nightly-now.target batch-beets.slice
```

Let existing Nix builds finish before eventual activation relocates the daemon
to its new slice; old connection-handling processes can outlive a daemon restart.

`beets-nightly-now.target` starts both enabled backfills immediately, at any
hour. Its workers are `beets-xtractor-backfill-now.service` and
`beets-embed-backfill-now.service`; starting either also pulls in the manual
group. Both share the same `batch-beets.slice`, default 1200% aggregate quota,
per-worker CPU and memory limits, sandboxing, and import/store locking as their
nightly counterparts. Manual embedding uses a separate 2 GiB `noswap` scratch
tmpfs at `/run/beets-embed-now-tmp`, with the same persistent GPU cache.

Manual xtractor has an eight-hour elapsed budget. Manual embedding uses
`services.beets.embedBackfill.budgetHours`, also eight hours by default. Both
reserve the final minute for shutdown escalation. Manual work can finish early
and has no 08:59 wall-clock cutoff; the nightly cutoff timers address only the
nightly services.

The existing `beets-nightly.target` and unsuffixed worker services remain
window-gated: directly starting them outside 01:00–08:59 America/New_York skips
work. This explicit separation makes the CLI show whether a run is manual or
scheduled, without environment overrides or timer-trigger detection.

A shared mode lock keeps an active run in place: both workers of the same mode
may run concurrently, while workers of the other mode log a skip and exit
successfully. Scheduled starts therefore skip while manual work is active, and
manual starts skip while nightly work is active. Skipped work is not queued;
retry after the active run finishes, or explicitly stop its target first.
Admission locks live under `/run/beets-backfill-locks`; do not remove these
files while workers are running. The existing import and embedding-store locks
remain in effect too.

Stopping either target stops its workers and leaves the next-night timers
enabled; stop both start timers too to suspend scheduling. A job finishing or
failing does not stop its sibling. Each target becomes inactive when neither
worker needs it. Nightly cutoff timers still stop each nightly job before 09:00,
including after resume. Existing embedding-store revalidation guidance remains
a separate manual operation; these controls reset no real data.

## Finn's BIOS and firmware actions

- Confirm the physical board revision and installed BIOS support the 5900XT.
  The captured report records X570 AORUS ELITE WIFI / F40; verify the current
  CPU support list at [Gigabyte](https://www.gigabyte.com/us/Motherboard/X570-AORUS-ELITE-WIFI-rev-1x/support).
  BIOS/AGESA support is needed before Linux microcode can help; no minimum
  version is guessed here.
- Enable/confirm CPPC for active amd_pstate. Keep PBO Auto and Curve Optimizer off.
- Keep XMP off for the first few days, then re-enable it after stable burn-in.
- SVM is currently off. Enable it only if virtualization is wanted; kvm-amd
  being configured does not enable SVM in firmware.

## Post-swap verification

Follow Finn's existing plan: boot 5–6 times, scrub, and watch for hardware errors.

- Run `lscpu` and `lscpu -e=CPU,CORE,SOCKET,ONLINE`: expect 16 cores, 32 online CPUs.
- Record `cat /sys/devices/system/cpu/cpu0/microcode/version` and kernel microcode
  messages. Verify the replacement's patch loads; do not assume its stepping
  or revision matches the old report. Refresh Facter from actual hardware later.
- Check `cat /sys/devices/system/cpu/amd_pstate/status` is `active`. Check each
  cpufreq policy's `scaling_driver`, `scaling_governor`, and
  `energy_performance_preference`: amd-pstate-epp / powersave / balance_performance
  at idle and after normal or crashed-game cleanup; performance during GameMode.
  Inspect `systemctl status link-cpu-idle-policy` if restoration fails.
- On link, run `sudo journalctl --list-boots`, then capture each relevant boot:
  `sudo journalctl -b BOOT_ID -k -o short-monotonic > ~/boot-debug.log`.
  Inspect it with `rg -i 'microcode|amd.?pstate|mce|hardware error|edac' ~/boot-debug.log`.
  Require no MCE/Hardware Error/EDAC errors. Use boot-debug if needed; very early
  freezes may leave no saved journal even with persistent storage.
- Scrub each distinct btrfs filesystem: `sudo btrfs scrub start -B MOUNT` for
  `/`, `/nix`, `/volume1/Media`, and `/media/SlowData`; inspect
  `sudo btrfs scrub status MOUNT` and all error counters. Other subvolume mounts
  on the same filesystem do not need duplicate scrubs.
- After eventual adoption, confirm both nightly and manual workers report `Slice=batch-beets.slice`,
  the slice reports CPUQuotaPerSecUSec=12s (1200%), and target start/stop controls
  both workers in the selected mode. Watch temperatures via k10temp/hwmon and desktop responsiveness during
  concurrent work. Complete burn-in before un-parking this branch.
- After deploy, run `systemctl status batch.slice batch-ci.slice batch-nix.slice batch-beets.slice`
  and `systemctl show -p Slice -p ControlGroup forgejo-runner-link.service nix-daemon.service`.
  During an ordinary build, run `sudo systemd-cgls /batch.slice` and confirm
  the runner is under `batch-ci.slice`, and the daemon and build processes
  are under `batch-nix.slice`. If `use-cgroups` is enabled, expect
  `nix-build-*` descendants below `nix-daemon.service`. Inspect from the host:
  a sandbox's cgroup namespace may report its own cgroup as `/`.
  Verify both child slices' `AllowedCPUs` masks are cleared after GameMode exits,
  and their CPU/IO weights return to 20 for CI and 100 for Nix.
  During nightly work, confirm both backfill services are under the direct
  `batch-beets.slice` child, retaining its 1200% quota and CPU/IO weights of 10.
