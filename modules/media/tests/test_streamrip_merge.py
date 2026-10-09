"""Bounded, offline regression tests invoking the actual activation merger."""

import copy
import itertools
import json
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import tomlkit
import tomllib

MERGER, TEMPLATE = sys.argv[1:]
DEFAULTS = tomllib.loads(Path(TEMPLATE).read_text())
SECRET = "synthetic-migration-secret"
MANAGED = {"downloads": {"folder": "/synthetic/music"}, "qobuz": {"quality": 3}}
count = 0


def invoke(path):
    return subprocess.run(
        [MERGER, json.dumps(MANAGED), str(path)],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )


def fixture(qobuz=None):
    doc = copy.deepcopy(DEFAULTS)
    if qobuz is not None:
        doc["qobuz"] = {
            key: value
            for key, value in doc["qobuz"].items()
            if key not in ("user_id", "auth_token")
        }
        doc["qobuz"].update(qobuz)
    doc["tidal"]["access_token"] = SECRET + "-tidal"
    doc["deezer"]["arl"] = SECRET + "-deezer"
    doc["spotify"]["refresh_token"] = SECRET + "-spotify"
    doc["conversion"]["enabled"] = True
    doc["downloads"]["max_connections"] = 7
    doc["unknown_section"] = {"keep": "unchanged"}
    return doc


def check(doc=None, *, reject=False, symlink=False, absent=False):
    global count
    count += 1
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        target = root / "target.toml"
        path = root / "config.toml"
        original = tomlkit.dumps(doc) if doc is not None else ""
        if not absent:
            target.write_text(original)
            target.chmod(0o640)
            if symlink:
                path.symlink_to(target)
            else:
                target.rename(path)
                target = path
        result = invoke(path)
        assert not result.stdout, result.stdout
        assert SECRET not in result.stderr
        if reject:
            assert result.returncode == 1
            assert result.stderr in {
                "streamrip-merge-config: Qobuz credentials cannot be safely migrated; reauthenticate Qobuz before activation.\n",
                "streamrip-merge-config: Update-check setting must be a boolean; correct the config before activation.\n",
                "streamrip-merge-config: config migration failed; original config was not replaced. Correct the config or reauthenticate before activation.\n",
            }
            assert target.read_bytes() == original.encode()
            assert stat.S_IMODE(target.stat().st_mode) == 0o640
            assert not list(root.glob(".streamrip-config-*"))
            if symlink:
                assert path.is_symlink() and path.resolve() == target
            return {}
        assert result.returncode == 0, result.stderr
        assert not result.stderr
        merged = tomllib.loads(path.read_text())
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        if symlink:
            assert path.is_symlink() and path.resolve() == target
        if doc is not None:
            assert merged["tidal"]["access_token"] == SECRET + "-tidal"
            assert merged["deezer"]["arl"] == SECRET + "-deezer"
            assert merged["spotify"]["refresh_token"] == SECRET + "-spotify"
            assert merged["conversion"]["enabled"] is True
            assert merged["downloads"]["max_connections"] == 7
            assert merged["unknown_section"] == doc["unknown_section"]
        before = path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns
        second = invoke(path)
        assert second.returncode == 0 and not second.stdout and not second.stderr
        assert before == (
            path.read_bytes(),
            path.stat().st_ino,
            path.stat().st_mtime_ns,
        )
        path.chmod(0o640)
        third = invoke(path)
        assert third.returncode == 0 and not third.stdout and not third.stderr
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert before == (
            path.read_bytes(),
            path.stat().st_ino,
            path.stat().st_mtime_ns,
        )
        return merged


legacy: dict[str, object] = {
    "use_auth_token": True,
    "email_or_userid": "synthetic-user",
    "password_or_token": SECRET,
}
new: dict[str, object] = {
    "user_id": "synthetic-new-user",
    "auth_token": SECRET + "-new",
}

# Complete old 2.2 shape, including all obsolete fields from its shipped fixture.
old = fixture(legacy)
old["downloads"]["concurrency"] = True
old["cli"]["text_output"] = True
old["filepaths"]["unique"] = True
old["tidal"]["download_videos"] = True
old["deezer"].update(use_deezloader=True, deezloader_warnings=True)
old["soundcloud"]["quality"] = 0
old["misc"] = {"version": "2.2.0", "check_for_updates": True}
old["qobuz_filters"] = {
    "extras": True,
    "repeats": False,
    "non_albums": False,
    "features": False,
    "non_studio_albums": False,
    "non_remaster": False,
}
old.pop("artist_filters")
old["youtube"] = {"quality": 0, "download_videos": False, "video_downloads_folder": ""}
for section, key in (
    ("downloads", "lyrics"),
    ("metadata", "prefer_explicit"),
    ("tidal", "hires_client"),
):
    old[section].pop(key)
