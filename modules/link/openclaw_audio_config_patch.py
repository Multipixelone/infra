"""Narrow startup migration of mutable OpenClaw JSON; never read by Nix eval."""

import copy
import json
import os
import stat
import sys
import tempfile
from pathlib import Path


def patch_config(config, command):
    result = copy.deepcopy(config)
    try:
        models = result["tools"]["media"]["models"]
    except (KeyError, TypeError):
        raise ValueError("expected tools.media.models") from None
    if not isinstance(models, list):
        raise TypeError("tools.media.models must be a list")
    retained = []
    for entry in models:
        if not isinstance(entry, dict):
            raise TypeError("media model must be an object")
        caps = entry.get("capabilities")
        if (
            not isinstance(caps, list)
            or not caps
            or not all(
                isinstance(cap, str) and cap in ("audio", "image", "video")
                for cap in caps
            )
        ):
            raise ValueError("media model requires explicit known capabilities")
        local = (
            entry.get("type") == "cli"
            and Path(entry.get("command", "")).name == "openclaw-whisper"
        )
        failing_openai = (
            entry.get("provider") == "openai" and entry.get("model") == "gpt-transcribe"
        )
        if "audio" in caps and (local or failing_openai):
            # A combined entry must retain its non-audio capabilities/settings.
            remaining = [cap for cap in caps if cap != "audio"]
            if remaining:
                entry["capabilities"] = remaining
                retained.append(entry)
        else:
            retained.append(entry)
    result["tools"]["media"]["models"] = [
        {
            "type": "cli",
            "command": command,
            "args": ["{{AttachmentPath}}"],
            "timeoutSeconds": 300,
            "capabilities": ["audio"],
        }
    ] + retained
    return result


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def identity(metadata):
    # Reading can update atime under relatime; that is not a concurrent edit.
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def patch_file(filename, command):
    path = Path(filename)
    original_stat = path.lstat()
    if not stat.S_ISREG(original_stat.st_mode) or original_stat.st_uid != os.getuid():
        raise ValueError("config must be an owned regular file (not a symlink)")
    mode = stat.S_IMODE(original_stat.st_mode)
    if mode & 0o077:
        raise ValueError("config must have owner-only permissions")
    original = path.read_bytes()
    config = json.loads(
        original,
        object_pairs_hook=reject_duplicates,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite JSON")),
    )
    updated = patch_config(config, command)
    if updated == config:
        return False
    replacement = (json.dumps(updated, ensure_ascii=False, indent=2) + "\n").encode()
    # Both files are created privately in the same directory. Backup is unique,
    # contains exact original bytes, and is only created on an actual change.
    backup_fd, backup_name = tempfile.mkstemp(
        prefix=path.name + ".pre-whisper-", dir=path.parent
    )
    with os.fdopen(backup_fd, "wb") as backup:
        backup.write(original)
        backup.flush()
        os.fsync(backup.fileno())
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".whisper-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as target:
            os.fchmod(target.fileno(), mode)
            target.write(replacement)
            target.flush()
            os.fsync(target.fileno())
        # Refuse to overwrite a concurrent edit; startup is normally serialized.
        if (
            identity(path.lstat()) != identity(original_stat)
            or path.read_bytes() != original
        ):
            raise ValueError("config changed during patch")
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(
        f"openclaw audio config patched; protected backup: {backup_name}",
        file=sys.stderr,
    )
    return True


def main():
    if len(sys.argv) != 3:
        print("usage: openclaw-audio-config-patch CONFIG COMMAND", file=sys.stderr)
        return 2
    try:
        patch_file(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, TypeError) as error:
        # Do not print JSON contents (which can contain credentials).
        print(
            f"openclaw audio config patch refused: {type(error).__name__}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
