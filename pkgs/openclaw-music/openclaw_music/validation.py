from __future__ import annotations

import hashlib
import json
import math
import os
import selectors
import shutil
import stat
import subprocess
import tempfile
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

from .errors import Configuration, InvalidInput

COPY_BLOCK = 64 * 1024
MAX_TOOL_OUTPUT = 64 * 1024
LOSSLESS_CODECS = {
    "flac",
    "alac",
    "wav",
    "wavpack",
    "ape",
    "pcm_s16le",
    "pcm_s24le",
    "pcm_s32le",
    "pcm_f32le",
}


def _safe_component(value: str) -> str:
    if (
        not value
        or value in {".", ".."}
        or "/" in value
        or "\\" in value
        or "\x00" in value
    ):
        raise InvalidInput("unsafe expected completed path")
    return value


def slskd_sanitized(value: str) -> str:
    # slskd v0.26 FileSafety on Linux preserves legal punctuation and whitespace.
    # Remote-path validation has already rejected traversal; only separators/NUL
    # and dot components are unsafe as a local path component.
    return _safe_component(value)


def expected_completed_relative(remote: str) -> Path:
    parts = remote.split("/")
    if len(parts) < 2:
        raise InvalidInput("source directory layout requires a remote directory")
    return Path(slskd_sanitized(parts[-2]), slskd_sanitized(parts[-1]))


def expected_batch_relative(job_id: str, remote: str) -> Path:
    try:
        if str(uuid.UUID(job_id)) != job_id:
            raise ValueError
    except ValueError as exc:
        raise InvalidInput("invalid batch destination id") from exc
    basename = remote.replace("\\", "/").rsplit("/", 1)[-1]
    return Path("openclaw", job_id, slskd_sanitized(basename))


def _open_relative(root: Path, relative: Path) -> tuple[int, os.stat_result]:
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = root_fd
    try:
        parts = relative.parts
        for part in parts[:-1]:
            next_fd = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
            )
            if fd != root_fd:
                os.close(fd)
            fd = next_fd
        source_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        info = os.fstat(source_fd)
        if not stat.S_ISREG(info.st_mode):
            os.close(source_fd)
            raise InvalidInput("completed transfer is not a regular file")
        return source_fd, info
    finally:
        if fd != root_fd:
            os.close(fd)
        os.close(root_fd)


def _fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _local_name(item: dict) -> str:
    extension = (
        item["remote"].rsplit(".", 1)[-1].casefold() if "." in item["remote"] else ""
    )
    if extension not in {
        "flac",
        "alac",
        "wav",
        "ape",
        "wv",
        "mp3",
        "aac",
        "ogg",
        "m4a",
        "opus",
        "wma",
    }:
        raise InvalidInput("unsupported audio extension")
    return f"{item['disc']:02d}-{item['track']:02d}.{extension}"


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(COPY_BLOCK):
            digest.update(block)
    return digest.hexdigest()


def _manifest_item(item: dict, name: str, size: int, sha256: str) -> dict:
    manifest = {
        "name": name,
        "size": size,
        "sha256": sha256,
        "disc": item["disc"],
        "track": item["track"],
        "recording_mbid": item["recording_mbid"],
        "duration_ms": item["duration_ms"],
    }
    if "expected_tags" in item:
        manifest["expected_tags"] = item["expected_tags"]
    return manifest


def _adopt_publication(
    final: Path, files: list[dict], validator, policy: dict | None
) -> tuple[list[dict], list[dict]]:
    expected = {_local_name(item): item for item in files}
    if final.is_symlink() or not final.is_dir():
        raise InvalidInput("existing staging publication is unsafe")
    entries = list(final.iterdir())
    if {entry.name for entry in entries} != set(expected):
        raise InvalidInput("existing staging publication does not match capture intent")
    manifest = []
    for entry in entries:
        info = entry.lstat()
        item = expected[entry.name]
        if (
            entry.is_symlink()
            or not stat.S_ISREG(info.st_mode)
            or info.st_size != item["size"]
        ):
            raise InvalidInput(
                "existing staging publication does not match capture intent"
            )
        manifest.append(
            _manifest_item(item, entry.name, info.st_size, _hash_file(entry))
        )
    manifest.sort(key=lambda item: (item["disc"], item["track"]))
    measurements = (
        validator.validate(final, manifest, policy or {})
        if validator is not None
        else []
    )
    return manifest, measurements


def _write_all(fd: int, block: bytes) -> None:
    offset = 0
    while offset < len(block):
        written = os.write(fd, block[offset:])
        if written <= 0:
            raise InvalidInput("capture write failed")
        offset += written


