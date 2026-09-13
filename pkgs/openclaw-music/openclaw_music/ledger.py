from __future__ import annotations

import fcntl
import json
import os
import stat
import tempfile
from contextlib import contextmanager
from pathlib import Path

from .errors import Configuration, Temporary, Unknown
from .models import parse_uuid


def _check(path: Path, *, directory: bool, mode: int) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(info.st_mode) or (directory and not stat.S_ISDIR(info.st_mode)):
        raise Configuration(f"unsafe ledger path: {path.name}")
    if not directory and not stat.S_ISREG(info.st_mode):
        raise Configuration(f"unsafe ledger file: {path.name}")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != mode:
        raise Configuration(f"unsafe ledger ownership or mode: {path.name}")


class Ledger:
    """Small JSON ledger with secure paths and deliberately short critical sections."""

    def __init__(self, root: str | Path):
        self.root = Path(root)
        if self.root.exists():
            _check(self.root, directory=True, mode=0o700)
        else:
            self.root.mkdir(mode=0o700, parents=True)
        self.jobs = self.root / "jobs"
        if self.jobs.exists():
            _check(self.jobs, directory=True, mode=0o700)
        else:
            self.jobs.mkdir(mode=0o700)
        self.lock_path = self.root / ".lock"
        self.worker_lock_path = self.root / ".worker.lock"

    @contextmanager
    def locked(self, blocking: bool = False):
        with self._locked_path(self.lock_path, blocking):
            yield

    @contextmanager
    def worker_locked(self):
        with self._locked_path(self.worker_lock_path, False):
            yield

    @contextmanager
    def _locked_path(self, path: Path, blocking: bool):
        _check(path, directory=False, mode=0o600)
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError:
                raise Temporary("ledger is busy") from None
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def _path(self, job_id: str) -> Path:
        return self.jobs / f"{parse_uuid(job_id)}.json"

    def _validate(self, job: object) -> dict:
        if not isinstance(job, dict):
            raise Temporary("ledger record has invalid shape")
        required = {
            "schema",
            "job_id",
            "revision",
            "state",
            "request",
            "raw_request",
            "policy",
            "created_at",
            "updated_at",
        }
        if set(required) - set(job) or job.get("schema") != 1:
            raise Temporary("ledger record has invalid schema")
        parse_uuid(job["job_id"])
        if (
            type(job["revision"]) is not int
            or job["revision"] < 1
            or not isinstance(job["state"], str)
        ):
            raise Temporary("ledger record has invalid fields")
        if (
            not isinstance(job["request"], dict)
            or not isinstance(job["raw_request"], dict)
            or not isinstance(job["policy"], dict)
        ):
            raise Temporary("ledger record has invalid fields")
        return job

    def get(self, job_id: str) -> dict:
        path = self._path(job_id)
        try:
            _check(path, directory=False, mode=0o600)
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, encoding="utf-8") as source:
                return self._validate(json.load(source))
        except FileNotFoundError:
            raise Unknown("unknown job") from None
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise Temporary("ledger record is unreadable") from None

    def save(self, job: dict) -> None:
        self._validate(job)
        path = self._path(job["job_id"])
        _check(path, directory=False, mode=0o600)
        fd, temporary = tempfile.mkstemp(prefix=".job-", dir=self.jobs)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump(
                    job,
                    output,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                )
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(
                self.jobs, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def all_jobs(self) -> list[dict]:
        _check(self.jobs, directory=True, mode=0o700)
        records = []
        with os.scandir(self.jobs) as entries:
            for entry in entries:
                if not entry.name.endswith(".json"):
                    continue
                if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                    raise Temporary("unsafe ledger job entry")
                records.append(self.get(entry.name[:-5]))
        return sorted(records, key=lambda job: job["job_id"])

    def find_idempotency(self, key: str) -> dict | None:
        for job in self.all_jobs():
            if job["raw_request"].get("idempotency_key") == key:
                return job
        return None
