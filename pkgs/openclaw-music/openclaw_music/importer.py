from __future__ import annotations

import fcntl
import os
import stat
import subprocess
from contextlib import contextmanager
from pathlib import Path
from typing import Protocol, TypedDict

from .errors import (
    BackendTransient,
    BackendUncertain,
    BeetsNoImport,
    Configuration,
    InvalidInput,
)


class ImportIdentity(TypedDict):
    job_id: str
    release_mbid: str
    manifest_digest: str
    behavior: str
    expected_tracks: list[dict]
    policy: dict
    selected_quality: str


class ImportReceipt(ImportIdentity):
    receipt_id: str
    album_id: str
    items: list[dict]
    final_paths: list[str]
    success: bool


class ImportAdapter(Protocol):
    behavior_identity: str

    def reconcile_import(
        self, identity: ImportIdentity
    ) -> tuple[str, ImportReceipt | None]: ...
    def import_album(self, plan: dict, identity: ImportIdentity) -> ImportReceipt: ...


MAX_OUTPUT = 64 * 1024
DIAGNOSTIC = 512
ROW_FIELDS = (
    "id",
    "album_id",
    "disc",
    "track",
    "mb_albumid",
    "path",
    "openclaw_job_id",
    "openclaw_manifest_digest",
    "openclaw_behavior",
)
FORMAT = "|".join("$" + field for field in ROW_FIELDS)


