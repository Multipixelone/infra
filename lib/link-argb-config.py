"""Configure the cooler through the existing SDK server before LedFx starts."""

import argparse
import copy
import hashlib
import json
import sys
import time
from pathlib import Path

from openrgb import OpenRGBClient

# Shared private-backup/atomic-replacement implementation; no cooling operation.
sys.path.insert(0, str(Path(__file__).parent))
from link_cooling_config import atomic_write


class DetectionPending(ValueError, ConnectionError):
    """The SDK server may accept clients before its hardware scan finishes."""


def unique(items, description, wait=False):
    if wait and not items:
        raise DetectionPending(f"Waiting for {description}")
    if len(items) != 1:
        raise ValueError(f"Expected one {description}, found {len(items)}")
    return items[0]


def zone_layout(device):
    # SDK 0.3.6 retains stale Zone.leds[].id when another zone's resize shifts
    # this zone's offset without changing its own length. ControllerData is
    # freshly decoded, so use its start_idx rather than cached LED objects.
    layout = {}
    for zone in device.data.zones:
        if zone.name in layout:
            raise ValueError(f"Ambiguous OpenRGB zone name: {zone.name}")
        layout[zone.name] = list(range(zone.start_idx, zone.start_idx + len(zone.leds)))
    return layout


def remap_segments(segments, device_id, old_layout, new_layout):
    mapping = {}
    for name, old_leds in old_layout.items():
        new_leds = new_layout.get(name, [])
        mapping.update(zip(old_leds, new_leds))
    result = []
    for segment in segments:
        if segment[0] != device_id:
            result.append(segment)
            continue
        indices = [
            mapping[index]
            for index in range(segment[1], segment[2] + 1)
            if index in mapping
        ]
        # A resized zone can create a gap inside an old full-device segment.
        # Split that segment at the gap, preserving direction and other fields.
        runs = []
        for index in indices:
            if not runs or index != runs[-1][-1] + 1:
                runs.append([index])
            else:
                runs[-1].append(index)
        if segment[3]:
            runs.reverse()
        for run in runs:
            result.append([device_id, run[0], run[-1], *segment[3:]])
    return result


def add_cooler(document, settings, device, old_layout, new_layout):
    document = copy.deepcopy(document)
    board = unique(
        [
            entry
            for entry in document.get("devices", [])
            if entry.get("id") == settings["ledfx_device"]
            and entry.get("type") == "openrgb"
        ],
        "existing LedFx motherboard device",
    )
    target = unique(
        [
            entry
            for entry in document.get("virtuals", [])
            if entry.get("id") == settings["virtual"]
        ],
        "existing LedFx front-fan virtual",
    )
    leds = new_layout[settings["zone"]]
    if len(leds) != settings["led_count"] or leds != list(
        range(leds[0], leds[0] + len(leds))
    ):
        raise ValueError(
            "Cooler zone did not resize to the requested contiguous LED range"
        )
    board["config"]["openrgb_id"] = device.id
    board["config"]["pixel_count"] = len(device.leds)
    board["config"]["ip_address"] = "127.0.0.1"
    board["config"]["port"] = settings["port"]
    for virtual in document["virtuals"]:
        segments = remap_segments(
            virtual.get("segments", []), board["id"], old_layout, new_layout
        )
        # Only the selected front-fan virtual writes the cooler range. Preserve
        # any portions of other motherboard segments outside that range.
        cleaned = []
        for segment in segments:
            if segment[0] != board["id"]:
                cleaned.append(segment)
                continue
            start, end = segment[1:3]
            if start < leds[0]:
                cleaned.append(
                    [board["id"], start, min(end, leds[0] - 1), *segment[3:]]
                )
            if end > leds[-1]:
                cleaned.append(
                    [board["id"], max(start, leds[-1] + 1), end, *segment[3:]]
                )
        virtual["segments"] = cleaned
    target["segments"].append([board["id"], leds[0], leds[-1], False])
    return document


def configure(config_path, settings, client_factory=OpenRGBClient):
    path = Path(config_path)
    if path.is_symlink():
        raise ValueError("LedFx configuration must be writable, not a managed symlink")
    original = path.read_bytes()
    document = json.loads(original)
    # Validate the existing LedFx identities before any SDK resize operation.
    unique(
        [
            entry
            for entry in document.get("devices", [])
            if entry.get("id") == settings["ledfx_device"]
            and entry.get("type") == "openrgb"
        ],
        "LedFx motherboard device",
    )
    unique(
        [
            entry
            for entry in document.get("virtuals", [])
            if entry.get("id") == settings["virtual"]
        ],
        "LedFx front-fan virtual",
    )
    client = client_factory(
        address="127.0.0.1", port=settings["port"], name="link-cooler-argb"
    )
    try:
        device = unique(
            [
                device
                for device in client.devices
                if device.name == settings["controller"]
            ],
            "OpenRGB motherboard controller",
            wait=True,
        )
        zone = unique(
            [zone for zone in device.zones if zone.name == settings["zone"]],
            "D_LED1 zone",
            wait=True,
        )
        current_layout = zone_layout(device)
        # After a server restart its resizable zones may reset to zero. Retain
        # our previous layout so existing LedFx motherboard offsets stay correct.
        state_path = path.with_name("link-argb-layout.json")
        if state_path.is_symlink():
            raise ValueError("ARGB layout state must be a regular writable file")
        state = json.loads(state_path.read_text()) if state_path.exists() else None
        digest = hashlib.sha256(original).hexdigest()
        old_layout = current_layout
        if state and state.get("controller") == settings["controller"]:
            old_layout = (
                state["previous_layout"]
                if state.get("previous_config_sha256") == digest
                else state["layout"]
            )
        # Save the old offsets before SDK resize, which may outlive this process.
        checkpoint = {
            "controller": settings["controller"],
            "layout": old_layout,
            "previous_layout": old_layout,
            "previous_config_sha256": digest,
        }
        atomic_write(state_path, json.dumps(checkpoint, sort_keys=True) + "\n")
        if len(zone.leds) != settings["led_count"]:
            zone.resize(settings["led_count"])
            client.update()
            device = unique(
                [
                    device
                    for device in client.devices
                    if device.name == settings["controller"]
                ],
                "OpenRGB motherboard controller",
                wait=True,
            )
        new_layout = zone_layout(device)
        updated = add_cooler(document, settings, device, old_layout, new_layout)
        # LedFx sets Direct mode when activating its OpenRGB device. Do not
        # overwrite colors or modes here, or start a second hardware scanner.
        # The previous hash recovers old offsets if interrupted between these
        # two atomic replacements. Subsequent UI edits still use the new layout.
        checkpoint["layout"] = new_layout
        atomic_write(
            state_path,
            json.dumps(checkpoint, sort_keys=True) + "\n",
        )
        atomic_write(path, json.dumps(updated, indent=2) + "\n")
    finally:
        client.disconnect()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--settings", required=True)
    args = parser.parse_args()
    settings = json.loads(Path(args.settings).read_text())
    if not 1 <= settings["led_count"] <= 512:
        raise ValueError("LED count must be between 1 and 512")
    # Retry connection/detection while the server finishes its hardware scan.
    for attempt in range(5):
        try:
            configure(args.config, settings)
            return
        except (ConnectionError, TimeoutError, OSError) as error:
            if attempt == 4:
                raise
            print(f"Waiting for OpenRGB: {error}", file=sys.stderr)
            time.sleep(2)


if __name__ == "__main__":
    main()
