"""Reconcile Nix-owned LedFx mappings through the existing OpenRGB SDK server."""

import argparse
import hashlib
import json
import logging
import multiprocessing
import os
import re
import tempfile
import time
from pathlib import Path

from openrgb import OpenRGBClient
from openrgb.utils import OpenRGBDisconnected

LOG = logging.getLogger("link-argb-config")
WHITESPACE = re.compile(r"[ \t\r\n]*")


class JsonDocument:
    """Parse JSON and retain exact value spans; unowned bytes never get serialized."""

    def __init__(self, original):
        self.text = original.decode("utf-8")
        self.spans = {}
        self.decoder = json.JSONDecoder(parse_constant=self.invalid_constant)
        self.value, end = self.parse(0, ())
        if self.skip(end) != len(self.text) or not isinstance(self.value, dict):
            raise ValueError("Expected one JSON object")

    @staticmethod
    def invalid_constant(value):
        raise ValueError(f"Invalid JSON constant: {value}")

    def skip(self, offset):
        return WHITESPACE.match(self.text, offset).end()

    def parse(self, offset, path):
        start = offset = self.skip(offset)
        char = self.text[offset : offset + 1]
        if char == "{":
            value = {}
            offset = self.skip(offset + 1)
            if self.text[offset : offset + 1] != "}":
                while True:
                    key, offset = self.decoder.raw_decode(self.text, offset)
                    if not isinstance(key, str) or key in value:
                        raise ValueError("Non-string or duplicate JSON object key")
                    offset = self.skip(offset)
                    if self.text[offset : offset + 1] != ":":
                        raise ValueError("Expected JSON object colon")
                    value[key], offset = self.parse(offset + 1, (*path, key))
                    offset = self.skip(offset)
                    if self.text[offset : offset + 1] != ",":
                        break
                    offset = self.skip(offset + 1)
            if self.text[offset : offset + 1] != "}":
                raise ValueError("Expected JSON object terminator")
            offset += 1
        elif char == "[":
            value = []
            offset = self.skip(offset + 1)
            if self.text[offset : offset + 1] != "]":
                while True:
                    child, offset = self.parse(offset, (*path, len(value)))
                    value.append(child)
                    offset = self.skip(offset)
                    if self.text[offset : offset + 1] != ",":
                        break
                    offset = self.skip(offset + 1)
            if self.text[offset : offset + 1] != "]":
                raise ValueError("Expected JSON array terminator")
            offset += 1
        else:
            value, offset = self.decoder.raw_decode(self.text, offset)
        self.spans[path] = (start, offset)
        return value, offset

    def render(self, changes):
        edits = []
        for path, value in changes.items():
            start, end = self.spans[path]
            old = self.text[start:end]
            if json.loads(old) == value:
                continue
            # Scalars stay compact. Arrays retain the file's indentation and
            # newline style, without touching surrounding keys or whitespace.
            if isinstance(value, list) and "\n" in old:
                line = self.text[self.text.rfind("\n", 0, start) + 1 : start]
                base = re.match(r"[ \t]*", line).group()
                child = re.search(r"\n([ \t]+)\S", old)
                indent = child.group(1)[len(base) :] if child else "    "
                encoded = json.dumps(value, indent=indent, ensure_ascii=True)
                encoded = encoded.replace("\n", "\n" + base)
                if "\r\n" in old:
                    encoded = encoded.replace("\n", "\r\n")
            else:
                encoded = json.dumps(value, ensure_ascii=True)
            edits.append((start, end, encoded))
        result = self.text
        for start, end, encoded in sorted(edits, reverse=True):
            result = result[:start] + encoded + result[end:]
        JsonDocument(result.encode("utf-8"))
        return result.encode("utf-8")


def indexed_entries(document, kind):
    entries = document.get(kind, [])
    if not isinstance(entries, list):
        raise TypeError(f"LedFx {kind} must be an array")
    indexed = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise TypeError(f"Invalid LedFx {kind} entry")
        if entry["id"] in indexed:
            raise ValueError(f"Duplicate LedFx {kind} identity")
        indexed[entry["id"]] = (index, entry)
    return indexed


def normalized_location(location):
    match = re.fullmatch(
        r"I2C: (.+) \(/dev/i2c-\d+\), address (0x[0-9a-fA-F]+)", location
    )
    if match:
        return {"bus": match[1], "address": f"0x{int(match[2], 16):02x}"}
    return location


