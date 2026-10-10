"""Bounded Minecraft status requests and a cross-process player-count cache."""

import fcntl
import json
import math
import os
import socket
import stat
import struct
import tempfile
import time
from pathlib import Path

STATUS_TTL = 20


def varint(value):
    encoded = bytearray()
    while value >= 128:
        encoded.append((value & 127) | 128)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def read_exact(connection, size, deadline):
    result = bytearray()
    while len(result) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Minecraft status response timed out")
        connection.settimeout(remaining)
        part = connection.recv(size - len(result))
        if not part:
            raise ValueError("short Minecraft status packet")
        result.extend(part)
    return bytes(result)


def read_varint(connection, deadline):
    result = 0
    for index in range(5):
        byte = read_exact(connection, 1, deadline)[0]
        result |= (byte & 127) << (index * 7)
        if byte < 128:
            return result
    raise ValueError("oversized Minecraft varint")


def minecraft_players(port):
    """Use status state, never login, on an awake direct or isolated proxy port."""
    with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
        connection.settimeout(2)
        deadline = time.monotonic() + 2
        handshake = (
            b"\x00" + varint(777) + b"\x09localhost" + struct.pack(">H", port) + b"\x01"
        )
        connection.sendall(varint(len(handshake)) + handshake + b"\x01\x00")
        length = read_varint(connection, deadline)
        if not 2 <= length <= 65536:
            raise ValueError("invalid Minecraft packet size")
        packet = read_exact(connection, length, deadline)
        if packet[0] != 0:
            raise ValueError("unexpected Minecraft status packet")
        size, offset = 0, 1
        for index in range(5):
            if offset >= len(packet):
                raise ValueError("short Minecraft string length")
            byte = packet[offset]
            offset += 1
            size |= (byte & 127) << (7 * index)
            if byte < 128:
                break
        else:
            raise ValueError("oversized Minecraft string")
        if size != len(packet) - offset:
            raise ValueError("invalid Minecraft JSON length")
        try:
            response = json.loads(packet[offset:])
        except RecursionError:
            raise ValueError("overly nested Minecraft status object") from None
        if not isinstance(response, dict) or not isinstance(
            response.get("players"), dict
        ):
            raise ValueError("invalid Minecraft status object")  # noqa: TRY004
        players = response["players"].get("online")
        if type(players) is not int or players < 0:
            raise ValueError("invalid player count")
        return players


def read_cache(directory_fd, name):
    try:
        fd = os.open(
            name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd
        )
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise OSError("unsafe Minecraft status cache file")
        if info.st_size > 4096:
            return None
        try:
            value = json.loads(stream.read(4097))
        except (ValueError, RecursionError):
            return None
    if not isinstance(value, dict):
        return None
    updated = value.get("updated")
    players = value.get("players")
    try:
        valid_updated = type(updated) in (int, float) and math.isfinite(updated)
    except OverflowError:
        valid_updated = False
    if not valid_updated or not (
        players is None or type(players) is int and players >= 0
    ):
        return None
    return value


def publish_cache(directory, directory_fd, name, value):
    data = json.dumps(value).encode()
    if len(data) > 4096:
        raise ValueError("oversized Minecraft status cache")
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".status-")
    try:
        with os.fdopen(fd, "wb") as stream:
            # The setgid directory supplies the shared dashboard group, even
            # when root metrics refreshes a file under its restrictive umask.
            os.fchmod(stream.fileno(), 0o660)
            stream.write(data)
        os.replace(
            Path(temporary).name, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd
        )
    finally:
        Path(temporary).unlink(missing_ok=True)


def cached_players(directory, identifier, generation, port):
    """Cache failed attempts too; unavailable storage never causes extra probes."""
    directory_fd = lock_fd = None
    try:
        directory = Path(directory)
        for ancestor in [*directory.parents, directory]:
            if ancestor.is_symlink():
                raise OSError("Minecraft status cache directory is a symlink")
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        name = identifier + ".json"
        lock_name = identifier + ".lock"
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            lock_fd = os.open(
                lock_name, flags | os.O_CREAT | os.O_EXCL, 0o660, dir_fd=directory_fd
            )
            os.fchmod(lock_fd, 0o660)
        except FileExistsError:
            lock_fd = os.open(lock_name, flags, dir_fd=directory_fd)
        info = os.fstat(lock_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise OSError("unsafe Minecraft status cache lock")
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        cached = read_cache(directory_fd, name)
        now = time.monotonic()
        if (
            cached is not None
            and cached.get("generation") == generation
            and 0 <= now - cached["updated"] < STATUS_TTL
        ):
            return cached["players"]
        value = {"generation": generation, "updated": now, "players": None}
        # Reserve the attempt before connecting. A crash or failed publication
        # of the result leaves an unknown count rather than a retry storm.
        publish_cache(directory, directory_fd, name, value)
        try:
            value["players"] = minecraft_players(port)
        except (OSError, ValueError):
            return None
        publish_cache(directory, directory_fd, name, value)
        return value["players"]
    except (OSError, ValueError):
        return None
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        if directory_fd is not None:
            os.close(directory_fd)
