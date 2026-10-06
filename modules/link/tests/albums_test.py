"""Exercise the host launchers with synthetic files, never live beets data."""

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(sys.argv.pop(1))


class AlbumGraphHostTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.store = self.root / "vectors.sqlite3"
        self.store.write_bytes(b"synthetic store")
        self.library = self.root / "library.db"
        self.library.write_bytes(b"synthetic library")
        self.config = self.root / "config.yaml"
        self.config.write_text("synthetic config\n")
        self.output = self.state / "albums.json"
        self.launcher = self.root / "beet"
        self.launcher.write_text(
            f"#!{sys.executable}\n"
            "import fcntl, json, os, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['TEST_WAITING']).touch()\n"
            "with open(os.environ['TEST_LOCK'], 'w') as lock:\n"
            "    fcntl.flock(lock, fcntl.LOCK_EX)\n"
            "    Path(os.environ['TEST_ARGS']).write_text(json.dumps(sys.argv[1:]))\n"
            "    out = Path(sys.argv[sys.argv.index('-o') + 1])\n"
            "    out.write_text('partial' if os.environ.get('TEST_FAIL') else '{}\\n')\n"
            "    out.chmod(0o600)\n"
            "    if os.environ.get('TEST_FAIL'): sys.exit(42)\n"
        )
        self.launcher.chmod(0o755)
        self.env = os.environ | {
            "BEETS_GRAPH_STATE": str(self.state),
            "BEETS_GRAPH_STORE": str(self.store),
            "BEETS_GRAPH_CONFIG": str(self.config),
            "BEETS_GRAPH_LAUNCHER": str(self.launcher),
            "TEST_LOCK": str(self.root / ".import.lock"),
            "TEST_WAITING": str(self.root / "waiting"),
            "TEST_ARGS": str(self.root / "args.json"),
        }

    def command(self, script="albums-export.sh"):
        return ["bash", "-euo", "pipefail", str(SCRIPTS / script)]

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
        self.assertEqual(list(self.state.iterdir()), [])

    def test_missing_store_keeps_last_good_export(self):
        self.output.write_text("previous")
        self.store.unlink()
        self.assertEqual(self.run_export().returncode, 0)
        self.assertEqual(self.output.read_text(), "previous")

    def test_success_uses_locked_launcher_and_prepares_reader_permissions(self):
        self.output.write_text("previous")
        previous_inode = self.output.stat().st_ino
        inputs = {
            path: path.read_bytes() for path in [self.store, self.library, self.config]
        }
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.root / "args.json").read_text())
        self.assertEqual(
            arguments[:-1],
            [
                "-c",
                str(self.config),
                "-p",
                "embed",
                "embed-graph-export",
                "--store",
                str(self.store),
                "--model",
                "style",
                "-o",
            ],
        )
        self.assertEqual(Path(arguments[-1]).parent.parent, self.state)
        self.assertEqual(self.output.read_text(), "{}\n")
        self.assertNotEqual(self.output.stat().st_ino, previous_inode)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.state.iterdir()), [self.output])
        for path, original in inputs.items():
            self.assertEqual(path.read_bytes(), original)

    def test_failed_export_preserves_previous_data_and_cleans_staging(self):
        self.output.write_text("previous")
        result = self.run_export(TEST_FAIL="1")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.output.read_text(), "previous")
        self.assertEqual(list(self.state.iterdir()), [self.output])

    def test_export_waits_for_launcher_import_lock(self):
        self.output.write_text("previous")
        with open(self.env["TEST_LOCK"], "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            child = subprocess.Popen(
                self.command(),
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while (
                    not (self.root / "waiting").exists() and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertTrue((self.root / "waiting").exists())
                self.assertIsNone(child.poll())
                self.assertEqual(self.output.read_text(), "previous")
                self.assertFalse((self.root / "args.json").exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
                _, stderr = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, stderr)
                self.assertEqual(self.output.read_text(), "{}\n")
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()

    def viewer_arguments(self):
        viewer = self.root / "viewer"
        viewer.write_text(
            f"#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n"
        )
        viewer.chmod(0o755)
        result = subprocess.run(
            self.command("albums-viewer.sh"),
            env=self.env | {"BEETS_GRAPH_VIEWER": str(viewer)},
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout)

    def test_viewer_starts_without_data_for_file_picker(self):
        self.assertEqual(self.viewer_arguments(), ["--port", "8765"])
        self.assertFalse(self.output.exists())

    def test_viewer_enables_data_after_export(self):
        self.assertEqual(self.run_export().returncode, 0)
        self.assertEqual(
            self.viewer_arguments(), ["--port", "8765", "--data", str(self.output)]
        )


if __name__ == "__main__":
    unittest.main()