def snapshot(device):
    zones = [
        {"name": zone.name, "start": zone.start_idx, "count": len(zone.leds)}
        for zone in device.data.zones
    ]
    return {
        "id": device.id,
        "name": device.name,
        "vendor": device.metadata.vendor,
        "serial": device.metadata.serial,
        "location": device.metadata.location,
        "pixelCount": len(device.leds),
        "zones": zones,
    }


def matches(device, match):
    if device["name"] != match["name"]:
        return False
    for key in ("vendor", "serial"):
        if match.get(key) is not None and device[key] != match[key]:
            return False
    if (
        match.get("location") is not None
        and normalized_location(device["location"]) != match["location"]
    ):
        return False
    return (
        match.get("zoneSignature") is None
        or {z["name"]: z["count"] for z in device["zones"]} == match["zoneSignature"]
    )


def resolve(devices, declarations):
    resolved, failures, warnings = {}, {}, []
    for identity, declaration in declarations.items():
        candidates = [d for d in devices if matches(d, declaration["match"])]
        if not candidates:
            failures[identity] = ("missing", "no matching OpenRGB controller")
            continue
        first = min(candidates, key=lambda d: d["id"])
        if len(candidates) > 1:

            def physical_key(device):
                return (
                    device["name"],
                    device["serial"],
                    device["vendor"],
                    json.dumps(normalized_location(device["location"]), sort_keys=True),
                    device["pixelCount"],
                    device["zones"],
                )

            if not (first["serial"] or first["location"]) or any(
                physical_key(d) != physical_key(first) for d in candidates
            ):
                failures[identity] = (
                    "ambiguous",
                    "multiple distinct OpenRGB candidates",
                )
                continue
            warnings.append(
                f"{identity}: duplicate physical identity at SDK indices "
                f"{sorted(d['id'] for d in candidates)}; using {first['id']}"
            )
        resolved[identity] = first
    # Two declarations must never acquire the same physical controller, even
    # through differently restricted selectors or duplicate SDK entries.
    claims = {}
    for identity, device in resolved.items():
        claims.setdefault(device["id"], []).append(identity)
    for identities in claims.values():
        if len(identities) > 1:
            for identity in identities:
                del resolved[identity]
                failures[identity] = (
                    "ambiguous",
                    "physical controller claimed by multiple LedFx devices",
                )
    return resolved, failures, warnings


def named_zone(device, names):
    zones = [zone for zone in device["zones"] if zone["name"] in names]
    if len(zones) != 1:
        raise ValueError(f"Expected exactly one zone from {names}; found {len(zones)}")
    return zones[0]


def collect_sdk(
    settings, enabled, resize_allowed, client_factory=OpenRGBClient, sleep=time.sleep
):
    """Only connection failures and missing required identities consume retries."""
    declarations = {
        key: value for key, value in settings["devices"].items() if key in enabled
    }
    for attempt in range(5):
        client = None
        try:
            client = client_factory(
                address="127.0.0.1",
                port=settings["port"],
                name="link-argb-config",
                protocol_version=3,
            )
            devices = [snapshot(device) for device in client.devices]
            resolved, failures, warnings = resolve(devices, declarations)
            missing_required = [
                identity
                for identity, (kind, _) in failures.items()
                if kind == "missing" and not declarations[identity]["optional"]
            ]
            if missing_required and attempt < 4:
                LOG.info(
                    "Waiting for required OpenRGB devices: %s",
                    ", ".join(missing_required),
                )
            else:
                cooler = settings["cooler"]
                board = resolved.get(cooler["device"])
                if board and resize_allowed:
                    try:
                        zone = named_zone(board, cooler["zoneNames"])
                        if zone["count"] != cooler["ledCount"]:
                            twins = {
                                d["id"]
                                for d in devices
                                if d["id"] != board["id"]
                                and normalized_location(d["location"])
                                == normalized_location(board["location"])
                                and all(
                                    d[key] == board[key]
                                    for key in (
                                        "name",
                                        "serial",
                                        "vendor",
                                        "pixelCount",
                                        "zones",
                                    )
                                )
                            }
                            live = next(
                                d for d in client.devices if d.id == board["id"]
                            )
                            live.zones[
                                next(
                                    i for i, z in enumerate(board["zones"]) if z == zone
                                )
                            ].resize(cooler["ledCount"])
                            client.update()
                            devices = [snapshot(device) for device in client.devices]
                            # Remember only exact physical twins established before
                            # resize. Their SDK objects may keep an old zone size.
                            canonical = [d for d in devices if d["id"] not in twins]
                            resolved, failures, after_warnings = resolve(
                                canonical, declarations
                            )
                            warnings.extend(after_warnings)
                        if cooler["device"] in resolved:
                            resized = named_zone(
                                resolved[cooler["device"]], cooler["zoneNames"]
                            )
                            if resized["count"] != cooler["ledCount"]:
                                raise ValueError(
                                    "D_LED1 did not reach the requested LED count"
                                )
                    except ValueError as error:
                        resolved.pop(cooler["device"], None)
                        failures[cooler["device"]] = ("layout", str(error))
                for identity, device in list(resolved.items()):
                    if len({z["name"] for z in device["zones"]}) != len(
                        device["zones"]
                    ):
                        del resolved[identity]
                        failures[identity] = ("layout", "duplicate OpenRGB zone names")
                    elif device["pixelCount"] != declarations[identity]["pixelCount"]:
                        del resolved[identity]
                        failures[identity] = (
                            "layout",
                            f"expected {declarations[identity]['pixelCount']} LEDs, found {device['pixelCount']}",
                        )
                return devices, resolved, failures, warnings
        except (ConnectionError, TimeoutError, OSError, OpenRGBDisconnected) as error:
            if attempt == 4 or not any(
                not d["optional"] for d in declarations.values()
            ):
                raise ConnectionError(
                    f"OpenRGB SDK unavailable after {attempt + 1} attempts"
                ) from error
            LOG.info("Waiting for OpenRGB SDK: %s", type(error).__name__)
        finally:
            if client is not None:
                client.disconnect()
        sleep(2)
    raise AssertionError("unreachable retry state")