merged = check(old)
assert merged["qobuz"]["user_id"] == "synthetic-user"
assert merged["qobuz"]["auth_token"] == SECRET
assert all(key not in merged["qobuz"] for key in legacy)
assert merged["artist_filters"]["extras"] is True
assert merged["cli"]["no_update_check"] is False
assert not any(section in merged for section in ("misc", "qobuz_filters", "youtube"))
for section, keys in {
    "tidal": ("download_videos",),
    "deezer": ("use_deezloader", "deezloader_warnings"),
    "soundcloud": ("quality",),
    "downloads": ("concurrency",),
    "cli": ("text_output",),
    "filepaths": ("unique",),
}.items():
    assert all(key not in merged[section] for key in keys)
assert merged["downloads"]["lyrics"] == DEFAULTS["downloads"]["lyrics"]
doc = fixture(legacy)
doc["qobuz_filters"] = {"extras": True, "custom_keep": "preserved"}
doc["misc"] = {"version": "2.2.0", "custom_keep": "preserved"}
doc["youtube"] = {"quality": 0, "custom_keep": "preserved"}
merged = check(doc)
assert merged["artist_filters"]["extras"] == DEFAULTS["artist_filters"]["extras"]
for section in ("qobuz_filters", "misc", "youtube"):
    assert merged[section] == {"custom_keep": "preserved"}

assert check(fixture(new))["qobuz"]["auth_token"] == new["auth_token"]
# A valid complete new pair wins even over unusable password-mode legacy fields.
assert (
    check(fixture(dict(legacy, **new, use_auth_token=False)))["qobuz"]["user_id"]
    == new["user_id"]
)
check(fixture(legacy), symlink=True)
check(fixture({}))
check(fixture({"user_id": "", "auth_token": ""}))
check(
    fixture({"use_auth_token": False, "email_or_userid": "", "password_or_token": ""})
)
check(absent=True)

for key, value in new.items():
    check(fixture(dict(legacy, **{key: value})), reject=True)
    check(fixture(dict(legacy, **{key: ""})), reject=True)
for flag in (False, None, "true", 1, []):
    value = dict(legacy)
    if flag is None:
        value.pop("use_auth_token")
    else:
        value["use_auth_token"] = flag
    check(fixture(value), reject=True)
for keys, base in (
    (("user_id", "auth_token"), new),
    (("email_or_userid", "password_or_token"), legacy),
):
    for key, invalid in itertools.product(
        keys, ("", "   ", "secret\nvalue", "secret\x7fvalue", 42, False, [])
    ):
        value = dict(base)
        value[key] = invalid
        check(fixture(value), reject=True)
    for key in keys:
        value = dict(base)
        del value[key]
        check(fixture(value), reject=True)
check(fixture({"user_id": "partial", **legacy}), reject=True, symlink=True)

# Update-check truth table; the new explicit setting wins, unspecified stays default.
for old_flag, new_flag in itertools.product((None, False, True), repeat=2):
    doc = fixture(new)
    if old_flag is not None:
        doc["misc"] = {"check_for_updates": old_flag}
    if new_flag is not None:
        doc["cli"]["no_update_check"] = new_flag
    merged = check(doc)
    expected = (
        new_flag
        if new_flag is not None
        else (not old_flag if old_flag is not None else False)
    )
    assert merged["cli"].get("no_update_check", False) is expected
for section, key in (("misc", "check_for_updates"), ("cli", "no_update_check")):
    for invalid in ("false", "", 0, 1, []):
        doc = fixture(new)
        doc.setdefault(section, {})[key] = invalid
        check(doc, reject=True)
doc = fixture(new)
doc["misc"] = {"check_for_updates": "invalid"}
doc["cli"]["no_update_check"] = True
check(doc, reject=True)

# Do not silently discard unknown typed options; loader rejection preserves bytes.
doc = fixture(new)
doc["qobuz"]["unknown_setting"] = SECRET
check(doc, reject=True)

# Replacing an immutable generated link must not modify the store target.
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "config.toml"
    before = Path(TEMPLATE).read_bytes()
    path.symlink_to(TEMPLATE)
    result = invoke(path)
    assert result.returncode == 0, result.stderr
    assert not path.is_symlink()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert Path(TEMPLATE).read_bytes() == before

print(f"passed {count} config migration cases plus immutable-link replacement")
