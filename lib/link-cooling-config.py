"""Reconcile Nix-owned profiles while CoolerControl is stopped.

Never talks to hardware or the daemon API. Paths are arguments so validation
can use private fixtures without touching /etc/coolercontrol.
"""

import argparse
import copy
import json
import os
import tempfile
from itertools import pairwise
from pathlib import Path

import tomlkit

KRAKEN = "ddaf4223288218655ca8177c40841504c065de5600c7869af6e26739a7694956"
SMART = "4b9cd1bc5fb2921253e6b7dd5b1b011086ea529d915a86b3560c236084452807"
OLD_MIX = "56c9ca47-48b6-4dae-a079-1aad35136daf"
OLD_GPU_GRAPH = "e4b520ba-47a6-4220-a58f-ff9c68fe10f4"


def atomic_write(path, content):
    """Keep a private original backup and replace a regular file atomically."""
    if path.is_symlink():
        raise ValueError(f"Refusing managed/symlinked daemon configuration: {path}")
    payload = content.encode()
    if path.exists() and path.read_bytes() == payload:
        return
    if path.exists():
        backup = path.with_name(path.name + ".pre-link-nix")
        try:
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, "wb") as stream:
                stream.write(path.read_bytes())
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        if path.exists():
            stat = path.stat()
            os.fchmod(fd, stat.st_mode & 0o777)
            if os.geteuid() == 0:
                os.fchown(fd, stat.st_uid, stat.st_gid)
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def purge_device(value):
    """Remove only exact Kraken keys/identities; retain unrelated settings."""
    if isinstance(value, dict):
        for key in list(value):
            child = value[key]
            if key == KRAKEN or child == KRAKEN:
                del value[key]
            elif isinstance(child, (dict, list)):
                purge_device(child)
    elif isinstance(value, list):
        # tomlkit arrays reject slice assignment. Delete by index so comments
        # and the array's TOML representation survive targeted removals.
        for index in range(len(value) - 1, -1, -1):
            child = value[index]
            if child == KRAKEN or (
                isinstance(child, dict)
                and any(
                    child.get(key) == KRAKEN
                    for key in ("deviceUID", "device_uid", "uid")
                )
            ):
                del value[index]
        for child in value:
            purge_device(child)


def reconcile_document(document, library):
    library = copy.deepcopy(library)
    for profile in library["profiles"]:
        if profile["p_type"] == "Graph":
            points = profile["speed_profile"]
            if (
                len(points) < 2
                or any(len(point) != 2 or not 1 <= point[1] <= 100 for point in points)
                or any(a[0] >= b[0] for a, b in pairwise(points))
            ):
                raise ValueError(f"Invalid non-stopping fan curve: {profile['name']}")
            profile["speed_profile"] = [
                [float(temp), int(duty)] for temp, duty in points
            ]
            profile["temp_min"] = float(points[0][0])
            profile["temp_max"] = float(points[-1][0])
            # The daemon requires inline temperature sources, not TOML subtables.
            source = tomlkit.inline_table()
            source.update(profile["temp_source"])
            profile["temp_source"] = source

    # Profiles that actually depend on the removed cooler must not survive.
    profiles = document.get("profiles", [])
    removed = {
        p["uid"]
        for p in profiles
        if p.get("temp_source", {}).get("device_uid") == KRAKEN
    }
    while True:
        dependent = {
            p["uid"]
            for p in profiles
            if removed.intersection(p.get("member_profile_uids", []))
        }
        if dependent <= removed:
            break
        removed.update(dependent)
    purge_device(document)
    for settings in document.get("device-settings", {}).values():
        for channel in list(settings):
            if settings[channel].get("profile_uid") in removed:
                del settings[channel]

    # Migrate only the observed Smart Device radiator assignments. GPU fan
    # assignments and the existing graph/function control data are preserved.
    for setting in document.get("device-settings", {}).get(SMART, {}).values():
        if setting.get("profile_uid") == OLD_MIX:
            setting["profile_uid"] = library["case_profile_uid"]
    for profile in profiles:
        if profile.get("uid") == OLD_GPU_GRAPH:
            profile["name"] = "GPU fan (existing)"
        elif profile.get("uid") == OLD_MIX:
            profile["name"] = "Case fans (legacy)"

    for kind in ("profiles", "functions"):
        owned = {entry["uid"] for entry in library[kind]}
        existing = document.get(kind, [])
        current_owned = [entry for entry in existing if entry["uid"] in owned]
        # Rebuilding identical arrays accumulates tomlkit blank-line trivia.
        if (
            len(current_owned) == len(library[kind])
            and all(
                any(entry == desired for entry in current_owned)
                for desired in library[kind]
            )
            and not any(entry["uid"] in removed for entry in existing)
        ):
            continue
        entries = tomlkit.aot()
        for entry in existing:
            if entry["uid"] not in owned | removed:
                entries.append(entry)
        for entry in library[kind]:
            entries.append(tomlkit.item(entry))
        document[kind] = entries
    document.setdefault("settings", tomlkit.table())["apply_on_boot"] = True
    return document


