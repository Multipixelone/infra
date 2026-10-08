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
