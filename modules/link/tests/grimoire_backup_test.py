"""Exercise live SQLite snapshots and a real Restic round trip in temp fixtures."""

import importlib.util
import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("grimoire_backup", sys.argv[1])
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)
config = json.loads(Path(sys.argv[2]).read_text()) if len(sys.argv) > 2 else None


class OnlineSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "live.db"
        self.destination = self.root / "snapshot.db"

    def live_database(self):
        live = sqlite3.connect(self.source)
        self.addCleanup(live.close)
        live.execute("PRAGMA journal_mode=WAL")
        live.execute("PRAGMA wal_autocheckpoint=0")
        live.execute("CREATE TABLE campaigns (name TEXT)")
        live.execute("INSERT INTO campaigns VALUES ('first campaign')")
        live.commit()
        return live

    def test_live_wal_and_committed_updates_are_restorable(self):
        live = self.live_database()
        self.assertGreater(Path(str(self.source) + "-wal").stat().st_size, 0)
        backup.snapshot(self.source, self.destination)
        with closing(sqlite3.connect(self.destination)) as restored:
            self.assertEqual(
                restored.execute("SELECT name FROM campaigns").fetchall(),
                [("first campaign",)],
            )
            self.assertEqual(
                restored.execute("PRAGMA integrity_check").fetchall(), [("ok",)]
            )
            self.assertEqual(
                restored.execute("PRAGMA journal_mode").fetchone()[0], "delete"
            )
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o600)
        self.assertTrue(Path(str(self.source) + "-wal").exists())
        live.execute("INSERT INTO campaigns VALUES ('second campaign')")
        live.commit()
        backup.snapshot(self.source, self.destination)
        with closing(sqlite3.connect(self.destination)) as restored:
            self.assertEqual(
                restored.execute("SELECT count(*) FROM campaigns").fetchone()[0], 2
            )
        self.assertEqual(list(self.root.glob(".snapshot.db-*")), [])

    def test_missing_source_does_not_create_a_database_or_replace_snapshot(self):
        self.destination.write_bytes(b"previous snapshot")
        with self.assertRaises(sqlite3.OperationalError):
            backup.snapshot(self.source, self.destination)
        self.assertFalse(self.source.exists())
        self.assertEqual(self.destination.read_bytes(), b"previous snapshot")
        self.assertEqual(list(self.root.glob(".snapshot.db-*")), [])

    def test_corrupt_source_preserves_the_previous_snapshot(self):
        self.source.write_bytes(b"not a SQLite database")
        self.destination.write_bytes(b"previous snapshot")
        with self.assertRaises(sqlite3.DatabaseError):
            backup.snapshot(self.source, self.destination)
        self.assertEqual(self.destination.read_bytes(), b"previous snapshot")
        self.assertEqual(list(self.root.glob(".snapshot.db-*")), [])

    def test_publish_failure_preserves_the_previous_snapshot(self):
        self.live_database()
        self.destination.write_bytes(b"previous snapshot")
        with (
            patch.object(
                backup.os, "replace", side_effect=OSError("fixture publish failure")
            ),
            self.assertRaises(OSError),
        ):
            backup.snapshot(self.source, self.destination)
        self.assertEqual(self.destination.read_bytes(), b"previous snapshot")
        self.assertEqual(list(self.root.glob(".snapshot.db-*")), [])

    def test_busy_or_continuously_changing_database_has_a_time_limit(self):
        self.live_database()
        self.destination.write_bytes(b"previous snapshot")
        with self.assertRaises(TimeoutError):
            backup.snapshot(self.source, self.destination, timeout_seconds=0)
        self.assertEqual(self.destination.read_bytes(), b"previous snapshot")
        self.assertEqual(list(self.root.glob(".snapshot.db-*")), [])


