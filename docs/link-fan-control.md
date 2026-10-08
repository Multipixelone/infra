# Link fan control and cooler ARGB

On 2026-10-07 the NZXT Kraken Z63 was replaced by a Thermalright Peerless
Assassin 120 SE ARGB. Its two PWM fans share CPU_FAN and expose one PWM channel
and one tachometer reading. The former radiator fans are now front intakes.
The NZXT Smart Device 2 remains installed; fan 2 read 0 RPM during inspection.
Check its wiring before assuming that a fan is connected or calibrating it.

## Driver and evidence

Read-only inspection on link confirmed X570 AORUS ELITE WIFI, BIOS F40,
kernel 7.2.7-zen1, `acpi_enforce_resources=lax`, CPU Tctl about 58 °C,
`gigabyte_wmi` temperatures, and `nzxtsmart2` fan readings of 732/0/931 RPM.
There was no motherboard fan hwmon device. The running in-tree it87 module
contains IT8792 support but no IT8688 device entry.

The [upstream board table](https://github.com/frankcrawford/it87/blob/a9eb2495220cba861ef3df63fa15265e878293b6/it87.c)
identifies this board as IT8688E (`0x8688`). **This is inferred, not a live chip
identification.** A secondary IT8792E/IT8795E (driver device ID `0x8733`) is not
confirmed. Chip model numbers are not always their raw device IDs. The inspection
environment had no `/dev/port`; existing hwmon entries and boot logs did not
identify the Super I/O chips.

Link uses the out-of-tree driver from
[commit c567739](https://github.com/frankcrawford/it87/commit/c567739c639533177abd66894a6a8d561337285f),
with Gigabyte manual-control fixes, built against link's configured zen kernel.
The exact module configuration is `options it87 mmio=1`: keep upstream's
DMI/SIV-gated MMIO workarounds enabled. No `force_id`, `fix_pwm_polarity`,
`update_vbat`, or additional resource-conflict override is set. The existing
ACPI kernel parameter is retained. A guessed force ID can use the wrong
register layout; polarity correction can invert fan duty. Neither is a remedy
for a detection failure.

After a separately authorized activation/reboot, inspect `journalctl -k -g it87`
and `/sys/class/hwmon/*/name` to record the actual chip IDs/revisions and exposed
fan/PWM channels. A successful module build proves ABI compatibility, not
correct physical fan control. Firmware and Linux may still contend for the
controller despite relaxed ACPI resource enforcement.

## Curves and calibration

CoolerControl 5.0.1 stores profiles/functions in writable
`/etc/coolercontrol/config.toml`, not a UI-only database. Its NixOS module has
only an enable option. A read-only store symlink is not supported: the daemon
checks writeability and saves its device list, profiles and UI changes.
`link-cooling-config` reconciles the Nix-owned profiles before each daemon
startup, retaining other configuration. Existing files get private
`.pre-link-nix` backups on their first change. The helper removes the departed
cooler's mapping, LCD/lighting settings and UI references. The stale Facter
USB interfaces are removed too; generic liquidctl support and Smart Device 2
remain. No live configuration is edited by building this change.

| Profile | Temperature °C → duty % |
| --- | --- |
| CPU cooler / Tctl | 30–50 → 30; 60 → 50; 70 → 75; 80 → 100 |
| Case / Tctl | 30–50 → 30; 60 → 45; 70 → 70; 80 → 100 |
| Case / GPU edge | 30–45 → 30; 55 → 45; 65 → 70; 80 → 100 |

Case fans use the **maximum duty** from the CPU and GPU graphs, rather than
averaging temperatures. The Standard function delays only decreases (5 s,
2 °C deviance), allowing fast increases. Its duty minimum/maximum fields are
step sizes; the graphs supply the 30% non-stopping floor. Adjust
`link.cooling.{cpuCurve,caseCpuCurve,caseGpuCurve}` in Nix after calibration;
UI edits to these named `(Nix)` profiles are replaced at the next daemon start.
The Tctl and GPU edge source UIDs match the inspected configuration and can be
updated with `link.cooling.{cpuSource,gpuSource}` after hardware replacements.
GPU fan assignments, curves and functions are preserved; only its obsolete
"AIO Radiator" profile label is renamed.

After activation, open CoolerControl → Controls → each identified fan channel
→ Device Channel Settings → RPM Calibration, then select and apply
`CPU cooler (Nix)` to CPU_FAN and
`Case CPU/GPU max (Nix)` to connected front/rear Smart Device and SYS_FAN channels.
The observed Smart Device fan1/fan2 radiator assignments migrate to the case
profile; other channels need this one-time assignment. Identify channels from
wiring/readings before calibrating; the CPU splitter cannot report both fans.
Raise curve floors above the measured reliable start/run duty. Calibration
changes speeds and belongs to later commissioning, not this build task.

Keep BIOS cooling enabled until correct control and startup behavior are
verified. Missing assignments do not install a fallback curve; a failed daemon,
missing temperature source, or firmware override can leave a manual fan at its
last speed. No independent hardware failsafe is claimed. The reconciler rejects
malformed or symlinked files before writing and fails startup rather than
silently resetting configuration. Inspect `journalctl -u coolercontrold` if it
fails, and recover from the private backups with the daemon stopped.

## Cooler ARGB

The user confirmed the cooler is connected to **D_LED1 bottom**, with shared
data through a splitter. Use **six logical LEDs**, mirrored across both fans;
two parallel six-LED fans are not a twelve-pixel serial chain. Adjust
`link.coolerArgb.ledCount` if the fan variant or wiring changes.

Live USB sysfs identifies the motherboard controller as `048d:8297`
(`ITE Device(8595)`); today's OpenRGB server log registers
`X570 AORUS ELITE WIFI`. The board's D_LED headers are zones of this USB
controller, not independent USB fan devices. Existing OpenRGB udev rules cover
8297 with `uaccess`; no additional broad permissions are needed. Smart Device 2
is still USB `1e71:2006`; the removed Kraken's `1e71:3008` is absent.

LedFx already uses the OpenRGB SDK at localhost:6742. Before its user service
starts, `link-argb-config` locates the motherboard and `D_LED1 Bottom` by name,
resizes only that zone, resolves the current controller index, and adds its
pixels to the existing `top-front-fan` virtual. The cooler follows that
virtual's existing effect; changing the effect also changes the cooler. Other
motherboard segments are remapped around the new strip and overlapping writes
to the strip are removed. No other device's index, effect, color or fan control
is configured. LedFx selects Direct mode during device activation.

The helper keeps writable `~/.ledfx/config.json` and a checkpoint in
`~/.ledfx/link-argb-layout.json` so offsets survive server restarts and interrupted
configuration updates. Initial originals are backed up privately. A missing or
ambiguous device/zone, malformed configuration, or missing existing front-fan
virtual fails LedFx startup with a journal error instead of guessing a mapping.
Check `journalctl --user -u ledfx` if that happens. The helper does not launch a
second OpenRGB scanner or write fan controls. Hardware effects require the
existing LedFx graphical-session service to be running.

For a visual count check after later activation, connect the OpenRGB GUI to the
existing SDK server → `X570 AORUS ELITE WIFI` → `D_LED1 Bottom` → Resize → 6 LEDs.
Check that all six addresses illuminate both fans. Keep the matching count in
Nix; a manual resize is restored by the helper at the next LedFx startup. Do not
run a separate standalone detector against a controller already owned by the
server. If only one fan responds, inspect its ARGB cable before changing counts.
