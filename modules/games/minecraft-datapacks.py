"""Build deterministic packs and reconcile only managed archives while Paper is stopped."""

import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import zipfile


NAME = re.compile(r"infra-[a-z0-9_-]+\.zip")
LEDGER = ".infra-managed.json"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_directory(path):
    # The unit runs as Minecraft, never root; reject world/directory symlinks too.
    for parent in reversed([path, *path.parents]):
        if parent.is_symlink():
            raise ValueError("datapack directory must not contain symlinks")
        parent.mkdir(mode=0o750, exist_ok=True)


def atomic_write(directory, name, content):
    fd, temporary = tempfile.mkstemp(prefix=".infra-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / name)
    finally:
        Path(temporary).unlink(missing_ok=True)


def validate_pack(path):
    with zipfile.ZipFile(path) as archive:
        # Reject outer UNZIP_ME bundles and unsupported metadata, never rewrite it.
        metadata = json.loads(archive.read("pack.mcmeta"))["pack"]
        def version(value):
            return tuple(value) if isinstance(value, list) else (value, 0)
        minimum = metadata.get("min_format", metadata.get("pack_format"))
        maximum = metadata.get("max_format", metadata.get("pack_format"))
        if minimum is None or maximum is None:
            raise ValueError("datapack lacks an explicit format range")
        if not version(minimum) <= (121, 0) <= version(maximum):
            raise ValueError("datapack does not support Minecraft 26.3 format 121.0")


def install(configuration):
    directory = Path(configuration["directory"])
    sources = {}
    wanted = {}
    for key, source in configuration["packs"].items():
        name = f"infra-{key}.zip"
        if not NAME.fullmatch(name):
            raise ValueError("invalid managed datapack name")
        path = Path(source)
        validate_pack(path)
        sources[name] = path
        wanted[name] = digest(path)
    safe_directory(directory)
    ledger_path = directory / LEDGER
    if ledger_path.is_symlink():
        raise ValueError("datapack ledger must not be a symlink")
    previous = json.loads(ledger_path.read_text()) if ledger_path.exists() else {}
    if not isinstance(previous, dict) or any(
        not NAME.fullmatch(name)
        or not isinstance(hashes, list)
        or not hashes
        or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes)
        for name, hashes in previous.items()
    ):
        raise ValueError("invalid managed datapack ledger")
    # Check every collision before changing anything. Never adopt an unowned file.
    for name in previous.keys() | wanted.keys():
        path = directory / name
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise ValueError(f"unsafe managed datapack path: {name}")
        if path.exists() and (name not in previous or digest(path) not in previous[name]):
            raise ValueError(f"refusing to replace an unowned or modified datapack: {name}")
    # Journal both old and desired hashes before writes. Interrupted updates can
    # resume with either archive version, including removal and first installation.
    pending = {name: list(hashes) for name, hashes in previous.items()}
    for name, value in wanted.items():
        pending[name] = sorted(set(pending.get(name, []) + [value]))
    atomic_write(directory, LEDGER, (json.dumps(pending, sort_keys=True) + "\n").encode())
    for name, source in sources.items():
        path = directory / name
        if not path.exists() or digest(path) != wanted[name]:
            # Copy archive bytes so the world backup contains packs, not store links.
            atomic_write(directory, name, source.read_bytes())
    for name in previous.keys() - wanted.keys():
        (directory / name).unlink(missing_ok=True)
    installed = {name: [value] for name, value in wanted.items()}
    atomic_write(directory, LEDGER, (json.dumps(installed, sort_keys=True) + "\n").encode())


def build(files, output):
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, content.encode())


if __name__ == "__main__":
    action, filename, *arguments = sys.argv[1:]
    configuration = json.loads(Path(filename).read_text())
    if action == "build" and len(arguments) == 1:
        build(configuration, arguments[0])
    elif action == "install" and not arguments:
        if os.geteuid() == 0:
            raise PermissionError("datapack preparation must run as the Minecraft unit user")
        install(configuration)
    else:
        raise ValueError("expected build FILE OUTPUT or install FILE")
