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

| Profile           | Temperature °C → duty %                |
| ----------------- | -------------------------------------- |
| CPU cooler / Tctl | 30–50 → 30; 60 → 50; 70 → 75; 80 → 100 |
| Case / Tctl       | 30–50 → 30; 60 → 45; 70 → 70; 80 → 100 |
| Case / GPU edge   | 30–45 → 30; 55 → 45; 65 → 70; 80 → 100 |

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
data through a splitter. Use **nine logical LEDs**, mirrored across both fans;
two parallel nine-LED fans mirror nine addresses rather than forming an
eighteen-pixel serial chain. Adjust
`link.coolerArgb.ledCount` if the fan variant or wiring changes. The earlier
six-pixel setting left the last LEDs orange on both TL-C12C fans; community
measurement reports nine LEDs per fan.

Live USB sysfs identifies the motherboard controller as `048d:8297`
(`ITE Device(8595)`); today's OpenRGB server log registers
`X570 AORUS ELITE WIFI`. The board's D_LED headers are zones of this USB
controller, not independent USB fan devices. Existing OpenRGB udev rules cover
8297 with `uaccess`; no additional broad permissions are needed. Smart Device 2
is still USB `1e71:2006`; the removed Kraken's `1e71:3008` is absent.

LedFx uses the OpenRGB SDK at localhost:6742. Before its user service starts,
`link-argb-config` reconciles device identities and virtual segments declared in
`modules/hardware/rgb.nix`. It uses SDK protocol 3, matching LedFx; protocol 4's
plugin-list request timed out during read-only inspection. It resizes only the
motherboard's `D_LED1 Bottom` / `D_LED1` zone, then uses refreshed zone offsets to
attach the cooler to `top-front-fan`. The cooler follows that virtual's existing
effect. The four onboard motherboard LEDs retain their order in their own
virtual. An existing six-pixel zone migrates to nine on the next LedFx start:
the cooler occupies pixels 0–8 and the four onboard LEDs move from 6–9 to 9–12.
The motherboard device therefore has thirteen pixels. Repeated starts with
this layout require no resize or config write. LedFx selects Direct mode
during activation.

### Device identities and inspection

Read-only SDK inspection on 2026-10-08 found seven controllers. The four Corsair
sticks have no serial; their stable identity is the PIIX4 port 0 bus description
at `0b00` plus addresses `0x58`, `0x59`, `0x5a`, and `0x5b`, respectively.
`/dev/i2c-N` enumeration is excluded from matching. The GPU is ASUS TUF Radeon
RX 7800 XT Gaming OC on AMDGPU DM i2c OEM bus at `0x67`. The motherboard has
serial `0x82970100`; NZXT Smart Device V2 has serial `00000000001A`. HID paths
are not pinned because `/dev/hidrawN` can change between boots. MK750, the Razer
bungee, and G502 were unplugged and remain optional declarations using their
existing names and expected counts of 127, 8, and 2.

The server's SDK list contains seven devices, with the motherboard at index 5
and NZXT at 6. The old G502/Razer indices pointed at these controllers. A CLI
list showed two identical blocks, but the server log recorded one detection
pass and the direct SDK confirmed seven controllers. No duplicate detection
was found in the server unit, and its existing configuration/udev rules remain.
For read-only inspection, use a protocol-3 Python SDK client, or
`openrgb --client 127.0.0.1:6742 --nodetect --noautoconnect --list-detailed`
when that CLI combination works. Never launch another local hardware detector.

### Editing declarations

Add a device in the LedFx UI first, then declare its **existing LedFx id** in
`link.ledfxOpenrgb.devices`. Use its exact SDK name and expected LED count, with
serial or stable I2C location where names collide. An exact `zoneSignature`
(name-to-count attribute set) is also available as an identity discriminator.
All supplied match fields must agree; unresolved or genuinely ambiguous devices
are left untouched, with a journal message. Exact duplicate SDK entries with
the same physical identity and zone layout select the lowest index and warn.
Multiple LedFx declarations cannot claim the same physical controller.

For example, a replacement RAM stick declaration looks like:

```nix
link.ledfxOpenrgb.devices.corsair-vengeance-pro-rgb = {
  match = {
    name = "Corsair Vengeance RGB Pro DDR4";
    vendor = "Corsair";
    location = {
      bus = "SMBus PIIX4 adapter port 0 at 0b00";
      address = "0x58";
    };
  };
  pixelCount = 10;
};
```

Declare each existing virtual's ordered segments in
`link.ledfxOpenrgb.virtuals`. Fixed ranges are inclusive; `reverse` defaults to
false. A `zoneNames` segment includes the entire uniquely matched zone and
tracks offsets after resizing. Use either a fixed range or a zone selector:

```nix
link.ledfxOpenrgb.virtuals.top-front-fan = [
  {
    device = "nzxt-smart-device-v2";
    start = 10;
    end = 17;
    reverse = true;
  }
  {
    device = "x570-aorus-elite-wifi";
    zoneNames = [ "D_LED1 Bottom" "D_LED1" ];
  }
];
```

The helper owns **only** declared OpenRGB devices' `config.openrgb_id` and
`config.pixel_count`, and declared virtuals' `segments`. For a declared virtual
whose successfully resolved segments overlap D_LED1, it also changes an existing
boolean `active: false` to `true`; this fixes the observed inactive
`top-front-fan` without altering unrelated virtuals. Missing activation fields
already let LedFx restore the saved effect and are left untouched. Invalid
activation fields and virtuals with unresolved segments are left untouched.
UI edits to these owned fields reset at the next LedFx start. Names, ports/IPs,
effects, colors, presets, scenes, playlists, startup selections, virtual settings,
integrations, and every other field retain their exact bytes, including global
pause state. The helper does not create missing devices/virtuals or choose a
default scene/effect.

Optional unplugged devices log at info level and do not consume detection
retries. If their stale index collides with a resolved controller, only their
`openrgb_id` is parked at one past the highest SDK index. LedFx accepts this
nonnegative index and treats the absent controller as offline. Reconnection
resolves the real index normally. Required-device detection/connection retries
are bounded to five attempts, two seconds apart, with a 90-second overall SDK
work deadline. Unresolved devices do not stop reconciliation of other devices;
a virtual referencing one keeps its entire previous segment array.

### Files and recovery

`~/.ledfx/config.json` stays writable. Only changed JSON value spans are
replaced, preserving key order and unrelated formatting; an unchanged result
has no write or backup. Before each changed replacement, the exact prior bytes
are saved privately as `config.json.pre-link-nix.<sha256>`. A same-directory
temporary file is fsynced and atomically renamed. Symlinked/malformed JSON and
concurrent edits are rejected. Earlier `link-argb-layout.json` checkpoints are
no longer needed because layouts come from Nix and fresh zone data; existing
checkpoint files are left alone.

Inspect `journalctl --user -u ledfx` for unresolved identities, count mismatches,
or SDK failures. Restore a private backup only with LedFx stopped. Building
this configuration does not edit live files, resize live LEDs, restart services,
or deploy it. Effects require the graphical-session LedFx service to run.

For a visual count check after later activation, connect the OpenRGB GUI to the
existing SDK server → `X570 AORUS ELITE WIFI` → `D_LED1 Bottom` / `D_LED1` →
Resize → 9 LEDs. Check that all nine addresses illuminate both fans. Keep the
matching count in Nix; a manual resize is restored at the next LedFx startup.
If only one fan responds, inspect its ARGB cable before changing counts.
