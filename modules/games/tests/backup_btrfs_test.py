"""Real Btrfs snapshots, private namespace, Restic and SQLite/WAL restore in a VM.

Only Minecraft's command replies/readiness are simulated. The workload unit,
filesystem operations, namespace, repository, restore and SQLite recovery run
for real. The database connection remains open so committed data lives in WAL.
"""

import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]).parent))
spec = importlib.util.spec_from_file_location("runtime", sys.argv[1])
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
source = Path("/srv")
world = source / "games/minecraft/survival/world"
plugins = source / "games/minecraft/survival/plugins/HuskHomes"
for directory in (world / "region", plugins, source / "games/.state"):
    directory.mkdir(parents=True)
region = world / "region/r.0.0.mca"
region.write_bytes(b"saved-world-region-before-snapshot")
database = plugins / "HuskHomesData.db"
connection = sqlite3.connect(database)
assert connection.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
connection.execute("PRAGMA wal_autocheckpoint=0")
connection.execute("CREATE TABLE homes (name TEXT)")
connection.execute("INSERT INTO homes VALUES ('before-snapshot')")
connection.commit()
assert Path(str(database) + "-wal").stat().st_size > 0
password = Path("/tmp/fixture-restic-password")
password.write_text("disposable-test-only")
cfg = {
    "servers": {
        "survival": {
            "id": "survival",
            "game": "minecraft-paper",
            "wakeOnJoin": False,
            "unit": "fixture-paper.service",
            "available": True,
            "backup": True,
            "serverPort": 25567,
            "worldPaths": [str(world), str(plugins)],
            "console": {"port": 25575},
        }
    },
    "proxy": {},
    "stateDir": "/srv/games/.state",
    "runDir": "/run/games-fixture",
    "backup": {
        "enabled": True,
        "repository": "/tmp/restic-fixture",
        "passwordFile": str(password),
        "source": "fixture",
        "btrfsSource": "/srv",
        "snapshotDir": "/srv/.games-backup-snapshots",
    },
    "commands": {
        name: shutil.which(name)
        for name in ("systemctl", "restic", "btrfs", "mount", "unshare")
    },
}
cfg["commands"].update(python=sys.executable, onlineRestic=sys.argv[2])
runtime.run(cfg, "restic", "-r", cfg["backup"]["repository"], "-p", password, "init")
runtime.atomic_json(Path(cfg["stateDir"]) / "survival.json", {"fingerprint": "fixture"})
runtime.record_stop(cfg, "survival", False, new=True)
commands = []
enabled = True


def rcon(_item, command):
    global enabled
    commands.append(command)
    if command == "save-off":
        enabled = False
        return "Saving is now turned off"
    if command == "save-all flush":
        with region.open("rb") as stream:
            os.fsync(stream.fileno())
        return "Saved the game"
    if command == "save-on":
        enabled = True
        # Change both live inputs after capture, before restic reads. A backup
        # that accidentally reads the live tree will fail the restore checks.
        region.write_bytes(b"live-world-region-after-snapshot")
        connection.execute("INSERT INTO homes VALUES ('after-snapshot')")
        connection.commit()
        return "Saving is now turned on"
    raise AssertionError(command)


def metric():
    return json.loads((Path(cfg["stateDir"]) / "survival-backup.json").read_text())


def recovered():
    assert enabled, commands
    assert not runtime.online_recovery_path(cfg, "survival").exists()
    assert not runtime.online_snapshot_path(cfg, "survival").exists()


original_run = runtime.run
before = runtime.unit_state(cfg, cfg["servers"]["survival"])


def checked_run(configuration, tool, *arguments, **kwargs):
    if tool == "unshare":
        assert enabled, "restic started while saves were disabled"
        assert runtime.online_snapshot_path(cfg, "survival").exists()
    if tool == "systemctl" and arguments[0] in ("stop", "restart", "start"):
        raise AssertionError("healthy online backup must not interrupt players")
    return original_run(configuration, tool, *arguments, **kwargs)


with (
    patch.object(runtime, "validate_repository"),
    patch.object(runtime, "passive_listening", return_value=True),
    patch.object(runtime, "rcon", side_effect=rcon),
    patch.object(runtime, "run", side_effect=checked_run),
):
    runtime.backup_run(cfg, "survival")
    assert commands == ["save-off", "save-all flush", "save-on"]
    recovered()
    assert not metric()["failed"]
    assert (
        runtime.unit_state(cfg, cfg["servers"]["survival"])["InvocationID"]
        == before["InvocationID"]
    )
    original_run(
        cfg,
        "restic",
        "-r",
        cfg["backup"]["repository"],
        "-p",
        password,
        "restore",
        "latest",
        "--target",
        "/tmp/restored",
    )
    restored = Path("/tmp/restored")
    assert (
        restored / region.relative_to("/")
    ).read_bytes() == b"saved-world-region-before-snapshot"
    restored_database = restored / database.relative_to("/")
    assert Path(str(restored_database) + "-wal").exists()
    with sqlite3.connect(restored_database) as saved:
        assert saved.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert saved.execute("SELECT name FROM homes").fetchall() == [
            ("before-snapshot",)
        ]
    assert region.read_bytes() == b"live-world-region-after-snapshot", (
        "namespace changed the real game tree"
    )
    print(
        "PASS: real Btrfs/Restic restore of world region and SQLite/WAL, original paths, save-on before upload, no workload restart",
        flush=True,
    )

    # Flush failure and snapshot failure must each resume saving and leave no
    # view or recovery marker. A failed restic must do the same after capture.
    for phase in ("save-off", "save-all flush", "snapshot", "restic"):
        commands.clear()

        def failing_rcon(item, command):
            reply = rcon(item, command)
            if command == phase:
                raise ConnectionError("injected lost response")
            return reply

        def failing_run(configuration, tool, *arguments, **kwargs):
            if (
                phase == "snapshot"
                and tool == "btrfs"
                and arguments[:2] == ("subvolume", "snapshot")
            ) or (phase == "restic" and tool == "unshare"):
                raise subprocess.CalledProcessError(1, tool)
            return checked_run(configuration, tool, *arguments, **kwargs)

        with (
            patch.object(runtime, "rcon", side_effect=failing_rcon),
            patch.object(runtime, "run", side_effect=failing_run),
        ):
            try:
                runtime.backup_run(cfg, "survival")
            except (OSError, subprocess.SubprocessError):
                pass
            else:
                raise AssertionError("injected failure did not fail the backup")
        assert "save-on" in commands
        recovered()
        assert metric()["failed"]
    print(
        "PASS: lost save-off response, flush, snapshot and restic failures all restored save-on and cleaned snapshots",
        flush=True,
    )

    # ExecStopPost/boot recovery: simulate a process dying after capture.
    commands.clear()
    enabled = False
    runtime.atomic_json(
        runtime.online_recovery_path(cfg, "survival"),
        {"paused": True, "invocation": before["InvocationID"]},
    )
    original_run(
        cfg,
        "btrfs",
        "subvolume",
        "snapshot",
        "-r",
        "/srv",
        runtime.online_snapshot_path(cfg, "survival"),
    )
    runtime.recover_all(cfg)
    recovered()
    assert commands == ["save-on"]
    print(
        "PASS: interrupted-run recovery restored save-on and removed the actual Btrfs snapshot",
        flush=True,
    )

connection.close()