def reconcile(directory, library):
    directory = Path(directory)
    path = directory / "config.toml"
    # The daemon supplies optional defaults, but requires these tables even on
    # a fresh install. Its validator indexes legacy690/device-settings directly.
    document = tomlkit.parse(path.read_text() if path.exists() else "")
    for section in ("devices", "legacy690", "device-settings", "settings"):
        document.setdefault(section, tomlkit.table())
    document.setdefault("profiles", tomlkit.aot())
    document.setdefault("functions", tomlkit.aot())
    if not any(p["uid"] == "0" for p in document["profiles"]):
        document["profiles"].append(
            tomlkit.item(
                {
                    "uid": "0",
                    "name": "Default Profile",
                    "p_type": "Default",
                    "function_uid": "0",
                }
            )
        )
    if not any(f["uid"] == "0" for f in document["functions"]):
        document["functions"].append(
            tomlkit.item({"uid": "0", "name": "Default Function", "f_type": "Identity"})
        )

    writes = {}
    # These arrays are parallel in CoolerControl's UI file. Remove corresponding
    # entries together before recursively pruning dashboard channel references.
    for name in (
        "config-ui.json",
        "modes.json",
        "calibrations.json",
        "alerts.json",
        "alarms.json",
    ):
        auxiliary = directory / name
        if not auxiliary.exists():
            continue
        value = json.loads(auxiliary.read_text())
        if name == "config-ui.json" and isinstance(value.get("devices"), list):
            devices = value["devices"]
            settings = value.get("deviceSettings", [])
            if len(devices) != len(settings):
                raise ValueError(
                    "CoolerControl UI device/settings arrays have different lengths"
                )
            value["deviceSettings"] = [
                setting for uid, setting in zip(devices, settings) if uid != KRAKEN
            ]
        purge_device(value)
        writes[auxiliary] = json.dumps(value, separators=(",", ":")) + "\n"
    overrides = directory / "overrides.toml"
    if overrides.exists():
        value = tomlkit.parse(overrides.read_text())
        purge_device(value)
        writes[overrides] = tomlkit.dumps(value)
    writes[path] = tomlkit.dumps(reconcile_document(document, library))
    # Parse everything before writing anything; malformed inputs preserve the
    # previous configuration and prevent the daemon starting with a partial edit.
    for target, content in writes.items():
        if target.is_symlink():
            raise ValueError(
                f"Refusing managed/symlinked daemon configuration: {target}"
            )
        if target.suffix == ".toml":
            tomlkit.parse(content)
        else:
            json.loads(content)
    directory.mkdir(parents=True, exist_ok=True)
    for target, content in writes.items():
        atomic_write(target, content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-dir", required=True)
    parser.add_argument("--library", required=True)
    args = parser.parse_args()
    reconcile(args.config_dir, json.loads(Path(args.library).read_text()))


if __name__ == "__main__":
    main()
