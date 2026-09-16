from __future__ import annotations

import json
import os
import selectors
import signal
import sqlite3
import stat
import subprocess
import time
import tomllib
import uuid
from datetime import date as calendar_date
from pathlib import Path

from .errors import BackendUncertain, Configuration, InvalidInput

MAX_RESULTS_BYTES = 64 * 1024
MAX_RESULTS = 20
MAX_PROVIDER_ID = 160
MAX_DESCRIPTION = 320
MAX_DIAGNOSTIC = 240
MAX_PROCESS_OUTPUT = 64 * 1024
PROCESS_TIMEOUT = 300
MAX_DB_ROWS = 100
MAX_OUTPUT_DEPTH = 8
MAX_OUTPUT_FILES = 100
MAX_OUTPUT_ENTRIES = 500
MAX_OUTPUT_BYTES = 4_000_000_000
AUDIO_EXTENSIONS = {"flac", "alac", "wav", "ape", "wv", "m4a"}

# Complete typed ConfigData.from_toml shape for pinned Streamrip 2.2.0.
PIN_TEMPLATE = {
    "downloads": {
        "folder": "",
        "source_subdirectories": False,
        "disc_subdirectories": True,
        "concurrency": True,
        "max_connections": 6,
        "requests_per_minute": 60,
        "verify_ssl": True,
    },
    "qobuz": {
        "quality": 3,
        "download_booklets": True,
        "use_auth_token": True,
        "email_or_userid": "",
        "password_or_token": "",
        "app_id": "",
        "secrets": [],
    },
    "tidal": {
        "quality": 3,
        "download_videos": True,
        "user_id": "",
        "country_code": "",
        "access_token": "",
        "refresh_token": "",
        "token_expiry": "",
    },
    "deezer": {
        "quality": 2,
        "lower_quality_if_not_available": True,
        "arl": "",
        "use_deezloader": True,
        "deezloader_warnings": True,
    },
    "soundcloud": {"quality": 0, "client_id": "", "app_version": ""},
    "youtube": {"quality": 0, "download_videos": False, "video_downloads_folder": ""},
    "database": {
        "downloads_enabled": True,
        "downloads_path": "",
        "failed_downloads_enabled": True,
        "failed_downloads_path": "",
    },
    "conversion": {
        "enabled": False,
        "codec": "ALAC",
        "sampling_rate": 48000,
        "bit_depth": 24,
        "lossy_bitrate": 320,
    },
    "qobuz_filters": {
        "extras": False,
        "repeats": False,
        "non_albums": False,
        "features": False,
        "non_studio_albums": False,
        "non_remaster": False,
    },
    "artwork": {
        "embed": True,
        "embed_size": "large",
        "embed_max_width": -1,
        "save_artwork": True,
        "saved_max_width": -1,
    },
    "metadata": {
        "set_playlist_to_album": True,
        "renumber_playlist_tracks": True,
        "exclude": [],
    },
    "filepaths": {
        "add_singles_to_folder": False,
        "folder_format": "{albumartist} - {title} ({year}) [{container}] [{bit_depth}B-{sampling_rate}kHz]",
        "track_format": "{tracknumber:02}. {artist} - {title}{explicit}",
        "restrict_characters": False,
        "truncate_to": 120,
    },
    "lastfm": {"source": "qobuz", "fallback_source": ""},
    "cli": {"text_output": True, "progress_bars": True, "max_search_results": 100},
    "misc": {"version": "2.2.0", "check_for_updates": True},
}


def _text(value: object, limit: int, field: str) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > limit
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise InvalidInput(f"invalid Streamrip {field}")
    return value.strip()


def _provider_id(value: object) -> str:
    result = _text(value, MAX_PROVIDER_ID, "album id")
    if (
        not result.isascii()
        or not result[0].isalnum()
        or not all(character.isalnum() or character in "._:-" for character in result)
    ):
        raise InvalidInput("invalid Streamrip album id")
    return result


def _toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def _private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise Configuration("unsafe Streamrip runtime directory")
    os.chmod(path, 0o700)


