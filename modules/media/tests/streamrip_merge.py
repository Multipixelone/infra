"""Migrate the mutable user config without guessing credentials or losing settings."""

import json
import os
import sys
import tempfile
from pathlib import Path

import tomlkit
import tomllib
from streamrip.config import BLANK_CONFIG_PATH, ConfigData


class MigrationError(Exception):
    pass


def valid_credential(value):
    return (
        isinstance(value, str)
        and bool(value.strip())
        and not any(ord(char) < 32 or ord(char) == 127 for char in value)
    )


def select_credentials(qobuz):
    new_keys = ("user_id", "auth_token")
    old_keys = ("email_or_userid", "password_or_token")
    configured = any(key in qobuz and qobuz[key] != "" for key in new_keys + old_keys)
    if not configured:
        return None  # Fresh/blank configs are intentionally not authenticated.
    if any(key in qobuz for key in new_keys):
        if all(valid_credential(qobuz.get(key)) for key in new_keys):
            return tuple(qobuz[key] for key in new_keys)
    elif qobuz.get("use_auth_token") is True and all(
        valid_credential(qobuz.get(key)) for key in old_keys
    ):
        return tuple(qobuz[key] for key in old_keys)
    raise MigrationError(
        "Qobuz credentials cannot be safely migrated; reauthenticate Qobuz before activation."
    )


def deep_merge(dst, src):
    for key, value in src.items():
        if isinstance(value, dict):
            if key not in dst:
                dst[key] = tomlkit.table()
            deep_merge(dst[key], value)
        else:
            dst[key] = value


def merge(managed, cfg):
    replace_store_link = cfg.is_symlink() and str(cfg.resolve()).startswith(
        "/nix/store/"
    )
    if cfg.is_symlink() and not replace_store_link:
        cfg = cfg.resolve()
    old = cfg.read_text(encoding="utf-8") if cfg.exists() else None
    original = tomllib.loads(old) if old is not None else {}

    # Validate everything used for migration BEFORE modifying the TOML document.
    credentials = select_credentials(original.get("qobuz", {}))
    cli = original.get("cli", {})
    misc = original.get("misc", {})
    for section, key in ((cli, "no_update_check"), (misc, "check_for_updates")):
        if key in section and type(section[key]) is not bool:
            raise MigrationError(
                "Update-check setting must be a boolean; correct the config before activation."
            )

    doc = tomlkit.parse(old) if old is not None else tomlkit.document()
    if credentials is not None:
        if "qobuz" not in doc:
            doc["qobuz"] = tomlkit.table()
        doc["qobuz"]["user_id"], doc["qobuz"]["auth_token"] = credentials
    if "check_for_updates" in misc and "no_update_check" not in cli:
        if "cli" not in doc:
            doc["cli"] = tomlkit.table()
        doc["cli"]["no_update_check"] = not misc["check_for_updates"]

    # The old Qobuz-only filters became shared artist filters. New values win.
    if "qobuz_filters" in doc:
        if "artist_filters" not in doc:
            doc["artist_filters"] = tomlkit.table()
        for key in ("extras", "repeats", "non_albums", "features", "non_remaster"):
            if key in doc["qobuz_filters"] and key not in doc["artist_filters"]:
                doc["artist_filters"][key] = doc["qobuz_filters"][key]

    obsolete = {
        "qobuz": ("use_auth_token", "email_or_userid", "password_or_token"),
        "downloads": ("concurrency",),
        "cli": ("text_output",),
        "filepaths": ("unique",),
        "tidal": ("download_videos",),
        "deezer": ("use_deezloader", "deezloader_warnings"),
        "soundcloud": ("quality",),
        "misc": ("version", "check_for_updates"),
        "qobuz_filters": (
            "extras",
            "repeats",
            "non_albums",
            "features",
            "non_remaster",
            "non_studio_albums",
        ),
        "youtube": ("quality", "download_videos", "video_downloads_folder"),
    }
    for section, keys in obsolete.items():
        if section in doc:
            for key in keys:
                doc[section].pop(key, None)
            if not doc[section] and section in ("misc", "qobuz_filters", "youtube"):
                del doc[section]

    template = tomlkit.parse(Path(BLANK_CONFIG_PATH).read_text(encoding="utf-8"))
    template["downloads"]["folder"] = managed["downloads"]["folder"]
    template["database"]["downloads_path"] = str(cfg.parent / "downloads.db")
    template["database"]["failed_downloads_path"] = str(
        cfg.parent / "failed_downloads.db"
    )
    for section, defaults in template.items():
        if section not in doc:
            doc[section] = tomlkit.table()
        for key, value in defaults.items():
            if key not in doc[section]:
                doc[section][key] = value
    deep_merge(doc, managed)
    new = tomlkit.dumps(doc)
    ConfigData.from_toml(new)  # Exact pinned typed loader, before atomic replacement.

    if new != old or replace_store_link:
        cfg.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".streamrip-config-", dir=cfg.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(new)
            os.replace(tmp, cfg)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    else:
        # Also secure a valid, already migrated file without replacing its bytes/inode.
        cfg.chmod(0o600)


def main():
    try:
        merge(json.loads(sys.argv[1]), Path(sys.argv[2]))
    except MigrationError as exc:
        print(f"streamrip-merge-config: {exc}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - never expose credentials from parser/IO errors
        # Parser/IO exception messages can quote credential values. Never print them.
        print(
            "streamrip-merge-config: config migration failed; original config was not replaced. Correct the config or reauthenticate before activation.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