def capture(
    root: str | Path,
    stage: str | Path,
    job_id: str,
    files: list[dict],
    *,
    max_bytes: int,
    validator=None,
    policy: dict | None = None,
    copy_timeout: float = 120.0,
) -> tuple[Path, list[dict], list[dict]]:
    root = Path(root)
    stage = Path(stage)
    if root.is_symlink() or stage.is_symlink():
        raise InvalidInput("unsafe capture root")
    stage.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(stage, 0o700)
    final = stage / job_id
    if final.exists() or final.is_symlink():
        manifest, measurements = _adopt_publication(final, files, validator, policy)
        return final, manifest, measurements
    temporary = Path(tempfile.mkdtemp(prefix=f".{job_id}-", dir=stage))
    manifest = []
    copied = 0
    deadline = time.monotonic() + copy_timeout
    try:
        for item in sorted(files, key=lambda entry: (entry["disc"], entry["track"])):
            relative = Path(item["expected_relative"])
            source_fd, before = _open_relative(root, relative)
            try:
                if before.st_size != item["size"] or before.st_size < 1:
                    raise InvalidInput("completed transfer size does not match intent")
                if item.get("requested_at"):
                    try:
                        requested = datetime.fromisoformat(item["requested_at"])
                    except ValueError as exc:
                        raise InvalidInput("invalid transfer intent timestamp") from exc
                    if requested.tzinfo is None:
                        requested = requested.replace(tzinfo=UTC)
                    if min(before.st_ctime_ns, before.st_mtime_ns) < int(
                        requested.timestamp() * 1_000_000_000
                    ):
                        raise InvalidInput("completed transfer predates queue intent")
                copied += before.st_size
                if copied > max_bytes:
                    raise InvalidInput("capture exceeds byte limit")
                name = _local_name(item)
                target_fd = os.open(
                    temporary / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
                )
                digest = hashlib.sha256()
                remaining = before.st_size
                try:
                    while True:
                        if time.monotonic() > deadline:
                            raise InvalidInput("capture timed out")
                        block = os.read(source_fd, min(COPY_BLOCK, remaining + 1))
                        if not block:
                            break
                        if len(block) > remaining:
                            raise InvalidInput("completed transfer grew during capture")
                        digest.update(block)
                        _write_all(target_fd, block)
                        remaining -= len(block)
                    if remaining != 0:
                        raise InvalidInput("completed transfer was shorter than intent")
                    os.fsync(target_fd)
                finally:
                    os.close(target_fd)
                after = os.fstat(source_fd)
                if (
                    before.st_ino,
                    before.st_size,
                    before.st_mtime_ns,
                    before.st_ctime_ns,
                ) != (
                    after.st_ino,
                    after.st_size,
                    after.st_mtime_ns,
                    after.st_ctime_ns,
                ):
                    raise InvalidInput("completed transfer changed during capture")
                manifest.append(
                    _manifest_item(item, name, before.st_size, digest.hexdigest())
                )
            finally:
                os.close(source_fd)
        measurements = (
            validator.validate(temporary, manifest, policy or {})
            if validator is not None
            else []
        )
        _fsync_directory(temporary)
        os.replace(temporary, final)
        _fsync_directory(stage)
        return final, manifest, measurements
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


