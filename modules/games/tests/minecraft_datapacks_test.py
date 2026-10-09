"""Managed archives are recoverable, isolated from other packs, and backed up as bytes."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location("datapacks", sys.argv.pop(1))
datapacks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(datapacks)


class DatapacksTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "world/datapacks"
        self.source = self.root / "policy.zip"
        self.make_pack(self.source)
        self.configuration = {"directory": str(self.directory), "packs": {"world-policy": str(self.source)}}

    def make_pack(self, source, value="50", metadata=None):
        datapacks.build({
            "pack.mcmeta": json.dumps({"pack": metadata or {"min_format": [121, 0], "max_format": [121, 0]}}),
            "data/infra/function/world_policy.mcfunction": f"gamerule minecraft:players_sleeping_percentage {value}\n",
        }, source)

    def test_deterministic_pack_and_idempotent_install(self):
        second = self.root / "second.zip"
        self.make_pack(second)
        self.assertEqual(self.source.read_bytes(), second.read_bytes())
        datapacks.install(self.configuration)
        target = self.directory / "infra-world-policy.zip"
        original = target.stat().st_mtime_ns
        datapacks.install(self.configuration)
        self.assertEqual(target.stat().st_mtime_ns, original)
        self.assertFalse(target.is_symlink())
        self.assertEqual(target.read_bytes(), self.source.read_bytes())
        self.assertEqual(json.loads((self.directory / datapacks.LEDGER).read_text()), {
            target.name: [datapacks.digest(self.source)],
        })

    def test_update_and_removal_preserve_other_packs_and_world_files(self):
        datapacks.install(self.configuration)
        manual = self.directory / "friends.zip"
        manual.write_bytes(b"unmanaged")
        region = self.directory.parent / "region"
        region.mkdir()
        chunk = region / "r.0.0.mca"
        chunk.write_bytes(b"world data")
        self.make_pack(self.source, "75")
        datapacks.install(self.configuration)
        with zipfile.ZipFile(self.directory / "infra-world-policy.zip") as archive:
            self.assertIn(b"75", archive.read("data/infra/function/world_policy.mcfunction"))
        datapacks.install({**self.configuration, "packs": {}})
        self.assertFalse((self.directory / "infra-world-policy.zip").exists())
        self.assertEqual(manual.read_bytes(), b"unmanaged")
        self.assertEqual(chunk.read_bytes(), b"world data")

    def test_unowned_or_modified_managed_names_are_not_replaced(self):
        self.directory.mkdir(parents=True)
        target = self.directory / "infra-world-policy.zip"
        target.write_bytes(self.source.read_bytes())
        with self.assertRaisesRegex(ValueError, "unowned or modified"):
            datapacks.install(self.configuration)
        self.assertFalse((self.directory / datapacks.LEDGER).exists())
        target.unlink()
        datapacks.install(self.configuration)
        target.write_bytes(b"edited by operator")
        with self.assertRaisesRegex(ValueError, "unowned or modified"):
            datapacks.install(self.configuration)
        self.assertEqual(target.read_bytes(), b"edited by operator")

    def test_official_selection_removes_all_four_dropped_packs(self):
        # Synthetic prior archives exercise the deployed ledger without retaining
        # any retired third-party bytes in the repository or test closure.
        retained = {"player-head-drops", "more-mob-heads", "double-shulker-shells", "world-policy"}
        dropped = {"coordinates-hud", "silence-mobs", "durability-ping", "armor-statues"}
        added = {"confetti-creepers", "mini-blocks", "custom-nether-portals", "afk-display"}
        old = {key: str(self.source) for key in retained | dropped}
        datapacks.install({**self.configuration, "packs": old})
        retained_times = {key: (self.directory / f"infra-{key}.zip").stat().st_mtime_ns for key in retained}
        manual = self.directory / "friends.zip"
        manual.write_bytes(b"unmanaged")
        world = self.directory.parent / "level.dat"
        world.write_bytes(b"existing world")
        new = {key: str(self.source) for key in retained | added}
        for _ in range(2):
            datapacks.install({**self.configuration, "packs": new})
            self.assertEqual({p.name for p in self.directory.glob("infra-*.zip")},
                             {f"infra-{key}.zip" for key in new})
            self.assertEqual(json.loads((self.directory / datapacks.LEDGER).read_text()),
                             {f"infra-{key}.zip": [datapacks.digest(self.source)] for key in new})
            self.assertEqual(manual.read_bytes(), b"unmanaged")
            self.assertEqual(world.read_bytes(), b"existing world")
            for key, original in retained_times.items():
                self.assertEqual((self.directory / f"infra-{key}.zip").stat().st_mtime_ns, original)

    def test_interrupted_first_install_and_upgrade_can_resume(self):
        write = datapacks.atomic_write
        def fail_archive(directory, name, content):
            if name.endswith(".zip"):
                raise OSError("interrupted archive publication")
            write(directory, name, content)
        for value in ("50", "75"):
            self.make_pack(self.source, value)
            with patch.object(datapacks, "atomic_write", side_effect=fail_archive):
                with self.assertRaisesRegex(OSError, "interrupted"):
                    datapacks.install(self.configuration)
            datapacks.install(self.configuration)
            self.assertEqual((self.directory / "infra-world-policy.zip").read_bytes(), self.source.read_bytes())

    def test_interrupted_removal_can_resume(self):
        datapacks.install(self.configuration)
        write = datapacks.atomic_write
        calls = 0
        def fail_final_ledger(directory, name, content):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("interrupted ledger publication")
            write(directory, name, content)
        empty = {**self.configuration, "packs": {}}
        with patch.object(datapacks, "atomic_write", side_effect=fail_final_ledger):
            with self.assertRaises(OSError):
                datapacks.install(empty)
        datapacks.install(empty)
        self.assertEqual(json.loads((self.directory / datapacks.LEDGER).read_text()), {})

    def test_rejects_symlinked_world_archive_and_ledger(self):
        outside = self.root / "outside"
        outside.mkdir()
        world = self.directory.parent
        world.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            datapacks.install(self.configuration)
        self.assertEqual(list(outside.iterdir()), [])
        world.unlink()
        self.directory.mkdir(parents=True)
        for filename in ("infra-world-policy.zip", datapacks.LEDGER):
            target = self.directory / filename
            target.symlink_to(self.root / "missing")
            with self.assertRaisesRegex(ValueError, "symlink|unsafe"):
                datapacks.install(self.configuration)
            target.unlink()

    def test_rejects_unsupported_pack_and_path_traversal_before_writes(self):
        self.make_pack(self.source, metadata={"min_format": 107, "max_format": 107})
        with self.assertRaisesRegex(ValueError, "does not support"):
            datapacks.install(self.configuration)
        self.assertFalse(self.directory.exists())
        with self.assertRaisesRegex(ValueError, "invalid managed"):
            datapacks.install({**self.configuration, "packs": {"../escape": str(self.source)}})
        self.assertFalse(self.directory.exists())


if __name__ == "__main__":
    unittest.main()
