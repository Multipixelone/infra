import io
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

import openclaw_music.streamrip as streamrip_module
from openclaw_music import cli as cli_module
from openclaw_music.config import TrustedConfig
from openclaw_music.errors import (
    BackendUncertain,
    Configuration,
    Conflict,
    InvalidInput,
)
from openclaw_music.input import parse
from openclaw_music.jobs import JobService
from openclaw_music.ledger import Ledger
from openclaw_music.streamrip import PIN_TEMPLATE, StreamripAdapter
from openclaw_music.validation import AudioValidator, capture


class Resolver:
    def resolve(self, request, selections, as_of):
        return {
            "state": "resolved",
            "resolved_release": {
                "mbid": "release",
                "artist": "Artist",
                "title": "Album",
                "search_text": "Artist Album",
                "details": {
                    "title": "Album",
                    "date": "2020-01-01",
                    "media": [{"format": "Digital Media"}],
                },
                "tracks": [
                    {
                        "disc": 1,
                        "track": 1,
                        "title": "One",
                        "recording_mbid": "r1",
                        "duration_ms": 200,
                    },
                    {
                        "disc": 1,
                        "track": 2,
                        "title": "Two",
                        "recording_mbid": "r2",
                        "duration_ms": 200,
                    },
                ],
            },
        }


class Validator:
    def inspect(self, path):
        track = 2 if "two" in path.name or "-02." in path.name else 1
        return {
            "codec": "flac",
            "duration": 0.2,
            "tags": {
                "TITLE": "One" if track == 1 else "Two",
                "ALBUM": "Album",
                "ALBUMARTIST": "Artist",
                "DISCNUMBER": "1/1",
                "TRACKNUMBER": f"{track}/2",
                "DATE": "2020-01-01",
                "YEAR": "2020",
            },
        }

    def validate(self, directory, manifest, policy):
        return [self.inspect(Path(directory) / item["name"]) for item in manifest]


class Runner:
    def __init__(self, *, rows=None, code=0, partial=False):
        self.rows = (
            rows
            if rows is not None
            else [
                {
                    "source": "qobuz",
                    "media_type": "album",
                    "id": "provider-private",
                    "desc": "Album by Artist",
                }
            ]
        )
        self.code = code
        self.partial = partial
        self.argv = []
        self.environments = []

    def __call__(self, argv, **kwargs):
        self.argv.append(argv)
        self.environments.append(kwargs["env"])
        if "search" in argv:
            Path(argv[argv.index("--output-file") + 1]).write_text(
                json.dumps(self.rows)
            )
        elif self.code == 0:
            output = Path(argv[argv.index("--folder") + 1])
            output.mkdir(exist_ok=True)
            (output / "one.flac").write_bytes(b"one")
            if not self.partial:
                (output / "two.flac").write_bytes(b"two")
            config = tomllib.loads(
                Path(argv[argv.index("--config-path") + 1]).read_text()
            )
            database = config["database"]
            connection = sqlite3.connect(database["downloads_path"])
            connection.execute("INSERT INTO downloads VALUES ('track-one')")
            if not self.partial:
                connection.execute("INSERT INTO downloads VALUES ('track-two')")
            connection.commit()
            connection.close()
        return subprocess.CompletedProcess(argv, self.code, "", "password=never-public")


class StreamripTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.master = root / "master.toml"
        self.master.write_text("[qobuz]\nuser_id = 'user'\nauth_token = 'secret'\n")
        self.config = TrustedConfig(
            str(root / "ledger"),
            str(root / "stage"),
            str(root / "downloads"),
            "tests/1",
            "http://127.0.0.1:5030",
            str(root / "secret"),
            shutil.which("ffprobe"),
            shutil.which("ffmpeg"),
            transport_isolated=True,
            streamrip_launcher=shutil.which("true"),
            streamrip_master_config=str(self.master),
            streamrip_runtime_root=str(root / "runtime"),
        )
        (root / "downloads").mkdir()
        (root / "secret").write_text("unused")

    def tearDown(self):
        self.temp.cleanup()

    def service(self, runner):
        adapter = StreamripAdapter(
            shutil.which("true"),
            str(self.master),
            self.config.streamrip_runtime_root,
            run=runner,
        )
        return JobService(
            Ledger(self.config.ledger_root),
            Resolver(),
            None,
            Validator(),
            self.config,
            streamrip=adapter,
        )

    def configured_service(self, runner, resolver, validator, *, importer=None):
        adapter = StreamripAdapter(
            shutil.which("true"),
            str(self.master),
            self.config.streamrip_runtime_root,
            run=runner,
        )
        return JobService(
            Ledger(self.config.ledger_root),
            resolver,
            None,
            validator,
            self.config,
            importer=importer,
            streamrip=adapter,
        )

    def request(self, key="key"):
        return parse(
            "submit",
            {
                "schema": 1,
                "idempotency_key": key,
                "artist": "Artist",
                "release": "Album",
                "backend": "streamrip",
            },
        )

    def adapter(self, *, launcher=None, run=subprocess.run):
        return StreamripAdapter(
            launcher or shutil.which("true"),
            str(self.master),
            self.config.streamrip_runtime_root,
            run=run,
        )

    def runtime(self, number=10):
        return self.adapter().runtime(f"00000000-0000-0000-0000-{number:012d}")

    @staticmethod
    def release():
        return Resolver().resolve({}, {}, "")["resolved_release"]

    def assert_private(self, value):
        text = json.dumps(value)
        for secret in (
            "provider-private",
            "password=never-public",
            "secret",
            str(self.config.streamrip_runtime_root),
            str(self.master),
        ):
            self.assertNotIn(secret, text)

    def _audio_tools(self):
        if not self.config.ffmpeg or not self.config.ffprobe:
            self.skipTest("ffmpeg/ffprobe are supplied by the Nix package check")
        return AudioValidator(self.config.ffprobe, self.config.ffmpeg)

    def _flac(self, path, *, track, title, codec="flac"):
        arguments = [
            self.config.ffmpeg,
            "-y",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=8000:cl=mono",
            "-t",
            "0.2",
            "-metadata",
            f"title={title}",
            "-metadata",
            "album=Album",
            "-metadata",
            "album_artist=Artist",
            "-metadata",
            "disc=1/1",
            "-metadata",
            f"track={track}/2",
            "-metadata",
            "date=2020-01-01",
            "-metadata",
            "year=2020",
            "-c:a",
            codec,
            str(path),
        ]
        subprocess.run(arguments, check=True, capture_output=True, text=True)

    def test_backend_is_strict_and_explicit_in_idempotency_digest(self):
        with self.assertRaises(InvalidInput):
            parse(
                "submit",
                {
                    "schema": 1,
                    "idempotency_key": "x",
                    "artist": "a",
                    "release": "b",
                    "backend": "other",
                },
            )
        service = self.service(Runner())
        stream = service.submit(self.request())
        self.assertEqual(stream["backend"], "streamrip")
        with self.assertRaises(Conflict):
            service.submit(
                parse(
                    "submit",
                    {
                        "schema": 1,
                        "idempotency_key": "key",
                        "artist": "Artist",
                        "release": "Album",
                        "backend": "slskd",
                    },
                )
            )
        legacy = service.submit(
            parse(
                "submit",
                {
                    "schema": 1,
                    "idempotency_key": "legacy",
                    "artist": "Artist",
                    "release": "Album",
                },
            )
        )
        self.assertEqual(legacy["backend"], "slskd")

    def test_partial_streamrip_environment_fails_closed_and_status_needs_no_credentials(
        self,
    ):
        root = Path(self.temp.name)
        environment = {
            "OPENCLAW_MUSIC_LEDGER": self.config.ledger_root,
            "OPENCLAW_MUSIC_STAGING": self.config.staging_root,
            "OPENCLAW_MUSIC_DOWNLOAD_ROOT": self.config.download_root,
            "OPENCLAW_MUSIC_MB_USER_AGENT": "tests/1",
            "OPENCLAW_MUSIC_SLSKD_URL": "http://127.0.0.1:5030",
            "OPENCLAW_MUSIC_SLSKD_SECRET": self.config.slskd_secret,
            "OPENCLAW_MUSIC_FFPROBE": self.config.ffprobe,
            "OPENCLAW_MUSIC_FFMPEG": self.config.ffmpeg,
            "OPENCLAW_MUSIC_LIBRARY_ROOT": str(root / "downloads"),
            "OPENCLAW_MUSIC_STREAMRIP_LAUNCHER": shutil.which("true"),
        }
        with self.assertRaises(Configuration):
            TrustedConfig.from_env(environment)
        service = self.service(Runner())
        job = service.submit(self.request("status-without-secrets"))["job_id"]
        stdin = io.TextIOWrapper(
            io.BytesIO(json.dumps({"schema": 1, "job_id": job}).encode()),
            encoding="utf-8",
        )
        stdout = io.StringIO()
        with (
            patch.dict(
                os.environ,
                {"OPENCLAW_MUSIC_LEDGER": self.config.ledger_root},
                clear=True,
            ),
            patch.object(sys, "stdin", stdin),
            patch.object(sys, "stdout", stdout),
        ):
            self.assertEqual(cli_module.main(["status"]), 0)
        self.assertEqual(json.loads(stdout.getvalue())["state"], "queued")

    def test_pinned_template_fixture_matches_generator_before_overrides(self):
        fixture = Path(__file__).parent / "fixtures" / "streamrip-2.4.11.toml"
        self.assertEqual(tomllib.loads(fixture.read_text()), PIN_TEMPLATE)

    def test_new_and_legacy_token_credentials_are_private_and_master_is_unchanged(self):
        legacy = (
            "use_auth_token = true\nemail_or_userid = 'legacy-user'\n"
            "password_or_token = 'legacy-token'\n"
        )
        for number, (login, expected) in enumerate(
            (
                (
                    "user_id = 'new-user'\nauth_token = 'new-token'\n",
                    {"user_id": "new-user", "auth_token": "new-token"},
                ),
                (legacy, {"user_id": "legacy-user", "auth_token": "legacy-token"}),
                (
                    "user_id = 'new-user'\nauth_token = 'new-token'\n" + legacy,
                    {"user_id": "new-user", "auth_token": "new-token"},
                ),
            ),
            start=20,
        ):
            with self.subTest(number=number):
                master = (
                    "# Master must stay byte-for-byte unchanged\r\n[qobuz]\r\n"
                    + login
                    + "app_id = 'master-app'\nsecrets = ['master-secret']\n"
                    + "[downloads]\nfolder = '/shared/downloads'\nverify_ssl = false\n"
                    + "[database]\ndownloads_path = '/shared/downloads.db'\n"
                    + "[tidal]\naccess_token = 'other-source-secret'\n"
                    + "[spotify]\nrefresh_token = 'other-spotify-secret'\n"
                ).encode()
                self.master.write_bytes(master)
                self.master.chmod(0o640)
                before = self.master.stat()
                template = json.dumps(PIN_TEMPLATE, sort_keys=True)
                runtime = self.runtime(number)
                adapter = self.adapter()
                self.assertEqual(adapter._credentials(), expected)
                adapter.write_config(runtime)
                adapter.write_config(runtime)
                raw = Path(runtime["config"]).read_text()
                parsed = tomllib.loads(raw)
                self.assertEqual(parsed["qobuz"], PIN_TEMPLATE["qobuz"] | expected)
                self.assertEqual(parsed["downloads"]["folder"], runtime["output"])
                self.assertEqual(
                    parsed["database"]["downloads_path"], runtime["downloads_db"]
                )
                self.assertEqual(
                    parsed["database"]["failed_downloads_path"],
                    runtime["failed_downloads_db"],
                )
                for section, key in (
                    ("artwork", "embed"),
                    ("artwork", "save_artwork"),
                    ("conversion", "enabled"),
                    ("downloads", "lyrics"),
                ):
                    self.assertFalse(parsed[section][key])
                for forbidden in (
                    "master-app",
                    "master-secret",
                    "other-source-secret",
                    "other-spotify-secret",
                    "/shared",
                    "use_auth_token",
                    "email_or_userid",
                    "password_or_token",
                ):
                    self.assertNotIn(forbidden, raw)
                self.assertEqual(
                    stat.S_IMODE(Path(runtime["config"]).stat().st_mode), 0o600
                )
                self.assertEqual(self.master.read_bytes(), master)
                after = self.master.stat()
                self.assertEqual(
                    (after.st_mode, after.st_mtime_ns, after.st_ino),
                    (before.st_mode, before.st_mtime_ns, before.st_ino),
                )
                self.assertEqual(json.dumps(PIN_TEMPLATE, sort_keys=True), template)

    def test_credentials_reject_malformed_and_password_logins_without_fallback(self):
        legacy = "email_or_userid = 'email@example.test'\npassword_or_token = 'password-secret'\n"
        cases = [
            "",
            "[other]\nvalue = 'secret'",
            "[qobuz]\ninvalid TOML",
            "[qobuz]\n" + legacy,
            "[qobuz]\nuse_auth_token = false\n" + legacy,
            "[qobuz]\nuse_auth_token = 'true'\n" + legacy,
            "[qobuz]\nuse_auth_token = 1\n" + legacy,
            "[qobuz]\nuse_auth_token = true\nemail_or_userid = 'user'\n",
        ]
        for key in ("user_id", "auth_token"):
            for value in (
                '""',
                '"   "',
                '"bad\\u0000secret"',
                '"bad\\nsecret"',
                '"bad\\u007fsecret"',
                "123",
                "true",
                "[]",
            ):
                other = "auth_token" if key == "user_id" else "user_id"
                cases.append(f"[qobuz]\n{key} = {value}\n{other} = 'valid-secret'\n")
            # Presence of either new field disallows even a valid legacy fallback.
            cases.append(
                f"[qobuz]\n{key} = 'valid-secret'\nuse_auth_token = true\n" + legacy
            )
        for number, contents in enumerate(cases):
            with self.subTest(number=number):
                self.master.write_text(contents)
                before = self.master.read_bytes()
                runtime = self.runtime(30)
                with self.assertRaises(Configuration) as caught:
                    self.adapter().write_config(runtime)
                self.assertNotIn("secret", str(caught.exception))
                self.assertNotIn(str(self.master), str(caught.exception))
                self.assertEqual(self.master.read_bytes(), before)
                self.assertFalse(Path(runtime["config"]).exists())

    def test_new_search_json_notes_remain_fail_closed_for_edition_matching(self):
        # v2.4.11 Summary.summarize appends year/explicit notes; as_list keeps
        # the source/media_type/id/desc envelope. Do not discard edition evidence.
        adapter = self.adapter(
            run=Runner(
                rows=[
                    {
                        "source": "qobuz",
                        "media_type": "album",
                        "id": "provider-private",
                        "desc": "Album by Artist (2020, explicit)",
                    }
                ]
            )
        )
        runtime = self.runtime(31)
        adapter.write_config(runtime)
        results = adapter.search(runtime, "Artist Album")
        self.assertEqual(results[0]["description"], "Album by Artist (2020, explicit)")
        self.assertFalse(
            adapter.description_matches(results[0]["description"], self.release())
        )

    def test_year_only_search_description_matches_only_the_frozen_year(self):
        adapter = self.adapter()
        release = self.release()
        for desc, expected in (
            ("Album by Artist", True),
            ("Album by Artist (2020)", True),
            ("Album by Artist (2019)", False),
            ("Album by Artist (2020, explicit)", False),
            ("Album by Artist (explicit)", False),
            ("Album by Artist (unknown)", False),
            ("Album (Remastered) by Artist (2020)", False),
            ("Album by Other (2020)", False),
            ("Album by Artist (2020) extra", False),
            ("Album by Artist (２０２０)", False),
            ("Album by Artist (2020) (2020)", False),
        ):
            with self.subTest(desc=desc):
                self.assertEqual(adapter.description_matches(desc, release), expected)
        for details in ({}, {"date": ""}, {"date": "202"}, None):
            with self.subTest(details=details):
                self.assertFalse(
                    adapter.description_matches(
                        "Album by Artist (2020)", release | {"details": details}
                    )
                )

    def test_year_only_workflow_adopts_pinned_composite_failed_database(self):
        class PinnedRunner(Runner):
            def __call__(self, argv, **kwargs):
                if "search" in argv:
                    parsed = tomllib.loads(
                        Path(argv[argv.index("--config-path") + 1]).read_text()
                    )
                    # Emulate pinned failed-table initialization at the search
                    # boundary, leaving its exact composite-key schema behind.
                    with sqlite3.connect(
                        parsed["database"]["failed_downloads_path"]
                    ) as db:
                        db.execute("DROP TABLE failed_downloads")
                        db.execute(
                            "CREATE TABLE failed_downloads (source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL, UNIQUE (source, media_type, id))"
                        )
                return super().__call__(argv, **kwargs)

        runner = PinnedRunner(
            rows=[
                {
                    "source": "qobuz",
                    "media_type": "album",
                    "id": "provider-private",
                    "desc": "Album by Artist (2020)",
                }
            ]
        )
        service = self.service(runner)
        master = self.master.read_bytes()
        job = self._chosen_streamrip_download(service, "pinned-year-workflow")
        self.assertEqual(service.worker_once()["state"], "downloading")
        self.assertEqual(service.worker_once()["state"], "validating")
        self.assertEqual(service.worker_once()["state"], "validating")
        final = service.worker_once()
        self.assertEqual(final["state"], "ready")
        self.assertEqual(len(runner.argv), 2)
        self.assertEqual(self.master.read_bytes(), master)
        self.assert_private(final)
        self.assertEqual(service.ledger.get(job)["state"], "ready")

    def test_wrong_year_and_edition_search_notes_never_complete_workflow(self):
        for number, desc in enumerate(
            (
                "Album by Artist (2019)",
                "Album by Artist (2020, explicit)",
                "Album by Artist (unknown)",
                "Album (Remastered) by Artist (2020)",
            )
        ):
            with self.subTest(desc=desc):
                runner = Runner(
                    rows=[
                        {
                            "source": "qobuz",
                            "media_type": "album",
                            "id": "provider-private",
                            "desc": desc,
                        }
                    ]
                )
                service = self.service(runner)
                self._chosen_streamrip_download(service, f"rejected-note-{number}")
                self.assertEqual(service.worker_once()["state"], "downloading")
                final = service.worker_once()
                self.assertEqual(final["state"], "needs_review")
                self.assert_private(final)

    def test_failed_database_supports_only_validated_new_and_legacy_schemas(self):
        adapter = self.adapter()
        runtime = self.runtime(32)
        adapter.establish_baseline(runtime)
        failed = Path(runtime["failed_downloads_db"])
        fields = ("source", "media_type", "id")
        adapter.adopt_baseline(runtime)
        with sqlite3.connect(failed) as db:
            indexes = db.execute("PRAGMA index_list(failed_downloads)").fetchall()
            self.assertEqual(
                [row[2] for row in db.execute(f'PRAGMA index_info("{indexes[0][1]}")')],
                list(fields),
            )
        for schema, index, valid in (
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL, UNIQUE(source, media_type, id)",
                None,
                True,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT UNIQUE NOT NULL",
                None,
                True,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL",
                None,
                False,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL, UNIQUE(source, id)",
                None,
                False,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL, UNIQUE(media_type, id)",
                None,
                False,
            ),
            (
                "source TEXT, media_type TEXT NOT NULL, id TEXT NOT NULL, UNIQUE(source, media_type, id)",
                None,
                False,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id INTEGER NOT NULL, UNIQUE(source, media_type, id)",
                None,
                False,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL, extra TEXT, UNIQUE(source, media_type, id)",
                None,
                False,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL",
                "CREATE UNIQUE INDEX partial ON failed_downloads(source, media_type, id) WHERE source = 'qobuz'",
                False,
            ),
            (
                "source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT NOT NULL",
                "CREATE UNIQUE INDEX expression ON failed_downloads(source, media_type, lower(id))",
                False,
            ),
        ):
            with self.subTest(schema=schema, index=index):
                failed.unlink()
                with sqlite3.connect(failed) as db:
                    db.execute(f"CREATE TABLE failed_downloads ({schema})")
                    if index:
                        db.execute(index)
                if valid:
                    adapter.adopt_baseline(runtime)
                    self.assertEqual(
                        adapter._db_rows(failed, "failed_downloads", fields), []
                    )
                    with sqlite3.connect(failed) as db:
                        db.execute(
                            "INSERT INTO failed_downloads VALUES ('qobuz', 'album', 'provider-private')"
                        )
                    with self.assertRaises(InvalidInput):
                        adapter.adopt_baseline(runtime)
                    with self.assertRaises(InvalidInput):
                        adapter._db_evidence(runtime, "provider-private", 0)
                else:
                    with self.assertRaises(InvalidInput):
                        adapter.adopt_baseline(runtime)
        failed.unlink()
        failed.write_bytes(b"corrupt sqlite")
        with self.assertRaises(InvalidInput):
            adapter.adopt_baseline(runtime)
        with self.assertRaises(InvalidInput):
            adapter._db_rows(Path(runtime["downloads_db"]), "unknown", ("id",))

    def test_production_run_bounds_output_and_timeout(self):
        adapter = StreamripAdapter(
            sys.executable, str(self.master), self.config.streamrip_runtime_root
        )
        runtime = adapter.runtime("00000000-0000-0000-0000-000000000002")
        self.assertEqual(
            adapter._run(runtime, [sys.executable, "-c", "print('ok')"])[0], 0
        )
        with self.assertRaises(BackendUncertain):
            adapter._run(
                runtime,
                [sys.executable, "-c", "import sys;sys.stdout.write('x'*70000)"],
            )
        with (
            patch.object(streamrip_module, "PROCESS_TIMEOUT", 0.1),
            self.assertRaises(BackendUncertain),
        ):
            adapter._run(runtime, [sys.executable, "-c", "import time;time.sleep(2)"])

    def test_production_run_reaps_descendants_and_cancellation_is_uncertain(self):
        adapter = self.adapter(launcher=sys.executable)
        runtime = self.runtime(11)
        child_pid = Path(self.temp.name) / "child.pid"
        child = (
            "import os,pathlib,signal,time;"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN);"
            f"p=pathlib.Path({str(child_pid)!r});"
            "tmp=p.with_suffix('.tmp');tmp.write_text(str(os.getpid()));"
            "tmp.replace(p);time.sleep(30)"
        )
        parent = (
            f"import subprocess,sys;subprocess.Popen([sys.executable, '-c', {child!r}])"
        )
        actual_popen = streamrip_module.subprocess.Popen

        def ready_popen(*args, **kwargs):
            process = actual_popen(*args, **kwargs)
            # Fixture startup has its own budget, before the short invocation
            # timeout starts. Atomic publication guarantees the PID write closed.
            startup_deadline = time.monotonic() + 10
            try:
                while time.monotonic() < startup_deadline:
                    try:
                        pid = int(child_pid.read_text())
                    except (OSError, ValueError):
                        time.sleep(0.02)
                        continue
                    self.assertGreater(pid, 0, "invalid fixture readiness PID")
                    try:
                        process.wait(
                            timeout=max(0.01, startup_deadline - time.monotonic())
                        )
                    except subprocess.TimeoutExpired:
                        self.fail(
                            "descendant fixture parent did not exit within startup budget"
                        )
                    return process
                self.fail(
                    "descendant fixture did not publish a readable PID within 10s"
                )
            except BaseException:
                try:
                    self.assertTrue(
                        adapter._kill_group(process),
                        "descendant fixture startup failed and group cleanup failed",
                    )
                finally:
                    if process.stdout:
                        process.stdout.close()
                    if process.stderr:
                        process.stderr.close()
                raise

        with (
            patch.object(streamrip_module.subprocess, "Popen", side_effect=ready_popen),
            patch.object(streamrip_module, "PROCESS_TIMEOUT", 0.15),
            self.assertRaises(BackendUncertain),
        ):
            adapter._run(runtime, [sys.executable, "-c", parent])
        pid = int(child_pid.read_text())
        deadline = time.monotonic() + 2
        while Path(f"/proc/{pid}").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(
            Path(f"/proc/{pid}").exists(), "launcher descendant survived cleanup"
        )

        selector = streamrip_module.selectors.DefaultSelector

        class CancelledSelector:
            def __init__(self):
                self.inner = selector()

            def register(self, *args):
                return self.inner.register(*args)

            def get_map(self):
                return self.inner.get_map()

            def select(self, timeout=None):
                raise KeyboardInterrupt

            def close(self):
                self.inner.close()

        with (
            patch.object(
                streamrip_module.selectors, "DefaultSelector", CancelledSelector
            ),
            patch.object(adapter, "_kill_group", wraps=adapter._kill_group) as cleanup,
            self.assertRaises(BackendUncertain),
        ):
            adapter._run(runtime, [sys.executable, "-c", "import time; time.sleep(30)"])
        cleanup.assert_called_once()

    def test_production_run_selector_setup_failure_reaps_post_spawn_process(self):
        adapter = self.adapter(launcher=sys.executable)
        runtime = self.runtime(15)
        actual_popen = streamrip_module.subprocess.Popen
        processes = []

        def record_popen(*args, **kwargs):
            process = actual_popen(*args, **kwargs)
            processes.append(process)
            return process

        class BrokenSelector:
            def register(self, *args):
                raise RuntimeError("selector registration failed")

            def close(self):
                pass

        with (
            patch.object(
                streamrip_module.subprocess, "Popen", side_effect=record_popen
            ),
            patch.object(streamrip_module.selectors, "DefaultSelector", BrokenSelector),
            patch.object(adapter, "_kill_group", wraps=adapter._kill_group) as cleanup,
            self.assertRaises(BackendUncertain),
        ):
            adapter._run(runtime, [sys.executable, "-c", "import time; time.sleep(30)"])
        cleanup.assert_called_once_with(processes[0])
        self.assertIsNotNone(processes[0].poll())
        self.assertFalse(Path(f"/proc/{processes[0].pid}").exists())

    def test_actual_popen_nonzero_acknowledges_then_stops_before_import(self):
        launcher = Path(self.temp.name) / "launcher.py"
        launcher.write_text(
            f"#!{sys.executable}\n"
            "import json, pathlib, sys\n"
            "a=sys.argv\n"
            "if 'search' in a:\n"
            " pathlib.Path(a[a.index('--output-file')+1]).write_text(json.dumps([{'source':'qobuz','media_type':'album','id':'provider-private','desc':'Album by Artist'}]))\n"
            " sys.exit(0)\n"
            "pathlib.Path(a[a.index('--folder')+1]).mkdir(exist_ok=True)\n"
            "sys.exit(7)\n"
        )
        launcher.chmod(0o700)

        class Importer:
            behavior_identity = "test-importer"

            def __init__(self):
                self.calls = 0

            def reconcile_import(self, identity):
                self.calls += 1
                raise AssertionError("beets/import must not run")

        importer = Importer()
        adapter = self.adapter(launcher=str(launcher))
        service = JobService(
            Ledger(self.config.ledger_root),
            Resolver(),
            None,
            Validator(),
            self.config,
            importer=importer,
            streamrip=adapter,
        )
        job = service.submit(self.request("actual-nonzero"))["job_id"]
        service.worker_once()
        service.worker_once()
        service.worker_once()
        search = service.worker_once()["candidate_set"]
        service.choose(
            job, search["id"], search["candidates"][0]["id"], search["revision"]
        )
        self.assertEqual(service.worker_once()["state"], "downloading")
        public = service.worker_once()
        self.assertEqual(public["state"], "needs_review")
        self.assertEqual(importer.calls, 0)
        self.assert_private(public)

    def test_actual_flac_completed_input_capture_and_mutation_revalidation(self):
        validator = self._audio_tools()
        adapter = self.adapter()
        runtime = self.runtime(12)
        adapter.establish_baseline(runtime)
        output = Path(runtime["output"])
        self._flac(output / "one.flac", track=1, title="One")
        self._flac(output / "two.flac", track=2, title="Two")
        connection = sqlite3.connect(runtime["downloads_db"])
        connection.executemany("INSERT INTO downloads VALUES (?)", [("one",), ("two",)])
        connection.commit()
        connection.close()
        completed = adapter.completed_input(
            runtime, self.release(), validator, "provider-private"
        )
        stage, manifest, measurements = capture(
            runtime["output"],
            self.config.staging_root,
            "00000000-0000-0000-0000-000000000012",
            completed["files"],
            max_bytes=self.config.max_bytes,
            validator=validator,
            policy={
                "profile": "lossless",
                "max_files": 10,
                "max_bytes": self.config.max_bytes,
            },
        )
        self.assertEqual(len(manifest), 2)
        self.assertEqual([item["codec"] for item in measurements], ["flac", "flac"])
        adapter.revalidate_capture(stage, completed, validator)
        self._flac(output / "one.flac", track=1, title="Changed")
        with self.assertRaises(InvalidInput):
            adapter.revalidate_completed_input(runtime, completed, validator)
        self._flac(stage / "01-01.flac", track=1, title="Changed")
        with self.assertRaises(InvalidInput):
            adapter.revalidate_capture(stage, completed, validator)

    def test_description_comment_is_unverifiable_in_workflow_and_capture(self):
        class CommentValidator(Validator):
            def __init__(self, *, captured_only=False):
                self.captured_only = captured_only

            def inspect(self, path):
                measured = super().inspect(path)
                if not self.captured_only or path.name.startswith("01-"):
                    measured["tags"][
                        "comment" if self.captured_only else "DESCRIPTION"
                    ] = "2024 remaster; not the original version"
                return measured

        class Importer:
            behavior_identity = "must-not-run"

            def __init__(self):
                self.calls = 0

            def reconcile_import(self, identity):
                self.calls += 1
                raise AssertionError("unverifiable edition reached importer")

        importer = Importer()
        service = self.configured_service(
            Runner(), Resolver(), CommentValidator(), importer=importer
        )
        self._chosen_streamrip_download(service, "description-comment")
        self.assertEqual(service.worker_once()["state"], "downloading")
        public = service.worker_once()
        self.assertEqual(public["state"], "needs_review")
        self.assertEqual(importer.calls, 0)
        self.assert_private(public)

        adapter = self.adapter()
        runtime = self.runtime(16)
        adapter.establish_baseline(runtime)
        output = Path(runtime["output"])
        for name in ("one.flac", "two.flac"):
            (output / name).write_bytes(b"x")
        connection = sqlite3.connect(runtime["downloads_db"])
        connection.executemany("INSERT INTO downloads VALUES (?)", [("one",), ("two",)])
        connection.commit()
        connection.close()
        completed = adapter.completed_input(
            runtime, self.release(), Validator(), "provider-private"
        )
        stage, _, _ = capture(
            output,
            self.config.staging_root,
            "00000000-0000-0000-0000-000000000016",
            completed["files"],
            max_bytes=self.config.max_bytes,
            validator=Validator(),
            policy={
                "profile": "lossless",
                "max_files": 10,
                "max_bytes": self.config.max_bytes,
            },
        )
        with self.assertRaises(InvalidInput):
            adapter.revalidate_capture(
                stage, completed, CommentValidator(captured_only=True)
            )

    def test_partial_dates_survive_capture_revalidation_and_reject_contradictions(self):
        class DatedResolver(Resolver):
            def __init__(self, target):
                self.target = target

            def resolve(self, request, selections, as_of):
                resolved = super().resolve(request, selections, as_of)
                resolved["resolved_release"]["details"]["date"] = self.target
                return resolved

        class DatedValidator(Validator):
            def __init__(self, source_date, captured_date=None, captured_year=None):
                self.source_date = source_date
                self.captured_date = captured_date or source_date
                self.captured_year = captured_year

            def inspect(self, path):
                measured = super().inspect(path)
                captured = path.name.startswith("01-")
                observed = self.captured_date if captured else self.source_date
                measured["tags"]["DATE"] = observed
                measured["tags"]["YEAR"] = (
                    self.captured_year
                    if captured and self.captured_year
                    else observed[:4]
                )
                return measured

        for target, observed in (
            ("2020-01-01", "2020-01-01"),
            ("2020", "2020-09-01"),
            ("2020-03", "2020-03-15"),
        ):
            with self.subTest(target=target, observed=observed):
                service = self.configured_service(
                    Runner(), DatedResolver(target), DatedValidator(observed)
                )
                job = self._chosen_streamrip_download(service, f"date-{target}")
                for _ in range(4):
                    result = service.worker_once()
                    if result["state"] == "ready":
                        break
                self.assertEqual(result["state"], "ready")
                attribution = service.ledger.get(job)["transfer_intent"]["completed"][
                    "files"
                ][0]["attribution"]
                self.assertEqual(attribution["date"], observed)
                # Keep this fixture's ready job from competing with the next case.
                self.assertTrue(service.worker_once()["integration_required"])

        service = self.configured_service(
            Runner(),
            DatedResolver("2020-03"),
            DatedValidator("2020-03", captured_date="2020-04", captured_year="2019"),
        )
        self._chosen_streamrip_download(service, "date-contradictory")
        self.assertEqual(service.worker_once()["state"], "downloading")
        self.assertEqual(service.worker_once()["state"], "validating")
        self.assertEqual(service.worker_once()["state"], "validating")
        public = service.worker_once()
        self.assertEqual(public["state"], "needs_review")
        self.assert_private(public)

    def test_actual_audio_rejects_corrupt_zero_and_lossy_quality(self):
        validator = self._audio_tools()
        root = Path(self.temp.name)
        corrupt = root / "corrupt.flac"
        corrupt.write_bytes(b"not audio")
        empty = root / "empty.flac"
        empty.touch()
        for path in (corrupt, empty):
            with self.subTest(path=path.name), self.assertRaises(InvalidInput):
                validator.inspect(path)
        mp3 = root / "lossy.mp3"
        self._flac(mp3, track=1, title="One", codec="libmp3lame")
        with self.assertRaises(InvalidInput):
            validator.validate(
                root,
                [{"name": mp3.name, "size": mp3.stat().st_size}],
                {"profile": "lossless", "max_files": 2, "max_bytes": 1_000_000},
            )

    def test_database_baselines_and_evidence_are_strict_and_bounded(self):
        adapter = self.adapter()
        runtime = self.runtime(13)
        downloads = Path(runtime["downloads_db"])
        failed = Path(runtime["failed_downloads_db"])
        with self.assertRaises(InvalidInput):
            adapter._db_rows(downloads, "downloads", ("id",))
        downloads.write_text("not sqlite")
        with self.assertRaises(InvalidInput):
            adapter._db_rows(downloads, "downloads", ("id",))
        downloads.unlink()
        sqlite3.connect(downloads).close()  # A database with no Streamrip table.
        with self.assertRaises(InvalidInput):
            adapter._db_rows(downloads, "downloads", ("id",))
        downloads.unlink()
        connection = sqlite3.connect(downloads)
        connection.execute("CREATE TABLE downloads (id TEXT)")
        connection.commit()
        connection.close()
        with self.assertRaises(InvalidInput):
            adapter._db_rows(downloads, "downloads", ("id",))
        downloads.unlink()
        # Search is allowed to create empty, schema-correct private databases.
        connection = sqlite3.connect(downloads)
        connection.execute("CREATE TABLE downloads (id TEXT UNIQUE NOT NULL)")
        connection.commit()
        connection.close()
        connection = sqlite3.connect(failed)
        connection.execute(
            "CREATE TABLE failed_downloads (source TEXT NOT NULL, media_type TEXT NOT NULL, id TEXT UNIQUE NOT NULL)"
        )
        connection.commit()
        connection.close()
        adapter.adopt_baseline(runtime)
        connection = sqlite3.connect(downloads)
        connection.execute("INSERT INTO downloads VALUES ('pre-search')")
        connection.commit()
        connection.close()
        with self.assertRaises(InvalidInput):
            adapter.adopt_baseline(runtime)
        connection = sqlite3.connect(downloads)
        connection.execute("DELETE FROM downloads")
        connection.executemany(
            "INSERT INTO downloads VALUES (?)", [(str(n),) for n in range(101)]
        )
        connection.commit()
        connection.close()
        with self.assertRaises(InvalidInput):
            adapter._db_rows(downloads, "downloads", ("id",))
        connection = sqlite3.connect(downloads)
        connection.execute("DELETE FROM downloads")
        connection.execute("INSERT INTO downloads VALUES ('one')")
        connection.commit()
        connection.close()
        connection = sqlite3.connect(failed)
        connection.execute(
            "INSERT INTO failed_downloads VALUES ('qobuz', 'album', 'provider-private')"
        )
        connection.commit()
        connection.close()
        with self.assertRaises(InvalidInput):
            adapter._db_evidence(runtime, "provider-private", 1)
        connection = sqlite3.connect(failed)
        connection.execute("DELETE FROM failed_downloads")
        connection.commit()
        connection.close()
        with self.assertRaises(InvalidInput):
            adapter._db_evidence(runtime, "provider-private", 2)
        self.assertEqual(
            adapter._db_evidence(runtime, "provider-private", 1)["download_rows"], 1
        )

    def test_output_inventory_rejects_unsafe_artifacts_and_duplicate_mapping(self):
        adapter = self.adapter()
        runtime = self.runtime(14)
        root = Path(runtime["output"])
        regular = root / "one.flac"
        regular.write_bytes(b"x")
        for name, build in (
            ("file-symlink", lambda: (root / "link.flac").symlink_to(regular)),
            (
                "directory-symlink",
                lambda: (root / "dir").symlink_to(root, target_is_directory=True),
            ),
        ):
            with self.subTest(name=name):
                build()
                with self.assertRaises(InvalidInput):
                    adapter._scan_output(root)
                for entry in root.iterdir():
                    if entry.is_symlink():
                        entry.unlink()
        (root / "cover.jpg").write_bytes(b"x")
        with self.assertRaises(InvalidInput):
            adapter._scan_output(root)
        (root / "cover.jpg").unlink()
        nested = root
        for index in range(9):
            nested = nested / str(index)
            nested.mkdir()
        with self.assertRaises(InvalidInput):
            adapter._scan_output(root)
        shutil.rmtree(root)
        root.mkdir()
        for index in range(101):
            (root / f"{index}.flac").write_bytes(b"x")
        with self.assertRaises(InvalidInput):
            adapter._scan_output(root)
        shutil.rmtree(root)
        root.mkdir()
        (root / "zero.flac").touch()
        with self.assertRaises(InvalidInput):
            adapter._scan_output(root)
        (root / "zero.flac").unlink()
        (root / "large.flac").write_bytes(b"xx")
        with (
            patch.object(streamrip_module, "MAX_OUTPUT_BYTES", 1),
            self.assertRaises(InvalidInput),
        ):
            adapter._scan_output(root)
        (root / "large.flac").unlink()
        (root / "one.flac").write_bytes(b"x")
        (root / "two.flac").write_bytes(b"x")

        class SameTrack(Validator):
            def inspect(self, path):
                return super().inspect(Path("one.flac"))

        adapter.establish_baseline(runtime)
        connection = sqlite3.connect(runtime["downloads_db"])
        connection.executemany("INSERT INTO downloads VALUES (?)", [("1",), ("2",)])
        connection.commit()
        connection.close()
        with self.assertRaises(InvalidInput):
            adapter.completed_input(
                runtime, self.release(), SameTrack(), "provider-private"
            )

    def test_output_inventory_bounds_shallow_directory_breadth(self):
        adapter = self.adapter()
        root = Path(self.runtime(17)["output"])
        for index in range(5):
            (root / f"empty-{index}").mkdir()
        with (
            patch.object(streamrip_module, "MAX_OUTPUT_ENTRIES", 4),
            self.assertRaises(InvalidInput),
        ):
            adapter._scan_output(root)

    def test_singleton_choice_private_config_and_fixed_argv(self):
        runner = Runner()
        service = self.service(runner)
        job = service.submit(self.request())["job_id"]
        service.worker_once()  # queued -> resolving
        service.worker_once()  # resolving -> searching
        service.worker_once()  # durable search plan
        result = service.worker_once()  # search -> choice, even singleton
        candidate = result["candidate_set"]
        self.assertEqual(result["state"], "needs_choice")
        self.assertEqual(len(candidate["candidates"]), 1)
        self.assertNotIn("provider-private", json.dumps(result))
        stored = service.ledger.get(job)
        runtime = stored["streamrip"]["runtime"]
        config = Path(runtime["config"])
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(Path(runtime["root"]).stat().st_mode), 0o700)
        parsed = tomllib.loads(config.read_text())
        expected = {
            "downloads": {
                "folder",
                "source_subdirectories",
                "disc_subdirectories",
                "lyrics",
                "max_connections",
                "requests_per_minute",
                "verify_ssl",
            },
            "qobuz": {
                "quality",
                "download_booklets",
                "user_id",
                "auth_token",
                "app_id",
                "secrets",
            },
            "tidal": {
                "quality",
                "hires_client",
                "client_id",
                "client_secret",
                "token_client_id",
                "hires_access_token",
                "hires_refresh_token",
                "hires_token_expiry",
                "hires_token_client_id",
                "user_id",
                "country_code",
                "access_token",
                "refresh_token",
                "token_expiry",
            },
            "deezer": {
                "quality",
                "lower_quality_if_not_available",
                "arl",
            },
            "soundcloud": {"client_id", "app_version"},
            "spotify": {
                "client_id",
                "redirect_uri",
                "audio_format",
                "audio_bitrate",
                "match_videos",
                "access_token",
                "refresh_token",
                "token_expiry",
            },
            "database": {
                "downloads_enabled",
                "downloads_path",
                "failed_downloads_enabled",
                "failed_downloads_path",
            },
            "conversion": {
                "enabled",
                "codec",
                "sampling_rate",
                "bit_depth",
                "lossy_bitrate",
            },
            "artist_filters": {
                "extras",
                "repeats",
                "non_albums",
                "features",
                "non_remaster",
            },
            "artwork": {
                "embed",
                "embed_size",
                "embed_max_width",
                "save_artwork",
                "saved_max_width",
            },
            "metadata": {
                "set_playlist_to_album",
                "renumber_playlist_tracks",
                "exclude",
                "prefer_explicit",
            },
            "filepaths": {
                "add_singles_to_folder",
                "folder_format",
                "track_format",
                "restrict_characters",
                "truncate_to",
            },
            "lastfm": {"source", "fallback_source"},
            "cli": {"progress_bars", "max_search_results", "no_update_check"},
        }
        self.assertEqual({name: set(value) for name, value in parsed.items()}, expected)
        self.assertEqual(parsed["downloads"]["max_connections"], 2)
        self.assertEqual(parsed["downloads"]["requests_per_minute"], 30)
        self.assertTrue(parsed["downloads"]["verify_ssl"])
        self.assertFalse(parsed["downloads"]["lyrics"])
        self.assertEqual(parsed["database"]["downloads_enabled"], True)
        self.assertTrue(parsed["cli"]["no_update_check"])
        self.assertEqual(self.master.read_text().count("secret"), 1)
        self.assertEqual(
            runner.argv[0],
            [
                shutil.which("true"),
                "--config-path",
                runtime["config"],
                "search",
                "--output-file",
                runtime["search_results"],
                "--num-results",
                "20",
                "qobuz",
                "album",
                "Artist Album",
            ],
        )
        self.assertEqual(runner.environments[0]["HOME"], runtime["home"])
        self.assertEqual(runner.environments[0]["XDG_CACHE_HOME"], runtime["xdg_cache"])
        for key in ("home", "xdg_config", "xdg_cache", "tmp"):
            self.assertEqual(stat.S_IMODE(Path(runtime[key]).stat().st_mode), 0o700)
        service.choose(
            job,
            candidate["id"],
            candidate["candidates"][0]["id"],
            candidate["revision"],
        )
        service.worker_once()
        self.assertEqual(
            runner.argv[1][-4:], ["id", "qobuz", "album", "provider-private"]
        )
        self.assertNotIn("secret", json.dumps(service.status(job)))
        self.assertEqual(service.worker_once()["state"], "validating")
        self.assertEqual(service.worker_once()["state"], "validating")
        final = service.worker_once()
        self.assertEqual(final["state"], "ready", final)

    def test_malformed_search_partial_output_and_unacknowledged_download_review(self):
        adapter = StreamripAdapter(
            shutil.which("true"),
            str(self.master),
            self.config.streamrip_runtime_root,
            run=Runner(rows=[{"source": "tidal"}]),
        )
        runtime = adapter.runtime("00000000-0000-0000-0000-000000000000")
        adapter.write_config(runtime)
        with self.assertRaises(InvalidInput):
            adapter.search(runtime, "Artist Album")
        runner = Runner(partial=True)
        service = self.service(runner)

        class Importer:
            behavior_identity = "must-not-run"

            def __init__(self):
                self.calls = 0

            def reconcile_import(self, identity):
                self.calls += 1
                raise AssertionError("partial Streamrip output reached beets")

        importer = Importer()
        service.importer = importer
        job = service.submit(self.request("partial"))["job_id"]
        for _ in range(4):
            result = service.worker_once()
        candidate = result["candidate_set"]
        service.choose(
            job,
            candidate["id"],
            candidate["candidates"][0]["id"],
            candidate["revision"],
        )
        self.assertEqual(service.worker_once()["state"], "downloading")
        public = service.worker_once()
        self.assertEqual(public["state"], "needs_review")
        self.assertNotIn("provider-private", json.dumps(public))
        self.assertNotIn("password=never-public", json.dumps(public))
        self.assertNotIn(str(self.config.streamrip_runtime_root), json.dumps(public))
        self.assertEqual(importer.calls, 0)
        stored = service.ledger.get(job)
        stored["state"] = "downloading"
        stored["streamrip"]["download"]["status"] = "calling"
        stored["revision"] += 1
        service.ledger.save(stored)
        self.assertEqual(service.worker_once()["state"], "needs_review")
        self.assertEqual(len(runner.argv), 2)

    def _chosen_streamrip_download(self, service, key):
        job = service.submit(self.request(key))["job_id"]
        for _ in range(4):
            result = service.worker_once()
        candidate = result["candidate_set"]
        service.choose(
            job,
            candidate["id"],
            candidate["candidates"][0]["id"],
            candidate["revision"],
        )
        return job

    def test_restart_plan_before_spawn_runs_once_and_calling_never_replays(self):
        runner = Runner()
        service = self.service(runner)
        job = self._chosen_streamrip_download(service, "restart-intent")
        self.assertEqual(
            service.ledger.get(job)["streamrip"]["download"]["status"], "intent"
        )
        resumed = self.service(runner)
        self.assertEqual(resumed.worker_once()["state"], "downloading")
        self.assertEqual(sum("id" in call for call in runner.argv), 1)

        stored = resumed.ledger.get(job)
        stored["streamrip"]["download"]["status"] = "calling"
        stored["revision"] += 1
        resumed.ledger.save(stored)
        result = self.service(runner).worker_once()
        self.assertEqual(result["state"], "needs_review")
        self.assertEqual(sum("id" in call for call in runner.argv), 1)
        self.assert_private(result)

    def test_restart_acknowledged_and_validating_resume_without_streamrip_spawn(self):
        runner = Runner()
        service = self.service(runner)
        job = self._chosen_streamrip_download(service, "restart-ack")
        self.assertEqual(service.worker_once()["state"], "downloading")
        calls = len(runner.argv)
        resumed = self.service(runner)
        self.assertEqual(resumed.worker_once()["state"], "validating")
        self.assertEqual(len(runner.argv), calls)
        self.assertEqual(resumed.worker_once()["state"], "validating")
        resumed = self.service(runner)
        self.assertEqual(resumed.worker_once()["state"], "ready")
        self.assertEqual(len(runner.argv), calls)
        ready = resumed.ledger.get(job)
        self.assertTrue(Path(ready["stage_path"]).is_dir())

    def test_restart_ready_capture_publication_uses_downstream_without_streamrip(self):
        runner = Runner()
        service = self.service(runner)
        job = self._chosen_streamrip_download(service, "restart-ready")
        for _ in range(4):
            result = service.worker_once()
            if result["state"] == "ready":
                break
        self.assertEqual(result["state"], "ready")
        calls = len(runner.argv)

        class Importer:
            behavior_identity = "restart-test"

            def reconcile_import(self, identity):
                return "not_started", None

        resumed = JobService(
            service.ledger,
            service.resolver,
            None,
            service.validator,
            self.config,
            importer=Importer(),
            streamrip=service.streamrip,
        )
        self.assertEqual(resumed.worker_once()["state"], "importing")
        self.assertEqual(len(runner.argv), calls)
        self.assertEqual(resumed.ledger.get(job)["state"], "importing")

    def test_credentials_launcher_candidates_and_attribution_are_strict(self):
        with self.assertRaises(Configuration):
            StreamripAdapter(
                "/tmp/rip", str(self.master), self.config.streamrip_runtime_root
            )
        with self.assertRaises(Configuration):
            TrustedConfig(
                self.config.ledger_root,
                self.config.staging_root,
                self.config.download_root,
                "tests/1",
                "http://127.0.0.1:5030",
                self.config.slskd_secret,
                self.config.ffprobe,
                self.config.ffmpeg,
                streamrip_master_config=str(self.master),
            )
        adapter = StreamripAdapter(
            shutil.which("true"),
            str(self.master),
            self.config.streamrip_runtime_root,
            run=Runner(),
        )
        runtime = adapter.runtime("00000000-0000-0000-0000-000000000001")
        adapter.write_config(runtime)
        self.master.unlink()
        self.master.symlink_to("missing")
        with self.assertRaises(Configuration):
            adapter.write_config(runtime)
        self.master.unlink()
        self.master.write_text("[qobuz]\nemail_or_userid = 'user'\n")
        with self.assertRaises(Configuration):
            adapter.write_config(runtime)
        self.master.write_text(
            "[qobuz]\nuse_auth_token = true\nemail_or_userid = 'user'\npassword_or_token = 'secret'\n"
        )
        duplicate = Runner(
            rows=[
                {"source": "qobuz", "media_type": "album", "id": "same", "desc": "A"},
                {"source": "qobuz", "media_type": "album", "id": "same", "desc": "A"},
            ]
        )
        adapter.run = duplicate
        self.assertEqual(len(adapter.search(runtime, "A")), 1)
        adapter.run = Runner(
            rows=[
                {"source": "qobuz", "media_type": "album", "id": "same", "desc": "A"},
                {"source": "qobuz", "media_type": "album", "id": "same", "desc": "B"},
            ]
        )
        with self.assertRaises(InvalidInput):
            adapter.search(runtime, "A")
        release = {
            "title": "Album",
            "artist": "Artist",
            "details": {
                "date": "2020-01-01",
                "media": [{"format": "Digital Media"}, {"format": "Digital Media"}],
            },
            "tracks": [
                {
                    "disc": 1,
                    "track": 1,
                    "title": "One",
                    "recording_mbid": "1",
                    "duration_ms": 1,
                },
                {
                    "disc": 1,
                    "track": 2,
                    "title": "Two",
                    "recording_mbid": "2",
                    "duration_ms": 1,
                },
                {
                    "disc": 2,
                    "track": 1,
                    "title": "Three",
                    "recording_mbid": "3",
                    "duration_ms": 1,
                },
                {
                    "disc": 2,
                    "track": 2,
                    "title": "Four",
                    "recording_mbid": "4",
                    "duration_ms": 1,
                },
            ],
        }
        tags = {
            "DISCNUMBER": " 01 / 02 ",
            "TRACKNUMBER": " 01 / 04 ",
            "TRACKTOTAL": "004",
            "TITLE": "One",
            "ALBUM": "Album",
            "ALBUMARTIST": "Artist",
            "DATE": "2020-01-01",
            "YEAR": "2020",
        }
        self.assertEqual(
            adapter._attribution(tags, release["tracks"][0], release)["track_total"],
            "4",
        )
        tags["TOTALTRACKS"] = "3"
        with self.assertRaises(InvalidInput):
            adapter._attribution(tags, release["tracks"][0], release)