class AudioValidator:
    def __init__(self, ffprobe: str, ffmpeg: str, run=subprocess.run):
        if not Path(ffprobe).is_absolute() or not Path(ffmpeg).is_absolute():
            raise Configuration("audio executables must be absolute")
        self.ffprobe = ffprobe
        self.ffmpeg = ffmpeg
        self.run = run

    def _run(self, arguments: list[str]):
        environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": "/nonexistent",
            "LANG": "C",
            "LC_ALL": "C",
        }
        if self.run is subprocess.run:
            process = subprocess.Popen(
                arguments,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
            )
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            output = {"stdout": bytearray(), "stderr": bytearray()}
            deadline = time.monotonic() + 60
            try:
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(arguments, 60)
                    for key, _ in selector.select(remaining):
                        block = os.read(key.fileobj.fileno(), 65_536)
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        output[key.data].extend(block)
                        if len(output[key.data]) > MAX_TOOL_OUTPUT:
                            raise InvalidInput("audio tool output exceeded limit")
                returncode = process.wait(timeout=max(0.1, deadline - time.monotonic()))
            except (InvalidInput, subprocess.TimeoutExpired) as exc:
                process.kill()
                process.wait()
                if isinstance(exc, InvalidInput):
                    raise
                raise InvalidInput("audio tool failed") from exc
            finally:
                selector.close()
                if process.stdout:
                    process.stdout.close()
                if process.stderr:
                    process.stderr.close()
            return type(
                "Result",
                (),
                {
                    "returncode": returncode,
                    "stdout": output["stdout"].decode("utf-8", "replace"),
                    "stderr": output["stderr"].decode("utf-8", "replace"),
                },
            )()
        try:
            result = self.run(
                arguments,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
                stdin=subprocess.DEVNULL,
                env=environment,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise InvalidInput("audio tool failed") from exc
        if (
            len(result.stdout or "") > MAX_TOOL_OUTPUT
            or len(result.stderr or "") > MAX_TOOL_OUTPUT
        ):
            raise InvalidInput("audio tool output exceeded limit")
        return result

    def inspect(self, path: Path) -> dict:
        result = self._run(
            [
                self.ffprobe,
                "-v",
                "error",
                "-protocol_whitelist",
                "file",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                str(path),
            ]
        )
        try:
            metadata = json.loads(result.stdout)
            streams = [
                stream
                for stream in metadata["streams"]
                if stream.get("codec_type") == "audio"
            ]
            audio = streams[0]
            duration = float(metadata["format"]["duration"])
            sample_rate = int(audio["sample_rate"])
            channels = int(audio["channels"])
        except (
            KeyError,
            TypeError,
            ValueError,
            IndexError,
            json.JSONDecodeError,
        ) as exc:
            raise InvalidInput("invalid audio metadata") from exc
        if (
            result.returncode
            or len(streams) != 1
            or not math.isfinite(duration)
            or not 0 < duration <= 86_400
        ):
            raise InvalidInput("invalid audio metadata")
        if not 1 <= sample_rate <= 384_000 or not 1 <= channels <= 16:
            raise InvalidInput("invalid audio metadata")
        decoded = self._run(
            [
                self.ffmpeg,
                "-nostdin",
                "-xerror",
                "-v",
                "error",
                "-protocol_whitelist",
                "file,pipe",
                "-i",
                str(path),
                "-map",
                "0:a:0",
                "-f",
                "null",
                "-",
            ]
        )
        if decoded.returncode:
            raise InvalidInput("audio decode failed")
        return {
            "codec": str(audio.get("codec_name", "")).casefold(),
            "duration": duration,
            "sample_rate": sample_rate,
            "channels": channels,
            "bit_depth": audio.get("bits_per_raw_sample"),
            "tags": self._tags(metadata, audio),
        }

    @staticmethod
    def _tags(metadata: dict, audio: dict) -> dict[str, list[str]]:
        tags = {}
        for source in (
            metadata.get("format", {}).get("tags", {}),
            audio.get("tags", {}),
        ):
            if not isinstance(source, dict):
                continue
            for key, value in source.items():
                if isinstance(key, str) and isinstance(value, str):
                    tags.setdefault(key, []).append(value)
        return tags

    def validate(
        self, directory: str | Path, manifest: list[dict], policy: dict
    ) -> list[dict]:
        if (
            not isinstance(manifest, list)
            or not manifest
            or len(manifest) > policy["max_files"]
        ):
            raise InvalidInput("manifest limits")
        if sum(item["size"] for item in manifest) > policy["max_bytes"]:
            raise InvalidInput("manifest limits")
        values = [self.inspect(Path(directory) / item["name"]) for item in manifest]
        for item, value in zip(manifest, values, strict=True):
            expected = item.get("expected_tags")
            if expected is None:
                continue
            if not isinstance(expected, dict):
                raise InvalidInput("invalid expected audio tags")
            tags = {}
            for key, raw_values in value.get("tags", {}).items():
                tag_values = (
                    raw_values if isinstance(raw_values, list) else [raw_values]
                )
                tags.setdefault(str(key).casefold().replace("_", ""), []).extend(
                    str(tag).strip() for tag in tag_values if isinstance(tag, str)
                )
            for key, wanted in expected.items():
                if set(tags.get(key.casefold().replace("_", ""), [])) != {wanted}:
                    raise InvalidInput(
                        "captured audio tags do not match the frozen release"
                    )
        if policy["profile"] == "lossless" and any(
            value["codec"] not in LOSSLESS_CODECS for value in values
        ):
            raise InvalidInput("lossy release violates frozen policy")
        if (
            policy["profile"] == "lossless-preferred"
            and not policy.get("accepted_lossy")
            and any(value["codec"] not in LOSSLESS_CODECS for value in values)
        ):
            raise InvalidInput("lossy release was not explicitly accepted")
        fallback = policy.get("accepted_lossy")
        if fallback:
            extensions = {Path(item["name"]).suffix[1:].casefold() for item in manifest}
            if len(manifest) < fallback["minimum_tracks"] or not extensions <= set(
                fallback["extensions"]
            ):
                raise InvalidInput("lossy release violates accepted fallback")
        return values