class DirectBeetsImportAdapter:
    """Fixed stock-beet adapter; database evidence is authoritative, not --set."""

    behavior_identity = "openclaw-beets-cli-v1"

    def __init__(
        self,
        executable: str,
        config: str,
        lock_path: str,
        staging_root: str,
        library_root: str | None,
        beets_home: str,
        beets_path: str,
        beets_cache: str,
        validator=None,
        *,
        run=subprocess.run,
    ):
        paths = (
            executable,
            config,
            lock_path,
            staging_root,
            library_root,
            beets_home,
            beets_cache,
        )
        if not all(isinstance(path, str) and os.path.isabs(path) for path in paths):
            raise Configuration("beets adapter paths must be trusted absolute paths")
        if not beets_path or any(
            not os.path.isabs(path) for path in beets_path.split(":")
        ):
            raise Configuration("beets PATH must contain only trusted absolute paths")
        self.executable = executable
        self.config = config
        self.lock_path = lock_path
        self.staging_root = os.path.realpath(staging_root)
        self.library_root = os.path.realpath(library_root)
        self.environment = {
            "HOME": beets_home,
            "PATH": beets_path,
            "LANG": "C",
            "LC_ALL": "C",
            "BEETSDIR": str(Path(config).parent),
            "XDG_CONFIG_HOME": str(Path(config).parent.parent),
            "XDG_CACHE_HOME": beets_cache,
        }
        self.run = run
        self.validator = validator

    @contextmanager
    def _locked(self):
        fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    @staticmethod
    def _excerpt(output: str) -> str:
        return (
            output.replace("\x00", "?")
            .replace("\r", " ")
            .replace("\n", " ")
            .strip()[-DIAGNOSTIC:]
        )

    @staticmethod
    def _output_text(value: object) -> str:
        if isinstance(value, bytes):
            return value.decode("utf-8", "replace")
        return value if isinstance(value, str) else ""

    def _run_unlocked(self, argv: list[str], *, mutation: bool = False):
        try:
            # subprocess.run kills and waits for its child on TimeoutExpired.
            result = self.run(
                argv,
                text=True,
                capture_output=True,
                timeout=120,
                env=self.environment,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            excerpt = self._excerpt(
                self._output_text(exc.stdout) + "\n" + self._output_text(exc.stderr)
            )
            if mutation:
                raise BackendUncertain(
                    "beets invocation timed out" + (": " + excerpt if excerpt else "")
                ) from exc
            raise BackendTransient(
                "beets list timed out" + (": " + excerpt if excerpt else "")
            ) from exc
        except OSError as exc:
            if mutation:
                raise BackendUncertain(
                    "beets invocation could not be confirmed"
                ) from exc
            raise BackendTransient("beets CLI is temporarily unavailable") from exc
        output = (result.stdout or "") + "\n" + (result.stderr or "")
        if len(output.encode("utf-8", "replace")) > MAX_OUTPUT:
            if mutation:
                raise BackendUncertain("beets invocation output exceeded limit")
            raise BackendTransient("beets list output exceeded limit")
        return result, output

    def _query_unlocked(self, query: str) -> list[dict]:
        result, output = self._run_unlocked(
            [self.executable, "-c", self.config, "list", "-f", FORMAT, query]
        )
        if result.returncode:
            detail = self._excerpt(output)
            raise BackendTransient(
                "beets list query failed" + (": " + detail if detail else "")
            )
        rows = []
        for line in (result.stdout or "").splitlines():
            if not line:
                continue
            if any(ord(char) < 32 for char in line):
                raise InvalidInput("beets list row contains control characters")
            values = line.split("|")
            if len(values) != len(ROW_FIELDS):
                raise InvalidInput("beets list row is malformed")
            row = dict(zip(ROW_FIELDS, values, strict=True))
            if (
                not row["id"]
                or not row["album_id"]
                or not row["disc"].isdigit()
                or not row["track"].isdigit()
            ):
                raise InvalidInput("beets list row is incomplete")
            rows.append(row)
        return rows

    def _usable_path(self, value: str) -> str | None:
        path = Path(value)
        if not path.is_absolute():
            return None
        try:
            info = path.lstat()
            resolved = path.resolve(strict=True)
            fd = os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return None
        try:
            if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_size < 1:
                return None
        finally:
            os.close(fd)
        if Path(self.library_root) not in resolved.parents:
            return None
        return str(resolved)

    def _receipt(
        self, identity: ImportIdentity, rows: list[dict], *, correlated: bool
    ) -> ImportReceipt | None:
        expected = {
            (int(track["disc"]), int(track["track"])): track
            for track in identity["expected_tracks"]
        }
        if not expected or len(expected) != len(identity["expected_tracks"]):
            raise InvalidInput("invalid expected manifest mapping")
        if len(rows) != len(expected) or len({row["id"] for row in rows}) != len(rows):
            return None
        album_ids = {row["album_id"] for row in rows}
        if (
            len(album_ids) != 1
            or not next(iter(album_ids))
            or any(row["mb_albumid"] != identity["release_mbid"] for row in rows)
        ):
            return None
        mapping = {(int(row["disc"]), int(row["track"])): row for row in rows}
        if set(mapping) != set(expected):
            return None
        items, paths = [], []
        for key in sorted(expected):
            row = mapping[key]
            final_path = self._usable_path(row["path"])
            if final_path is None or final_path in paths:
                return None
            if correlated and (
                row["openclaw_job_id"] != identity["job_id"]
                or row["openclaw_manifest_digest"] != identity["manifest_digest"]
                or row["openclaw_behavior"] != identity["behavior"]
            ):
                return None
            items.append(
                {
                    "id": row["id"],
                    "source_name": expected[key]["name"],
                    "final_path": final_path,
                }
            )
            paths.append(final_path)
        if self.validator is None:
            return None
        try:
            measurements = [self.validator.inspect(Path(path)) for path in paths]
        except (InvalidInput, OSError, TypeError, ValueError):
            return None
        if any(
            not isinstance(value, dict) or not isinstance(value.get("codec"), str)
            for value in measurements
        ):
            return None
        policy = identity["policy"]
        if (
            policy["profile"] in {"lossless", "lossless-preferred"}
            and not policy.get("accepted_lossy")
            and any(
                value["codec"].casefold()
                not in {
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
                for value in measurements
            )
        ):
            return None
        receipt = {
            **identity,
            "receipt_id": "beets:" + next(iter(album_ids)),
            "album_id": next(iter(album_ids)),
            "items": items,
            "final_paths": paths,
            "success": True,
        }
        if not correlated:
            receipt["reused_existing"] = True
        return receipt

    def _reconcile_unlocked(
        self, identity: ImportIdentity
    ) -> tuple[str, ImportReceipt | None]:
        rows = self._query_unlocked("openclaw_job_id:" + identity["job_id"])
        if rows:
            receipt = self._receipt(identity, rows, correlated=True)
            return ("complete", receipt) if receipt else ("needs_review", None)
        existing = self._query_unlocked("mb_albumid:" + identity["release_mbid"])
        if not existing:
            return "not_started", None
        receipt = self._receipt(identity, existing, correlated=False)
        return ("complete", receipt) if receipt else ("needs_review", None)

    def reconcile_import(
        self, identity: ImportIdentity
    ) -> tuple[str, ImportReceipt | None]:
        with self._locked():
            return self._reconcile_unlocked(identity)

    def import_album(self, plan: dict, identity: ImportIdentity) -> ImportReceipt:
        stage = os.path.realpath(str(plan.get("stage", "")))
        if os.path.commonpath((self.staging_root, stage)) != self.staging_root:
            raise InvalidInput("beets stage is outside trusted staging root")
        with self._locked():
            outcome, receipt = self._reconcile_unlocked(identity)
            if outcome == "complete":
                assert receipt is not None
                return receipt
            if outcome != "not_started":
                raise InvalidInput("beets import requires review")
            argv = [
                self.executable,
                "-c",
                self.config,
                "import",
                "--quiet",
                "--quiet-fallback",
                "skip",
                "--search-id",
                identity["release_mbid"],
                "--set",
                "openclaw_job_id=" + identity["job_id"],
                "--set",
                "openclaw_manifest_digest=" + identity["manifest_digest"],
                "--set",
                "openclaw_behavior=" + identity["behavior"],
                stage,
            ]
            result, output = self._run_unlocked(argv, mutation=True)
            if result.returncode:
                detail = self._excerpt(output)
                error = BackendUncertain(
                    f"beets invocation failed (exit {result.returncode})"
                    + (": " + detail if detail else "")
                )
                raise error
            outcome, receipt = self._reconcile_unlocked(identity)
            if outcome != "complete" or receipt is None:
                raise BeetsNoImport()
            return receipt