def sdk_worker(sender, settings, enabled, resize_allowed):
    try:
        sender.send((True, collect_sdk(settings, enabled, resize_allowed)))
    except Exception as error:  # noqa: BLE001 -- serialize errors across the worker boundary
        sender.send((False, f"{type(error).__name__}: {error}"))
    finally:
        sender.close()


def bounded_sdk(settings, enabled, resize_allowed, timeout=90):
    # The same packaged helper owns the worker. Its hard deadline also bounds
    # SDK constructor/profile queries that cannot be interrupted by Python timers.
    context = multiprocessing.get_context("spawn")
    receiver, sender = context.Pipe(duplex=False)
    worker = context.Process(
        target=sdk_worker, args=(sender, settings, enabled, resize_allowed)
    )
    worker.start()
    sender.close()
    try:
        if not receiver.poll(timeout):
            raise TimeoutError(
                f"OpenRGB reconciliation exceeded its {timeout}-second deadline"
            )
        success, result = receiver.recv()
        if not success:
            raise ConnectionError(result)
        return result
    finally:
        receiver.close()
        if worker.is_alive():
            worker.terminate()
        worker.join(timeout=1)
        if worker.is_alive():
            worker.kill()
            worker.join()


def segment_values(segments, devices, resolved, declarations):
    result = []
    for segment in segments:
        identity = segment["device"]
        if identity not in devices:
            raise ValueError(f"missing LedFx segment device {identity}")
        if identity in declarations and identity not in resolved:
            raise ValueError(f"unresolved OpenRGB segment device {identity}")
        if segment.get("zoneNames"):
            zone = named_zone(resolved[identity], segment["zoneNames"])
            start, end = zone["start"], zone["start"] + zone["count"] - 1
        else:
            start, end = segment["start"], segment["end"]
        if not 0 <= start <= end:
            raise ValueError(f"invalid segment range for {identity}")
        if identity in resolved and end >= resolved[identity]["pixelCount"]:
            raise ValueError(f"segment exceeds declared pixels for {identity}")
        result.append([identity, start, end, segment["reverse"]])
    return result