@unittest.skipUnless(config, "requires the evaluated NixOS fixture")
class ConfigurationTests(unittest.TestCase):
    def test_origin_and_family_gate(self):
        container = config["container"]
        self.assertEqual(config["backend"], "podman")
        self.assertEqual(container["ports"], ["127.0.0.1:9481:9481"])
        self.assertEqual(container["user"], "1000:100")
        self.assertEqual(
            container["image"],
            "docker.io/hunterreadca/grimoire:1.8.0@sha256:3c3bad0f15462538d3058d4d2b292a18d6487ee20a20a23718263d9f8ad6eb58",
        )
        self.assertEqual(config["route"]["backendAddress"], "127.0.0.1")
        self.assertEqual(config["route"]["proxy"]["host"], "link")
        self.assertEqual(config["route"]["health"]["path"], "/api/health")
        self.assertEqual(config["access"]["access"]["policy"], "family")
        self.assertFalse(config["access"]["access"]["bypassAccess"])
        self.assertEqual(config["dns"]["hostname"], "rpg.finnrut.is")
        self.assertIn(
            "location = /api/auth/setup { return 403; }", config["vhost"]["extraConfig"]
        )
        self.assertIn("rpg.finnrut.is", config["certificates"])
        self.assertNotIn(9481, config["firewallPorts"])
        self.assertNotIn("SECRET_KEY", container["environment"])
        self.assertEqual(container["environment"]["BACKUP_SCHEDULE"], "off")
        self.assertEqual(container["environment"]["GUEST_ACCESS_ENABLED"], "false")
        self.assertEqual(container["environment"]["BASE_URL"], "https://rpg.finnrut.is")

    def test_existing_library_and_kavita_state_are_preserved(self):
        self.assertIn(
            "/srv/kavita/library:/library/books/Imported",
            config["container"]["volumes"],
        )
        self.assertIn("/srv/grimoire/library:/library", config["container"]["volumes"])
        self.assertFalse(config["kavitaEnabled"])
        self.assertFalse(config["kavitaSecretDeclared"])
        self.assertIn("d /srv/kavita/library 0775 tunnel users -", config["tmpfiles"])
        self.assertIn("/var/lib/kavita", config["backup"]["paths"])
        self.assertFalse(
            any(
                rule.startswith(
                    (
                        "r /srv/kavita",
                        "R /srv/kavita",
                        "r /var/lib/kavita",
                        "R /var/lib/kavita",
                    )
                )
                for rule in config["tmpfiles"]
            )
        )

    def test_online_backup_joins_the_existing_schedule(self):
        for path in (
            "/srv/grimoire/data",
            "/srv/grimoire/library",
            "/srv/kavita/library",
            "/var/backup/grimoire",
        ):
            self.assertIn(path, config["backup"]["paths"])
        self.assertEqual(config["backup"]["timerConfig"]["OnCalendar"], "01:00")
        self.assertTrue(config["backup"]["timerConfig"]["Persistent"])
        self.assertEqual(
            config["backup"]["passwordFile"], "/run/agenix/restic/password"
        )
        self.assertTrue(
            any(
                "grimoire-sqlite-backup /srv/grimoire/data/grimoire.db /var/backup/grimoire/grimoire.db"
                in command
                for command in config["backup"]["preStart"]
            )
        )
        self.assertIn("notify-telegram@%n.service", config["backup"]["onFailure"])

    def test_nginx_setup_guard_is_valid_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            configuration = root / "nginx.conf"
            configuration.write_text(
                "error_log stderr;\n"
                f"pid {root}/nginx.pid;\n"
                "events {}\nhttp {\naccess_log off;\n"
                f"client_body_temp_path {root}/body;\n"
                f"proxy_temp_path {root}/proxy;\n"
                f"fastcgi_temp_path {root}/fastcgi;\n"
                f"uwsgi_temp_path {root}/uwsgi;\n"
                f"scgi_temp_path {root}/scgi;\n"
                "server { listen 127.0.0.1:19481;\n"
                + config["vhost"]["extraConfig"]
                + "\nlocation / { return 200; }\n}\n}\n"
            )
            result = subprocess.run(
                [
                    os.environ["NGINX_EXE"],
                    "-t",
                    "-c",
                    str(configuration),
                    "-p",
                    str(root),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)


@unittest.skipUnless(
    config and os.environ.get("RESTIC_EXE"),
    "requires evaluated paths and a fixture Restic binary",
)
class ResticRestoreTests(unittest.TestCase):
    def test_database_assets_and_both_libraries_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "srv/grimoire/data"
            library = root / "srv/grimoire/library"
            imported = root / "srv/kavita/library"
            snapshots = root / "var/backup/grimoire"
            for path in (data, library, imported, snapshots):
                path.mkdir(parents=True)
            files = {
                data / "secret_key": b"signing-key test fixture",
                data / "campaign_uploads/banner.png": b"campaign asset fixture",
                data / "character_portraits/portrait.png": b"portrait fixture",
                data / "system_covers/cover.png": b"cover fixture",
                library / "maps/map.png": b"map fixture",
                imported / "book.pdf": b"book fixture",
            }
            for path, contents in files.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            cache = data / "page_cache/page.png"
            cache.parent.mkdir()
            cache.write_bytes(b"regenerable cache")
            with closing(sqlite3.connect(data / "grimoire.db")) as live:
                live.execute("PRAGMA journal_mode=WAL")
                live.execute("PRAGMA wal_autocheckpoint=0")
                live.execute("CREATE TABLE campaigns (name TEXT)")
                live.execute("INSERT INTO campaigns VALUES ('restored campaign')")
                live.commit()
                backup.snapshot(data / "grimoire.db", snapshots / "grimoire.db")

                password = root / "fixture-password"
                password.write_text("temporary Restic test repository only\n")
                environment = os.environ | {"RESTIC_CACHE_DIR": str(root / "cache")}
                command = [
                    os.environ["RESTIC_EXE"],
                    "--repo",
                    str(root / "repository"),
                    "--password-file",
                    str(password),
                ]

                def restic(*args):
                    result = subprocess.run(
                        command + list(args),
                        env=environment,
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

                restic("init")
                arguments = [
                    "backup",
                    *(str(path) for path in (data, library, imported, snapshots)),
                ]
                for exclude in config["backup"]["exclude"]:
                    if exclude.startswith("/srv/grimoire/data/"):
                        arguments.extend(["--exclude", str(root) + exclude])
                restic(*arguments)
                target = root / "restored"
                restic("restore", "latest", "--target", str(target))

                def restored(path):
                    return target / str(path).lstrip("/")

                for path, contents in files.items():
                    self.assertEqual(restored(path).read_bytes(), contents)
                self.assertFalse(restored(data / "grimoire.db").exists())
                self.assertFalse(restored(data / "grimoire.db-wal").exists())
                self.assertFalse(restored(data / "grimoire.db-shm").exists())
                self.assertFalse(restored(cache).exists())
                recovered_database = restored(snapshots / "grimoire.db")
                with closing(sqlite3.connect(recovered_database)) as recovered:
                    self.assertEqual(
                        recovered.execute("PRAGMA integrity_check").fetchall(),
                        [("ok",)],
                    )
                    self.assertEqual(
                        recovered.execute("SELECT name FROM campaigns").fetchall(),
                        [("restored campaign",)],
                    )


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
