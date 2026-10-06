# Link: Ryzen 9 5900XT swap

Keep this branch parked until Finn finishes burning in the replacement CPU.
No deployment, activation, merge, or push is part of preparing it.

`link.cpu.threads` defaults to 32. Nightly xtractor uses 12 workers at 800%
CPUQuota; embedding uses 4 threads at 400%. Both run as tunnel in the system
manager's `beets-nightly.slice`, with a default aggregate quota of 1200% and
low CPU/IO weights on that slice and its `beets.slice` parent. The aggregate
quota follows the two job quota options and may be overridden through
`services.beets.nightly.cpuQuotaPercent`. `memoryHigh` defaults to null until
measured. These quotas limit CPU time, not reserved cores or guaranteed
interactive headroom; the GPU embedding load is outside the CPU budget.

Import xtractor gets 5 workers, conversion/ReplayGain 8 each, and Euphony 4,
derived from the host capacity. Host Nix keeps max-jobs=auto and cores=0;
CI's existing job/core and memory budgets stay unchanged. GameMode's CI fence
now selects two complete online physical cores from runtime topology.

ucodenix uses automatic CPU/stepping selection and still provides early AMD
microcode loading. Active amd_pstate stays enabled. Idle policy is powersave
plus balance_performance EPP; GameMode selects performance and reapplies idle
EPP on exit. There is no explicit build boost or competing power manager.
The separate Limine boot-debug entry stays available.

## Nightly controls and eventual migration

Both jobs retain their 01:00 America/New_York schedule, wall-clock cutoff,
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
sudo systemctl start beets-nightly.target
sudo systemctl stop beets-nightly.target
sudo systemctl status beets-nightly.target beets-nightly.slice
```

Starting either worker also pulls in the group. Outside the nightly window,
launchers skip work. Stopping the target stops both jobs, but leaves their
next-night timers enabled; stop both start timers too to suspend scheduling.
A job finishing or failing does not stop its sibling. The target becomes
inactive when neither worker needs it. Cutoff timers still stop each job before
09:00, including after resume. Existing embedding-store revalidation guidance
remains a separate manual operation; this change resets no real data.

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
- After eventual adoption, confirm both workers report `Slice=beets-nightly.slice`,
  the slice reports CPUQuotaPerSecUSec=12s (1200%), and target start/stop controls
  both. Watch temperatures via k10temp/hwmon and desktop responsiveness during
  concurrent work. Complete burn-in before un-parking this branch.