def atomic_write(path, original, payload):
    """Back up every changed original privately, then atomically replace it."""
    if payload == original:
        return False
    if path.is_symlink() or path.read_bytes() != original:
        raise ValueError("LedFx configuration changed during reconciliation")
    backup = path.with_name(
        path.name + ".pre-link-nix." + hashlib.sha256(original).hexdigest()
    )
    try:
        fd = os.open(
            backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
        )
    except FileExistsError:
        if backup.is_symlink() or backup.read_bytes() != original:
            raise ValueError("Unsafe or conflicting LedFx backup")
    else:
        with os.fdopen(fd, "wb") as stream:
            stream.write(original)
            stream.flush()
            os.fsync(stream.fileno())
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        stat = path.stat()
        os.fchmod(fd, stat.st_mode & 0o777)
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        if path.is_symlink() or path.read_bytes() != original:
            raise ValueError("LedFx configuration changed before atomic replacement")
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def configure(config_path, settings, sdk=bounded_sdk):
    path = Path(config_path)
    if path.is_symlink():
        raise ValueError("LedFx configuration must be writable, not a managed symlink")
    original = path.read_bytes()
    document = JsonDocument(original)
    devices = indexed_entries(document.value, "devices")
    virtuals = indexed_entries(document.value, "virtuals")
    enabled = set()
    for identity in settings["devices"]:
        entry = devices.get(identity, (None, {}))[1]
        cfg = entry.get("config", {})
        if (
            entry.get("type") != "openrgb"
            or not isinstance(cfg, dict)
            or any(
                type(cfg.get(key)) is not int for key in ("openrgb_id", "pixel_count")
            )
        ):
            LOG.error(
                "%s: missing or invalid existing LedFx OpenRGB device; untouched",
                identity,
            )
        else:
            enabled.add(identity)
    resize_allowed = settings["cooler"]["virtual"] in virtuals
    if not resize_allowed:
        LOG.error("Cooler virtual is missing; D_LED1 resize skipped")
    try:
        sdk_devices, resolved, failures, warnings = sdk(
            settings, enabled, resize_allowed
        )
    except (ConnectionError, TimeoutError) as error:
        LOG.error("%s; LedFx configuration untouched", error)
        return False
    for warning in dict.fromkeys(warnings):
        LOG.warning("%s", warning)
    changes = {}
    # Sentinel is out of range for this complete SDK snapshot. LedFx accepts
    # nonnegative IDs and treats an IndexError at activation as offline.
    sentinel = max((d["id"] for d in sdk_devices), default=-1) + 1
    present_indices = {device["id"] for device in resolved.values()}
    for identity, (kind, reason) in failures.items():
        optional_missing = (
            kind == "missing" and settings["devices"][identity]["optional"]
        )
        (LOG.info if optional_missing else LOG.error)("%s: %s", identity, reason)
        if optional_missing:
            index, entry = devices[identity]
            if entry["config"]["openrgb_id"] in present_indices:
                changes[("devices", index, "config", "openrgb_id")] = sentinel
                LOG.info(
                    "%s: stale index %s collides with a present controller; parking at unused index %s",
                    identity,
                    entry["config"]["openrgb_id"],
                    sentinel,
                )
    for identity, device in resolved.items():
        index, _ = devices[identity]
        changes[("devices", index, "config", "openrgb_id")] = device["id"]
        changes[("devices", index, "config", "pixel_count")] = device["pixelCount"]
    for identity, segments in settings["virtuals"].items():
        if identity not in virtuals:
            LOG.error("%s: missing existing LedFx virtual; untouched", identity)
            continue
        index, entry = virtuals[identity]
        if not isinstance(entry.get("segments"), list):
            LOG.error("%s: invalid existing segments; untouched", identity)
            continue
        try:
            values = segment_values(segments, devices, resolved, settings["devices"])
        except ValueError as error:
            level = (
                LOG.info
                if any(
                    segment["device"] in failures
                    and failures[segment["device"]][0] == "missing"
                    and settings["devices"][segment["device"]]["optional"]
                    for segment in segments
                )
                else LOG.error
            )
            level("%s: %s; segments untouched", identity, error)
            continue
        changes[("virtuals", index, "segments")] = values
        cooler = settings["cooler"]
        if entry.get("active") is False and any(
            value[0] == cooler["device"] for value in values
        ):
            try:
                zone = named_zone(resolved[cooler["device"]], cooler["zoneNames"])
            except (KeyError, ValueError) as error:
                LOG.error("%s: %s; activation untouched", identity, error)
                continue
            cooler_end = zone["start"] + zone["count"] - 1
            if any(
                device == cooler["device"]
                and start <= cooler_end
                and end >= zone["start"]
                for device, start, end, _ in values
            ):
                # Only the declared cooler segment owns activation. Missing
                # active fields already allow LedFx to restore the saved effect.
                changes[("virtuals", index, "active")] = True
    payload = document.render(changes)
    changed = atomic_write(path, original, payload)
    LOG.info("LedFx mappings %s", "updated" if changed else "already reconciled")
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--settings", required=True)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    settings = json.loads(Path(args.settings).read_text())
    if not 1 <= settings["cooler"]["ledCount"] <= 512:
        raise ValueError("Cooler LED count must be between 1 and 512")
    configure(args.config, settings)


if __name__ == "__main__":
    main()
