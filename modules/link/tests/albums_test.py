"""Exercise the host launchers with synthetic files, never live beets data."""

import fcntl
import http.client
import importlib.util
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from pathlib import Path

from PIL import Image

EXPORT = Path(sys.argv.pop(1))
VIEWER = Path(sys.argv.pop(1))
COVERS_MODULE = Path(sys.argv.pop(1))
NGINX = Path(sys.argv.pop(1))
PROXY_CONFIG = Path(sys.argv.pop(1))
SERVER_MODULE = Path(sys.argv.pop(1))
SNAPSHOT = Path(sys.argv.pop(1))
BOOKMARKS = Path(sys.argv.pop(1))
LIFE_EVENTS = Path(sys.argv.pop(1))
LIFE_EVENTS_SCHEMA = Path(sys.argv.pop(1))


class AlbumGraphHostTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.covers = self.state / "covers"
        self.covers.mkdir(mode=0o750)
        self.cache = self.state / "cache"
        self.cache.mkdir(mode=0o2770)
        self.query_cache = self.cache / "query"
        self.query_cache.mkdir(mode=0o700)
        self.art = self.root / "art.png"
        Image.new("RGB", (48, 32), "red").save(self.art)
        self.store = self.root / "vectors.sqlite3"
        with sqlite3.connect(self.store) as database:
            database.execute("CREATE TABLE fixture(value)")
            database.execute("INSERT INTO fixture VALUES (1)")
        self.library = self.root / "library.db"
        with sqlite3.connect(self.library) as database:
            database.execute("CREATE TABLE fixture(value)")
            database.execute("INSERT INTO fixture VALUES (2)")
            database.execute("CREATE TABLE albums(id INTEGER PRIMARY KEY, added REAL)")
            database.execute("INSERT INTO albums VALUES (1, 1640995200)")
            database.execute(
                "CREATE TABLE album_attributes(entity_id INTEGER, key TEXT, value TEXT)"
            )
            database.execute(
                "INSERT INTO album_attributes VALUES (1, 'lastfm_first_played', '1609459200')"
            )
        self.config = self.root / "config.yaml"
        self.config.write_text("synthetic config\n")
        self.events = self.root / "life-events.json"
        self.events.write_bytes(LIFE_EVENTS.read_bytes())
        self.output = self.state / "albums.json"
        self.launcher = self.root / "beet"
        self.launcher.write_text(
            f"#!{sys.executable}\n"
            "import importlib.util, json, os, sqlite3, sys\n"
            "from pathlib import Path\n"
            "sys.dont_write_bytecode = True\n"
            "spec = importlib.util.spec_from_file_location('covers', os.environ['TEST_COVERS_MODULE'])\n"
            "covers = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(covers)\n"
            "Path(os.environ['TEST_WAITING']).touch()\n"
            "for flag, value in [('-l', 2), ('--store', 1)]:\n"
            "    path = Path(sys.argv[sys.argv.index(flag) + 1])\n"
            "    assert path.parent.parent == Path(os.environ['BEETS_GRAPH_STATE'])\n"
            "    with sqlite3.connect(path) as database:\n"
            "        assert database.execute('SELECT value FROM fixture').fetchone()[0] == value\n"
            "        database.execute('UPDATE fixture SET value=99')\n"
            "Path(os.environ['TEST_ARGS']).write_text(json.dumps(sys.argv[1:]))\n"
            "out = Path(sys.argv[sys.argv.index('-o') + 1])\n"
            "cache_dir = sys.argv[sys.argv.index('--covers-dir') + 1]\n"
            "cache = covers.CoverCache(cache_dir, [Path(os.environ['TEST_ART'])], [out])\n"
            "name = cache.cover(Path(os.environ['TEST_ART']))\n"
            "large = cache.cover(Path(os.environ['TEST_ART']), large=True)\n"
            "phrase_cache = Path(sys.argv[sys.argv.index('--cache-dir') + 1]) / 'phrases-fixture.npz'\n"
            "if not phrase_cache.exists():\n"
            "    phrase_cache.write_bytes(b'synthetic phrase cache')\n"
            "exported = {'schema_version': 3, 'albums': [{'id': 1, 'added': '2022-01-01T00:00:00Z', 'cover': name, 'cover_large': large}]}\n"
            "exported['albums'].extend(json.loads(os.environ.get('TEST_ALBUMS', '[]')))\n"
            "Path(os.environ['TEST_UNENRICHED']).write_text(json.dumps(exported))\n"
            "if os.environ.get('TEST_BAD_GRAPH'):\n"
            "    del exported['albums'][0]['id']\n"
            "out.write_text('partial' if os.environ.get('TEST_FAIL') else json.dumps(exported))\n"
            "out.chmod(0o600)\n"
            "if os.environ.get('TEST_FAIL'):\n"
            "    cache.abort()\n"
            "    sys.exit(42)\n"
            "cache.finish()\n"
        )
        self.launcher.chmod(0o755)
        self.env = os.environ | {
            "BEETS_GRAPH_STATE": str(self.state),
            "BEETS_GRAPH_COVERS": str(self.covers),
            "BEETS_GRAPH_CACHE": str(self.cache),
            "BEETS_GRAPH_STORE": str(self.store),
            "BEETS_GRAPH_LIBRARY": str(self.library),
            "BEETS_GRAPH_SNAPSHOT": str(SNAPSHOT),
            "BEETS_GRAPH_BOOKMARKS": str(BOOKMARKS),
            "BEETS_GRAPH_LIFE_EVENTS": str(self.events),
            "BEETS_GRAPH_LIFE_EVENTS_SCHEMA": str(LIFE_EVENTS_SCHEMA),
            "BEETS_GRAPH_CONFIG": str(self.config),
            "BEETS_GRAPH_LAUNCHER": str(self.launcher),
            "TEST_LOCK": str(self.root / ".import.lock"),
            "TEST_WAITING": str(self.root / "waiting"),
            "TEST_ARGS": str(self.root / "args.json"),
            "TEST_ART": str(self.art),
            "TEST_COVERS_MODULE": str(COVERS_MODULE),
            "TEST_UNENRICHED": str(self.root / "unenriched.json"),
        }

    def command(self):
        return [str(EXPORT)]

    def run_export(self, **environment):
        return subprocess.run(
            self.command(),
            env=self.env | environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_missing_store_skips_without_creating_data_or_invoking_beets(self):
        self.store.unlink()
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("embeddings store is missing", result.stdout)
        self.assertFalse(self.store.exists())
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root / "waiting").exists())
        self.assertEqual(set(self.state.iterdir()), {self.covers, self.cache})
        self.assertEqual(list(self.cache.iterdir()), [self.query_cache])
        self.assertEqual(list(self.covers.iterdir()), [])

    def test_missing_store_keeps_last_good_export(self):
        self.output.write_text("previous")
        self.store.unlink()
        self.assertEqual(self.run_export().returncode, 0)
        self.assertEqual(self.output.read_text(), "previous")

    def test_success_uses_private_snapshots_and_prepares_reader_permissions(self):
        self.output.write_text("previous")
        previous_inode = self.output.stat().st_ino
        inputs = {
            path: path.read_bytes()
            for path in [self.store, self.library, self.config, self.art]
        }
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.root / "args.json").read_text())
        self.assertEqual(
            arguments[:-1],
            [
                "-c",
                str(self.config),
                "-l",
                arguments[3],
                "-p",
                "embed",
                "embed-graph-export",
                "--store",
                arguments[8],
                "--model",
                "style",
                "--covers-dir",
                str(self.covers),
                "--cache-dir",
                str(self.cache),
                "-o",
            ],
        )
        self.assertEqual(Path(arguments[3]).name, "library.db")
        self.assertEqual(Path(arguments[8]).name, "embeddings.sqlite3")
        self.assertEqual(Path(arguments[-1]).parent.parent, self.state)
        exported = json.loads(self.output.read_text())
        self.assertEqual(exported["schema_version"], 3)
        self.assertEqual(len(exported["bookmarks"]), 9)
        self.assertNotIn("sober-date", {e["id"] for e in exported["bookmarks"]})
        derived = next(
            e for e in exported["bookmarks"] if e["id"] == "beets-library-import"
        )
        self.assertEqual(derived["date"], "2022-01-01")
        original = json.loads((self.root / "unenriched.json").read_text())
        stripped = {key: value for key, value in exported.items() if key != "bookmarks"}
        stripped["albums"] = [
            {
                key: value
                for key, value in album.items()
                if key not in ("first_played", "first_played_source")
            }
            for album in exported["albums"]
        ]
        self.assertEqual(stripped, original)
        self.assertEqual(exported["albums"][0]["added"], "2022-01-01T00:00:00Z")
        self.assertEqual(exported["albums"][0]["first_played"], "2021-01-01")
        self.assertEqual(exported["albums"][0]["first_played_source"], "lastfm")
        thumbnail = self.covers / exported["albums"][0]["cover"]
        self.assertTrue(thumbnail.is_file())
        self.assertEqual(thumbnail.stat().st_mode & 0o777, 0o640)
        self.assertEqual(thumbnail.stat().st_gid, os.getegid())
        manifest = self.covers / ".album-graph-covers.json"
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o640)
        self.assertEqual(manifest.stat().st_gid, os.getegid())
        large = self.covers / exported["albums"][0]["cover_large"]
        self.assertTrue(large.is_file())
        self.assertEqual(large.stat().st_mode & 0o777, 0o640)
        self.assertEqual(large.stat().st_gid, os.getegid())
        self.assertEqual(
            json.loads(manifest.read_text())["files"],
            sorted([thumbnail.name, large.name]),
        )
        self.assertEqual(self.covers.stat().st_mode & 0o777, 0o750)
        with Image.open(thumbnail) as image:
            self.assertEqual(image.size, (256, 256))
            self.assertEqual(image.format, "JPEG")
        with Image.open(large) as image:
            self.assertEqual(image.size, (512, 512))
            self.assertEqual(image.format, "JPEG")
        self.assertNotEqual(self.output.stat().st_ino, previous_inode)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o640)
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )
        for path, original in inputs.items():
            self.assertEqual(path.read_bytes(), original)

    def test_failed_export_preserves_previous_data_and_cleans_staging(self):
        self.output.write_text("previous")
        result = self.run_export(TEST_FAIL="1")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.output.read_text(), "previous")
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )
        self.assertEqual(list(self.covers.iterdir()), [])

    def test_bookmarks_exclude_private_events_and_all_notes(self):
        events = json.loads(self.events.read_text())
        events[0]["note"] = "public event private note sentinel"
        events[-1]["note"] = "private event note sentinel"
        self.events.write_text(json.dumps(events))
        result = self.run_export(
            TEST_ALBUMS=json.dumps(
                [
                    {"id": 2, "added": "2024-03-04T12:00:00Z"},
                    {"id": 3, "added": "2020-12-31T23:30:00-02:00"},
                    {"id": 4, "added": None},
                ]
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = self.output.read_text()
        for private_value in (
            "sober-date",
            "Sober date",
            "2024-08-21",
            events[0]["note"],
            events[-1]["note"],
        ):
            self.assertNotIn(private_value, exported)
        bookmarks = json.loads(exported)["bookmarks"]
        self.assertEqual(len(bookmarks), 9)
        for bookmark in bookmarks:
            self.assertEqual(
                set(bookmark),
                {
                    "id",
                    "date",
                    "end_date",
                    "precision",
                    "title",
                    "category",
                },
            )
        derived = next(e for e in bookmarks if e["id"] == "beets-library-import")
        self.assertEqual(derived["date"], "2021-01-01")

    def test_invalid_life_events_preserve_previous_export_and_clean_staging(self):
        self.assertEqual(self.run_export().returncode, 0)
        previous = self.output.read_bytes()
        events = json.loads(self.events.read_text())
        del events[0]["visibility"]
        self.events.write_text(json.dumps(events))
        result = self.run_export()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("required", result.stderr)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )

    def test_missing_life_events_fail_closed(self):
        self.output.write_text("previous")
        self.events.unlink()
        result = self.run_export()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.output.read_text(), "previous")
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )

    def test_failed_enrichment_preserves_previous_data_and_cleans_staging(self):
        self.output.write_text("previous")
        result = self.run_export(TEST_BAD_GRAPH="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(self.output.read_text(), "previous")
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )

    def test_enrichments_preserve_each_others_fields(self):
        self.assertEqual(self.run_export().returncode, 0)
        published = json.loads(self.output.read_text())
        self.assertEqual(published["albums"][0]["first_played"], "2021-01-01")
        self.assertEqual(len(published["bookmarks"]), 9)
        # Repeating bookmarks after first-played must retain all album fields;
        # repeating first-played after bookmarks must retain the whole timeline.
        for command in (
            [
                str(BOOKMARKS),
                "export",
                str(self.events),
                str(LIFE_EVENTS_SCHEMA),
                str(self.output),
            ],
            [str(SNAPSHOT), "enrich-first-played", str(self.library), str(self.output)],
        ):
            result = subprocess.run(
                command, capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(self.output.read_text()), published)

    def test_export_creates_cache_with_group_traverse_permission(self):
        self.covers.rmdir()
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.covers.stat().st_mode & 0o777, 0o750)
        self.assertEqual(self.covers.stat().st_gid, os.getegid())

    def test_repeated_export_reuses_persistent_cache_and_preserves_manifest(self):
        self.assertEqual(self.run_export().returncode, 0)
        files = {
            path: (path.read_bytes(), path.stat().st_mtime_ns)
            for path in self.covers.glob("*.jpg")
        }
        self.assertEqual(len(files), 2)
        self.assertEqual(self.run_export().returncode, 0)
        for path, (contents, modified) in files.items():
            self.assertEqual(path.read_bytes(), contents)
            self.assertEqual(path.stat().st_mtime_ns, modified)
        self.assertTrue((self.covers / ".album-graph-covers.json").is_file())
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )

    def test_export_reuses_descriptor_cache_without_touching_viewer_cache(self):
        viewer_cache = self.query_cache / "runtime"
        viewer_cache.write_bytes(b"viewer-owned cache")
        self.assertEqual(self.run_export().returncode, 0)
        phrase_cache = self.cache / "phrases-fixture.npz"
        modified = phrase_cache.stat().st_mtime_ns
        self.assertEqual(self.run_export().returncode, 0)
        self.assertEqual(phrase_cache.stat().st_mtime_ns, modified)
        self.assertEqual(viewer_cache.read_bytes(), b"viewer-owned cache")

    def test_failed_refresh_preserves_json_and_previous_covers(self):
        self.assertEqual(self.run_export().returncode, 0)
        previous = self.output.read_bytes()
        cache = {path: path.read_bytes() for path in self.covers.iterdir()}
        Image.new("RGB", (48, 32), "blue").save(self.art)
        self.assertEqual(self.run_export(TEST_FAIL="1").returncode, 42)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(
            {path: path.read_bytes() for path in self.covers.iterdir()}, cache
        )
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )

    def test_refresh_prunes_stale_covers_without_deleting_unrelated_files(self):
        self.assertEqual(self.run_export().returncode, 0)
        previous = set(self.covers.glob("*.jpg"))
        unrelated = self.covers / "keep.txt"
        unrelated.write_text("unrelated")
        Image.new("RGB", (48, 32), "blue").save(self.art)
        self.assertEqual(self.run_export().returncode, 0)
        self.assertTrue(all(not path.exists() for path in previous))
        current = (
            self.covers / json.loads(self.output.read_text())["albums"][0]["cover"]
        )
        self.assertTrue(current.is_file())
        self.assertEqual(unrelated.read_text(), "unrelated")

    def test_export_completes_while_backfill_holds_import_lock(self):
        with open(self.env["TEST_LOCK"], "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = subprocess.run(
                self.command(),
                env=self.env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(self.output.read_text())["schema_version"], 3)
            # The exporter never released or replaced the backfill's lock.
            with (
                open(self.env["TEST_LOCK"]) as contender,
                self.assertRaises(BlockingIOError),
            ):
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_snapshot_failure_keeps_previous_export_and_cleans_staging(self):
        self.output.write_text("previous")
        self.library.write_bytes(b"not a database")
        result = self.run_export()
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn("snapshot failed", result.stderr)
        self.assertEqual(self.output.read_text(), "previous")
        self.assertFalse((self.root / "args.json").exists())
        self.assertEqual(
            set(self.state.iterdir()), {self.output, self.covers, self.cache}
        )

    def viewer_arguments(self):
        viewer = self.root / "viewer"
        viewer.write_text(
            f"#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n"
        )
        viewer.chmod(0o755)
        result = subprocess.run(
            [str(VIEWER)],
            env=self.env | {"BEETS_GRAPH_VIEWER": str(viewer)},
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout)

    def test_viewer_starts_without_data_for_file_picker(self):
        self.assertEqual(
            self.viewer_arguments(),
            [
                "--port",
                "8765",
                "--covers",
                str(self.covers),
                "--cache-dir",
                str(self.cache),
            ],
        )
        self.assertFalse(self.output.exists())

    def test_viewer_enables_data_after_export(self):
        self.assertEqual(self.run_export().returncode, 0)
        self.assertEqual(
            self.viewer_arguments(),
            [
                "--port",
                "8765",
                "--covers",
                str(self.covers),
                "--cache-dir",
                str(self.cache),
                "--data",
                str(self.output),
            ],
        )


class AlbumGraphProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise upstream's actual Host/Origin/Fetch Metadata checks, with
        # synthetic embeddings so this fixture never loads Torch or real data.
        sys.path.insert(0, str(SERVER_MODULE.parent))
        spec = importlib.util.spec_from_file_location(
            "album_graph_server", SERVER_MODULE
        )
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.queries = []
        self.query_started = threading.Event()
        self.query_finished = threading.Event()
        self.query_release = threading.Event()
        self.query_release.set()
        self.assets = self.root / "assets"
        self.assets.mkdir()
        (self.assets / "index.html").write_text("fixture viewer")
        (self.assets / "app.js").write_text("fixture script")
        (self.assets / "private.json").write_text("must not be served")
        self.data = self.root / "albums.json"
        self.data.write_text(
            json.dumps({"albums": [{"summed_plays": 17, "mean_plays": 8.5}]})
        )
        self.covers = self.root / "covers"
        self.covers.mkdir()
        self.cover = "cover-" + "a" * 64 + ".jpg"
        Image.new("RGB", (8, 8), "red").save(self.covers / self.cover)

        class Queries:
            def query(inner, phrase):
                self.queries.append(phrase)
                self.query_started.set()
                if not self.query_release.wait(timeout=5):
                    raise RuntimeError("fixture query was not released")
                self.query_finished.set()
                return {"model_id": "text:fixture", "vector": [1.0] + [0.0] * 511}

            def close(inner):
                pass

        handler = partial(
            self.module.Handler,
            directory=str(self.assets),
            data=self.data,
            covers=self.covers,
        )
        self.backend = self.module.Server(
            ("127.0.0.1", 0), handler, text_query=Queries()
        )
        self.thread = threading.Thread(target=self.backend.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_backend)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        config = PROXY_CONFIG.read_text().replace("@ROOT@", str(self.root))
        config = config.replace("@PROXY_PORT@", str(self.port))
        config = config.replace("@BACKEND_PORT@", str(self.backend.server_port))
        self.config = self.root / "nginx.conf"
        self.config.write_text(config)
        self.nginx_log = (self.root / "nginx.log").open("w+")
        self.addCleanup(self.nginx_log.close)
        self.proxy = subprocess.Popen(
            [
                str(NGINX),
                "-p",
                str(self.root),
                "-c",
                str(self.config),
                "-g",
                "daemon off;",
            ],
            stdout=self.nginx_log,
            stderr=self.nginx_log,
        )
        self.addCleanup(self.stop_proxy)
        self.addCleanup(self.query_release.set)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.proxy.poll() is not None:
                self.nginx_log.seek(0)
                self.fail(self.nginx_log.read())
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.01)
        self.fail("nginx fixture did not start")

    def stop_backend(self):
        self.backend.shutdown()
        self.backend.server_close()
        self.thread.join(timeout=5)

    def stop_proxy(self):
        if self.proxy.poll() is None:
            self.proxy.terminate()
            self.proxy.wait(timeout=5)

    def request(
        self,
        *,
        origin=None,
        fetch_site="same-origin",
        body=None,
        cf_client=None,
        source="127.0.0.1",
        host="albums.finnrut.is",
        method="POST",
        path="/api/embed-text",
    ):
        headers = {
            "Host": host,
            "Content-Type": "application/json",
            "Sec-Fetch-Site": fetch_site,
        }
        if origin is not None:
            headers["Origin"] = origin
        if cf_client is not None:
            headers["CF-Connecting-IP"] = cf_client
        if body is None and method == "POST":
            body = json.dumps({"q": "rainy night jazz piano"})
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.port, timeout=5, source_address=(source, 0)
        )
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_same_origin_post_reaches_upstream_and_is_not_cached(self):
        status, headers, body = self.request(origin="https://albums.finnrut.is")
        self.assertEqual(status, 200, body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(self.queries, ["rainy night jazz piano"])
        self.assertEqual(json.loads(body)["model_id"], "text:fixture")

    def test_internal_origin_post_reaches_upstream(self):
        status, _, body = self.request(origin="https://albums.nyc.finnrut.is")
        self.assertEqual(status, 200, body)
        self.assertEqual(self.queries, ["rainy night jazz piano"])

    def test_internal_name_redirects_to_public_name_with_query_string(self):
        status, headers, _ = self.request(
            method="GET", host="albums.nyc.finnrut.is", path="/?data=data.json"
        )
        self.assertEqual(status, 308)
        self.assertEqual(
            headers["Location"], "https://albums.finnrut.is/?data=data.json"
        )

    def test_absent_origin_remains_absent_and_query_works(self):
        status, _, body = self.request()
        self.assertEqual(status, 200, body)

    def test_wrong_origin_is_rejected_before_embedding(self):
        for origin in [
            "https://evil.example",
            "null",
            "http://albums.finnrut.is",
            "http://albums.nyc.finnrut.is",
            "https://albums.finnrut.is.evil.example",
        ]:
            with self.subTest(origin=origin):
                status, _, _ = self.request(origin=origin)
                self.assertEqual(status, 403)
        self.assertEqual(self.queries, [])

    def test_cross_site_fetch_metadata_is_preserved_and_rejected(self):
        status, _, _ = self.request(
            origin="https://albums.finnrut.is", fetch_site="cross-site"
        )
        self.assertEqual(status, 403)
        self.assertEqual(self.queries, [])

    def test_oversized_post_is_rejected_before_embedding(self):
        status, _, _ = self.request(body="x" * 4097)
        self.assertEqual(status, 413)
        self.assertEqual(self.queries, [])

    def exhaust_rate(self, **kwargs):
        # The fast synthetic backend isolates nginx from the encoder's own
        # two-starts-per-second limit. No model or real library is involved.
        for _ in range(11):
            status, _, body = self.request(**kwargs)
            self.assertEqual(status, 200, body)
        status, _, _ = self.request(**kwargs)
        self.assertEqual(status, 429)
        self.assertEqual(len(self.queries), 11)

    def test_rate_limit_uses_client_ip_from_each_trusted_connector(self):
        self.exhaust_rate(cf_client="198.51.100.10")
        status, _, _ = self.request(cf_client="198.51.100.10", source="127.0.0.4")
        self.assertEqual(status, 429)
        status, _, body = self.request(cf_client="2001:db8::20", source="127.0.0.4")
        self.assertEqual(status, 200, body)
        self.assertEqual(len(self.queries), 12)

    def test_untrusted_peer_cannot_rotate_header_to_evade_rate_limit(self):
        for index in range(12):
            status, _, body = self.request(
                cf_client=f"198.51.100.{index + 1}", source="127.0.0.2"
            )
            self.assertEqual(status, 200 if index < 11 else 429, body)
        self.assertEqual(len(self.queries), 11)

    def test_missing_client_header_falls_back_to_peer_address(self):
        self.exhaust_rate()
        status, _, _ = self.request(cf_client="")
        self.assertEqual(status, 429)
        status, _, body = self.request(source="127.0.0.2")
        self.assertEqual(status, 200, body)

    def test_client_header_does_not_replace_generated_acl_peer_address(self):
        status, _, _ = self.request(cf_client="127.0.0.1", source="127.0.0.3")
        self.assertEqual(status, 403)
        self.assertEqual(self.queries, [])

    def assert_assets_available(self, **kwargs):
        for path in ["/index.html", "/app.js", "/data.json", f"/covers/{self.cover}"]:
            with self.subTest(path=path):
                status, _, body = self.request(method="GET", path=path, **kwargs)
                self.assertEqual(status, 200, body)
                if path == "/data.json":
                    self.assertEqual(
                        json.loads(body)["albums"][0],
                        {"summed_plays": 17, "mean_plays": 8.5},
                    )
        status, _, _ = self.request(method="GET", path="/private.json", **kwargs)
        self.assertEqual(status, 404)

    def test_assets_and_play_counts_are_available_after_text_rate_limit(self):
        self.exhaust_rate(cf_client="198.51.100.10")
        self.assert_assets_available(cf_client="198.51.100.10")
        self.assertEqual(len(self.queries), 11)

    def test_global_concurrency_limit_matches_one_worker_and_releases_slot(self):
        self.query_release.clear()
        with ThreadPoolExecutor(max_workers=1) as executor:
            active = executor.submit(self.request, cf_client="198.51.100.10")
            try:
                self.assertTrue(self.query_started.wait(timeout=3))
                status, _, _ = self.request(
                    cf_client="198.51.100.20", source="127.0.0.4"
                )
                self.assertEqual(status, 429)
                self.assert_assets_available(cf_client="198.51.100.20")
                self.assertEqual(len(self.queries), 1)
            finally:
                self.query_release.set()
            self.assertEqual(active.result(timeout=3)[0], 200)
        status, _, body = self.request(cf_client="198.51.100.30")
        self.assertEqual(status, 200, body)

    def test_disconnect_keeps_inference_slot_until_upstream_finishes(self):
        self.query_release.clear()
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        self.addCleanup(connection.close)
        connection.request(
            "POST",
            "/api/embed-text",
            body=json.dumps({"q": "rainy night jazz piano"}),
            headers={
                "Host": "albums.finnrut.is",
                "Content-Type": "application/json",
                "CF-Connecting-IP": "198.51.100.10",
            },
        )
        try:
            self.assertTrue(self.query_started.wait(timeout=3))
            connection.sock.shutdown(socket.SHUT_RDWR)
            connection.close()
            # Give nginx time to observe the disconnect, then prove a fresh IP
            # still cannot start inference. Bounds avoid a timing-only pass.
            for index in range(3):
                time.sleep(0.05)
                status, _, _ = self.request(cf_client=f"198.51.100.{20 + index}")
                self.assertEqual(status, 429)
            self.assertEqual(len(self.queries), 1)
        finally:
            self.query_release.set()
        self.assertTrue(self.query_finished.wait(timeout=3))
        deadline = time.monotonic() + 3
        attempt = 0
        while time.monotonic() < deadline:
            status, _, body = self.request(cf_client=f"2001:db8::{attempt + 1}")
            if status == 200:
                return
            self.assertEqual(status, 429, body)
            attempt += 1
            time.sleep(0.01)
        self.fail("nginx did not release the completed inference slot")

    def test_viewer_busy_429_is_preserved_without_loading_model(self):
        query = self.module.TextQuery("fixture-worker", self.root / "encoder")
        self.backend.text_query = query
        query.gate.acquire()
        try:
            status, headers, body = self.request()
            self.assertEqual(status, 429)
            self.assertIn("Text encoder is busy", json.loads(body)["error"])
            self.assertEqual(headers["Retry-After"], "1")
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertIsNone(query.child)
        finally:
            query.gate.release()


if __name__ == "__main__":
    unittest.main()