def _read_regular(path: Path, limit: int) -> bytes:
    try:
        info = path.lstat()
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISREG(info.st_mode)
            or info.st_size > limit
        ):
            raise OSError
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            data = os.read(fd, limit + 1)
        finally:
            os.close(fd)
    except OSError as exc:
        raise InvalidInput("invalid Streamrip search response") from exc
    if len(data) > limit:
        raise InvalidInput("invalid Streamrip search response")
    return data


class StreamripAdapter:
    """Pinned Streamrip CLI boundary; launcher, paths, and evidence stay private."""

    def __init__(
        self,
        launcher: str,
        master_config: str,
        runtime_root: str,
        *,
        run=subprocess.run,
    ):
        if (
            not launcher
            or not Path(launcher).is_absolute()
            or Path(launcher).name == "rip"
        ):
            raise Configuration(
                "restricted Streamrip launcher must be an absolute non-rip path"
            )
        self.launcher = launcher
        self.master_config = Path(master_config)
        self.runtime_root = Path(runtime_root)
        self.run = run

    def runtime(self, job_id: str) -> dict[str, str]:
        try:
            if str(uuid.UUID(job_id)) != job_id:
                raise ValueError
        except ValueError as exc:
            raise InvalidInput("invalid Streamrip job id") from exc
        _private_directory(self.runtime_root)
        root = self.runtime_root / job_id
        _private_directory(root)
        paths = {
            "root": root,
            "output": root / "output",
            "home": root / "home",
            "xdg_config": root / "xdg-config",
            "xdg_cache": root / "xdg-cache",
            "tmp": root / "tmp",
        }
        for path in paths.values():
            _private_directory(path)
        return {
            "root": str(root),
            "config": str(root / "config.toml"),
            "output": str(paths["output"]),
            "home": str(paths["home"]),
            "xdg_config": str(paths["xdg_config"]),
            "xdg_cache": str(paths["xdg_cache"]),
            "tmp": str(paths["tmp"]),
            "downloads_db": str(root / "downloads.db"),
            "failed_downloads_db": str(root / "failed-downloads.db"),
            "search_results": str(root / "search.json"),
        }

    def _credentials(self) -> dict[str, object]:
        try:
            info = self.master_config.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                raise OSError
            with self.master_config.open("rb") as source:
                master = tomllib.load(source)
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise Configuration("Streamrip master credentials are unavailable") from exc
        qobuz = master.get("qobuz") if isinstance(master, dict) else None
        if not isinstance(qobuz, dict):
            raise Configuration("Streamrip Qobuz credentials are malformed")
        fields = {
            key: qobuz.get(key)
            for key in ("use_auth_token", "email_or_userid", "password_or_token")
        }
        if type(fields["use_auth_token"]) is not bool or not all(
            isinstance(fields[key], str) and fields[key] and "\x00" not in fields[key]
            for key in ("email_or_userid", "password_or_token")
        ):
            raise Configuration("Streamrip Qobuz credentials are malformed")
        return fields

    def establish_baseline(self, runtime: dict[str, str]) -> None:
        for key, table, schema in (
            ("downloads_db", "downloads", "id TEXT UNIQUE NOT NULL"),
            (
                "failed_downloads_db",
                "failed_downloads",
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT UNIQUE NOT NULL",
            ),
        ):
            path = Path(runtime[key])
            try:
                path.lstat()
            except FileNotFoundError:
                pass
            else:
                raise InvalidInput("Streamrip private database baseline already exists")
            try:
                connection = sqlite3.connect(path)
                connection.execute(f"CREATE TABLE {table} ({schema})")
                connection.commit()
                connection.close()
                os.chmod(path, 0o600)
            except sqlite3.Error as exc:
                raise InvalidInput(
                    "Streamrip private database baseline failed"
                ) from exc

    def adopt_baseline(self, runtime: dict[str, str]) -> None:
        if any(Path(runtime["output"]).iterdir()):
            raise InvalidInput("Streamrip output changed before download")
        if self._db_rows(Path(runtime["downloads_db"]), "downloads", ("id",)):
            raise InvalidInput("Streamrip database changed before download")
        if self._db_rows(
            Path(runtime["failed_downloads_db"]),
            "failed_downloads",
            ("source", "media_type", "id"),
        ):
            raise InvalidInput("Streamrip database changed before download")

    def write_config(self, runtime: dict[str, str]) -> None:
        credentials = self._credentials()
        config_data = {
            section: dict(values) for section, values in PIN_TEMPLATE.items()
        }
        config_data["downloads"].update(
            {
                "folder": runtime["output"],
                "source_subdirectories": False,
                "disc_subdirectories": True,
                "max_connections": 2,
                "requests_per_minute": 30,
                "verify_ssl": True,
            }
        )
        config_data["database"].update(
            {
                "downloads_path": runtime["downloads_db"],
                "failed_downloads_path": runtime["failed_downloads_db"],
            }
        )
        config_data["qobuz"].update(
            credentials | {"quality": 3, "download_booklets": False}
        )
        config_data["artwork"].update({"embed": False, "save_artwork": False})
        config_data["cli"].update({"text_output": False, "progress_bars": False})
        config_data["misc"]["check_for_updates"] = False
        lines = []
        for section, values in config_data.items():
            lines.append(f"[{section}]")
            for key, value in values.items():
                encoded = (
                    _toml_string(value) if isinstance(value, str) else json.dumps(value)
                )
                lines.append(f"{key} = {encoded}")
            lines.append("")
        config = Path(runtime["config"])
        fd = os.open(
            config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600
        )
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, ("\n".join(lines) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)

    def _environment(self, runtime: dict[str, str]) -> dict[str, str]:
        return {
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "HOME": runtime["home"],
            "XDG_CONFIG_HOME": runtime["xdg_config"],
            "XDG_CACHE_HOME": runtime["xdg_cache"],
            "TMPDIR": runtime["tmp"],
        }

    @staticmethod
    def _kill_group(process) -> bool:
        pgid = process.pid

        def gone() -> bool:
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                return True
            return False

        try:
            if gone():
                process.wait(timeout=0.1)
                return True
            os.killpg(pgid, signal.SIGTERM)
            until = time.monotonic() + 2
            while time.monotonic() < until:
                if gone():
                    process.wait(timeout=0.1)
                    return True
                time.sleep(0.02)
            os.killpg(pgid, signal.SIGKILL)
            until = time.monotonic() + 2
            while time.monotonic() < until:
                if gone():
                    process.wait(timeout=0.1)
                    return True
                time.sleep(0.02)
        except ProcessLookupError:
            process.wait(timeout=0.1)
            return True
        try:
            process.wait(timeout=0.1)
        except subprocess.TimeoutExpired:
            pass
        return False

    def _run(self, runtime: dict[str, str], argv: list[str]) -> tuple[int, str]:
        if self.run is not subprocess.run:
            try:
                result = self.run(
                    argv,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=PROCESS_TIMEOUT,
                    stdin=subprocess.DEVNULL,
                    env=self._environment(runtime),
                )
            except OSError as exc:
                raise Configuration("Streamrip launcher could not start") from exc
            except subprocess.TimeoutExpired as exc:
                raise BackendUncertain(
                    "Streamrip invocation acknowledgement is missing"
                ) from exc
            output = str(getattr(result, "stdout", "") or "") + str(
                getattr(result, "stderr", "") or ""
            )
            if len(output) > MAX_PROCESS_OUTPUT:
                raise BackendUncertain(
                    "Streamrip invocation acknowledgement is missing"
                )
            return int(result.returncode), str(getattr(result, "stderr", "") or "")[
                :MAX_DIAGNOSTIC
            ]
        try:
            process = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self._environment(runtime),
                start_new_session=True,
            )
        except OSError as exc:
            raise Configuration("Streamrip launcher could not start") from exc
        selector = None
        quiescent = False
        try:
            # From this point every setup failure owns a live process group.
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            selector.register(process.stderr, selectors.EVENT_READ)
            captured = bytearray()
            deadline = time.monotonic() + PROCESS_TIMEOUT
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(argv, PROCESS_TIMEOUT)
                for key, _ in selector.select(remaining):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    captured.extend(block)
                    if len(captured) > MAX_PROCESS_OUTPUT:
                        raise InvalidInput("Streamrip process output exceeded limit")
            code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except BaseException as exc:
            raise BackendUncertain(
                "Streamrip invocation acknowledgement is missing"
            ) from exc
        finally:
            quiescent = self._kill_group(process)
            if selector is not None:
                selector.close()
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()
        if not quiescent:
            raise BackendUncertain("Streamrip invocation acknowledgement is missing")
        return code, captured.decode("utf-8", "replace")[-MAX_DIAGNOSTIC:]

    def search(
        self, runtime: dict[str, str], query: str, count: int = MAX_RESULTS
    ) -> list[dict]:
        results = Path(runtime["search_results"])
        try:
            results.unlink()
        except FileNotFoundError:
            pass
        code, _ = self._run(
            runtime,
            [
                self.launcher,
                "--config-path",
                runtime["config"],
                "search",
                "--output-file",
                runtime["search_results"],
                "--num-results",
                str(count),
                "qobuz",
                "album",
                query,
            ],
        )
        if code:
            raise InvalidInput("Streamrip search failed")
        try:
            data = json.loads(_read_regular(results, MAX_RESULTS_BYTES).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError, InvalidInput):
            raise InvalidInput("invalid Streamrip search response") from None
        if not isinstance(data, list) or not data or len(data) > count:
            raise InvalidInput("invalid Streamrip search response")
        by_id = {}
        for item in data:
            if (
                not isinstance(item, dict)
                or set(item) != {"source", "media_type", "id", "desc"}
                or item["source"] != "qobuz"
                or item["media_type"] != "album"
            ):
                raise InvalidInput("invalid Streamrip search response")
            provider_id = _provider_id(item["id"])
            description = _text(item["desc"], MAX_DESCRIPTION, "description")
            if provider_id in by_id and by_id[provider_id] != description:
                raise InvalidInput("conflicting Streamrip search result")
            by_id[provider_id] = description
        descriptions = list(by_id.values())
        return [
            {
                "provider_id": key,
                "description": value,
                "indistinguishable": descriptions.count(value) > 1,
            }
            for key, value in sorted(
                by_id.items(), key=lambda entry: (entry[1].casefold(), entry[0])
            )
        ]

    def download(self, runtime: dict[str, str], provider_id: str) -> tuple[int, str]:
        return self._run(
            runtime,
            [
                self.launcher,
                "--config-path",
                runtime["config"],
                "--folder",
                runtime["output"],
                "--quality",
                "3",
                "--no-progress",
                "id",
                "qobuz",
                "album",
                _provider_id(provider_id),
            ],
        )

    @staticmethod
    def description_matches(description: str, release: dict) -> bool:
        # The only accepted sparse form is the provider display title followed by
        # the artist; parentheses/descriptions are edition evidence we cannot prove.
        expected = f"{release['title']} by {release['artist']}"
        normalize = lambda value: " ".join(value.casefold().split())
        return normalize(description) == normalize(expected)

    @staticmethod
    def edition_compatible(release: object) -> bool:
        if not isinstance(release, dict) or not isinstance(
            release.get("details"), dict
        ):
            return False
        details = release["details"]
        media = details.get("media")
        if (
            not isinstance(details.get("date"), str)
            or not details["date"]
            or not isinstance(media, list)
            or not media
        ):
            return False
        formats = [item.get("format") for item in media if isinstance(item, dict)]
        if not formats or any(
            not isinstance(value, str)
            or value.casefold() not in {"digital media", "digital"}
            for value in formats
        ):
            return False
        return not any(
            str(details.get(key, "")).strip() for key in ("disambiguation", "packaging")
        )

    @staticmethod
    def _tag_values(tags: object, aliases: tuple[str, ...]) -> list[str]:
        if not isinstance(tags, dict):
            return []
        normalized = {}
        for key, value in tags.items():
            name = str(key).casefold().replace("_", "").replace(" ", "")
            values = value if isinstance(value, list) else [value]
            normalized.setdefault(name, []).extend(
                str(item).strip()
                for item in values
                if isinstance(item, str) and str(item).strip()
            )
        return [item for key in aliases for item in normalized.get(key, [])]

    @staticmethod
    def _number(values: list[str], number: int, total: int | None, field: str) -> None:
        parsed = []
        for value in values:
            pieces = [part.strip() for part in value.split("/", 1)]
            if not pieces[0].isdigit() or (
                len(pieces) == 2 and not pieces[1].isdigit()
            ):
                raise InvalidInput("Streamrip attribution is invalid")
            parsed.append(
                (int(pieces[0]), int(pieces[1]) if len(pieces) == 2 else None)
            )
        if (
            not parsed
            or any(item[0] != number for item in parsed)
            or len(set(parsed)) != 1
        ):
            raise InvalidInput("Streamrip attribution is contradictory")
        if total is not None and parsed[0][1] is not None and parsed[0][1] != total:
            raise InvalidInput("Streamrip attribution is contradictory")

    def _attribution(self, tags: object, item: dict, release: dict) -> dict:
        tracks = release["tracks"]
        discs = max(track["disc"] for track in tracks)
        album_total = len(tracks)
        disc_total = sum(track["disc"] == item["disc"] for track in tracks)
        disc = self._tag_values(tags, ("discnumber", "disc"))
        disc_totals = self._tag_values(tags, ("disctotal", "totaldiscs"))
        track = self._tag_values(tags, ("tracknumber", "track"))
        track_totals = self._tag_values(tags, ("tracktotal", "totaltracks"))
        self._number(disc, item["disc"], discs, "disc")
        self._number(track, item["track"], album_total, "track")
        if not any("/" in value for value in disc) and not disc_totals:
            raise InvalidInput("Streamrip attribution is invalid")
        if not any("/" in value for value in track) and not track_totals:
            raise InvalidInput("Streamrip attribution is invalid")
        if disc_totals and (
            {int(value.strip()) for value in disc_totals if value.strip().isdigit()}
            != {discs}
            or len(disc_totals)
            != len([value for value in disc_totals if value.strip().isdigit()])
        ):
            raise InvalidInput("Streamrip attribution is contradictory")
        if track_totals and (
            {int(value.strip()) for value in track_totals if value.strip().isdigit()}
            != {album_total}
            or len(track_totals)
            != len([value for value in track_totals if value.strip().isdigit()])
        ):
            raise InvalidInput("Streamrip attribution is contradictory")
        expected = {
            "title": item["title"].strip(),
            "album": release["title"].strip(),
            "albumartist": release["artist"].strip(),
        }
        for name, aliases in (
            ("title", ("title",)),
            ("album", ("album",)),
            ("albumartist", ("albumartist", "album artist")),
        ):
            values = self._tag_values(tags, aliases)
            if not values or set(values) != {expected[name]}:
                raise InvalidInput(
                    "Streamrip attribution does not match frozen release"
                )
        details = (
            release.get("details") if isinstance(release.get("details"), dict) else {}
        )
        date = details.get("date")
        if isinstance(date, str) and date:
            dates = self._tag_values(tags, ("date",))
            years = self._tag_values(tags, ("year",))
            if (
                not dates
                or not years
                or len(set(dates)) != 1
                or not self._date_matches_target(dates[0], date)
                or set(years) != {date[:4]}
                or any(value[:4] != date[:4] for value in dates)
            ):
                raise InvalidInput(
                    "Streamrip edition date does not match frozen release"
                )
            # Retain the produced precision.  Capture must present this same claim,
            # while comparison to the frozen target remains precision-aware.
            expected["date"] = dates[0]
        if self._tag_values(tags, ("description", "comment")):
            raise InvalidInput("Streamrip edition description is unverifiable")
        expected.update(
            {
                "disc": str(item["disc"]),
                "disc_total": str(discs),
                "track": str(item["track"]),
                "track_total": str(album_total),
                "disc_local_total": str(disc_total),
            }
        )
        return expected

    @staticmethod
    def _date_matches_target(observed: str, target: str) -> bool:
        parts = observed.split("-")
        target_parts = target.split("-")
        if (
            len(parts) not in {1, 2, 3}
            or len(target_parts) not in {1, 2, 3}
            or any(not part.isascii() or not part.isdigit() for part in parts)
            or any(not part.isascii() or not part.isdigit() for part in target_parts)
            or len(parts[0]) != 4
            or len(target_parts[0]) != 4
            or any(len(part) != 2 for part in parts[1:])
            or any(len(part) != 2 for part in target_parts[1:])
            or parts[0] != target_parts[0]
        ):
            return False
        try:
            if len(parts) > 1:
                calendar_date(
                    int(parts[0]),
                    int(parts[1]),
                    int(parts[2]) if len(parts) == 3 else 1,
                )
            if len(target_parts) > 1:
                calendar_date(
                    int(target_parts[0]),
                    int(target_parts[1]),
                    int(target_parts[2]) if len(target_parts) == 3 else 1,
                )
        except ValueError:
            return False
        return (
            len(target_parts) == 1
            or len(target_parts) == 2
            and parts[:2] == target_parts
            or parts == target_parts
        )

    @staticmethod
    def _scan_output(root: Path) -> list[tuple[Path, os.stat_result]]:
        if root.is_symlink() or not root.is_dir():
            raise InvalidInput("Streamrip output is unsafe")
        found, pending, total, traversed = [], [(root, 0)], 0, 0
        while pending:
            parent, depth = pending.pop()
            with os.scandir(parent) as entries:
                for entry in entries:
                    traversed += 1
                    if traversed > MAX_OUTPUT_ENTRIES:
                        raise InvalidInput("Streamrip output has too many entries")
                    info = entry.stat(follow_symlinks=False)
                    path = parent / entry.name
                    if stat.S_ISLNK(info.st_mode):
                        raise InvalidInput("Streamrip output contains a symlink")
                    if stat.S_ISDIR(info.st_mode):
                        if depth >= MAX_OUTPUT_DEPTH:
                            raise InvalidInput("Streamrip output is too deeply nested")
                        pending.append((path, depth + 1))
                    elif (
                        stat.S_ISREG(info.st_mode)
                        and path.suffix[1:].casefold() in AUDIO_EXTENSIONS
                    ):
                        if info.st_size < 1:
                            raise InvalidInput(
                                "Streamrip output contains a partial artifact"
                            )
                        total += info.st_size
                        if len(found) >= MAX_OUTPUT_FILES or total > MAX_OUTPUT_BYTES:
                            raise InvalidInput("Streamrip output exceeds limits")
                        found.append((path, info))
                    else:
                        raise InvalidInput(
                            "Streamrip output contains an unexpected artifact"
                        )
        return found

    @staticmethod
    def _db_rows(path: Path, table: str, fields: tuple[str, ...]) -> list[tuple]:
        connection = None
        try:
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                raise OSError
            connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            columns = connection.execute(f"PRAGMA table_info({table})").fetchall()
            names = {row[1]: row for row in columns}
            if set(fields) - set(names) or any(
                names[field][3] != 1 for field in fields
            ):
                raise sqlite3.DatabaseError
            indexes = connection.execute(f"PRAGMA index_list({table})").fetchall()
            if not any(
                row[2]
                and {
                    item[2]
                    for item in connection.execute(f'PRAGMA index_info("{row[1]}")')
                }
                == {"id"}
                for row in indexes
            ):
                raise sqlite3.DatabaseError
            cursor = connection.execute(
                f"SELECT {','.join(fields)} FROM {table} LIMIT {MAX_DB_ROWS + 1}"
            )
            rows = cursor.fetchmany(MAX_DB_ROWS + 1)
            if len(rows) > MAX_DB_ROWS:
                raise sqlite3.DatabaseError
            return rows
        except (OSError, sqlite3.Error) as exc:
            raise InvalidInput("Streamrip database evidence is invalid") from exc
        finally:
            if connection is not None:
                connection.close()

    def _db_evidence(
        self, runtime: dict[str, str], provider_id: str, count: int
    ) -> dict:
        downloads = self._db_rows(Path(runtime["downloads_db"]), "downloads", ("id",))
        failed = self._db_rows(
            Path(runtime["failed_downloads_db"]),
            "failed_downloads",
            ("source", "media_type", "id"),
        )
        if len(downloads) != count or len({row[0] for row in downloads}) != count:
            raise InvalidInput("Streamrip database contradicts downloaded output")
        if failed and any(row != ("qobuz", "album", provider_id) for row in failed):
            raise InvalidInput("Streamrip database contradicts requested operation")
        if failed:
            raise InvalidInput("Streamrip database reports failed downloads")
        return {"download_rows": len(downloads), "failed_rows": len(failed)}

    def completed_input(
        self, runtime: dict[str, str], release: dict, validator, provider_id: str
    ) -> dict:
        root = Path(runtime["output"])
        paths = self._scan_output(root)
        tracks = release.get("tracks")
        if not isinstance(tracks, list) or not tracks or len(paths) != len(tracks):
            raise InvalidInput("Streamrip output is incomplete")
        expected = {(track["disc"], track["track"]): track for track in tracks}
        if len(expected) != len(tracks):
            raise InvalidInput("resolved manifest is ambiguous")
        files, used = [], set()
        for path, info in paths:
            measured = validator.inspect(path)
            tags = measured.get("tags")
            disc = self._tag_values(tags, ("discnumber", "disc"))
            track = self._tag_values(tags, ("tracknumber", "track"))
            if not disc or not track:
                raise InvalidInput("Streamrip attribution is invalid")
            try:
                key = (
                    int(disc[0].split("/", 1)[0].strip()),
                    int(track[0].split("/", 1)[0].strip()),
                )
            except ValueError as exc:
                raise InvalidInput("Streamrip attribution is invalid") from exc
            item = expected.get(key)
            if item is None or key in used:
                raise InvalidInput("Streamrip output track mapping is ambiguous")
            attribution = self._attribution(tags, item, release)
            used.add(key)
            relative = path.relative_to(root)
            files.append(
                {
                    "remote": str(relative),
                    "expected_relative": str(relative),
                    "size": info.st_size,
                    "disc": key[0],
                    "track": key[1],
                    "recording_mbid": item["recording_mbid"],
                    "duration_ms": item["duration_ms"],
                    "requested_at": None,
                    "expected_tags": {
                        key: value
                        for key, value in attribution.items()
                        if key in {"title", "album", "albumartist"}
                    },
                    "attribution": attribution,
                }
            )
        if used != set(expected):
            raise InvalidInput("Streamrip output is missing tracks")
        return {
            "files": files,
            "db": self._db_evidence(runtime, provider_id, len(files)),
            "source_entries": [
                list(item)
                for item in sorted(
                    (str(path.relative_to(root)), info.st_size, info.st_mtime_ns)
                    for path, info in paths
                )
            ],
            "release": {
                "tracks": tracks,
                "title": release["title"],
                "artist": release["artist"],
                "details": release.get("details", {}),
            },
        }

    def revalidate_completed_input(
        self, runtime: dict[str, str], completed: dict, validator
    ) -> None:
        paths = self._scan_output(Path(runtime["output"]))
        current = [
            list(item)
            for item in sorted(
                (
                    str(path.relative_to(runtime["output"])),
                    info.st_size,
                    info.st_mtime_ns,
                )
                for path, info in paths
            )
        ]
        if current != completed.get("source_entries"):
            raise InvalidInput("Streamrip output changed before capture")
        by_relative = {item["expected_relative"]: item for item in completed["files"]}
        tracks = {
            (item["disc"], item["track"]): item
            for item in completed["release"]["tracks"]
        }
        for path, _ in paths:
            item = by_relative.get(str(path.relative_to(runtime["output"])))
            original = tracks.get((item["disc"], item["track"])) if item else None
            if (
                item is None
                or original is None
                or self._attribution(
                    validator.inspect(path).get("tags"), original, completed["release"]
                )
                != item["attribution"]
            ):
                raise InvalidInput("Streamrip captured attribution changed")

    def revalidate_capture(
        self, directory: str | Path, completed: dict, validator
    ) -> None:
        root = Path(directory)
        tracks = {
            (item["disc"], item["track"]): item
            for item in completed["release"]["tracks"]
        }
        expected = set()
        for item in completed["files"]:
            extension = item["remote"].rsplit(".", 1)[-1].casefold()
            name = f"{item['disc']:02d}-{item['track']:02d}.{extension}"
            expected.add(name)
            original = tracks[(item["disc"], item["track"])]
            if (
                self._attribution(
                    validator.inspect(root / name).get("tags"),
                    original,
                    completed["release"],
                )
                != item["attribution"]
            ):
                raise InvalidInput("Streamrip captured attribution changed")
        if {entry.name for entry in root.iterdir()} != expected:
            raise InvalidInput("Streamrip capture contains unexpected artifacts")
