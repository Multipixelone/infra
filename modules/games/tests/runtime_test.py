"""Behavior checks for the fixed-inventory privilege and backup boundaries."""

import importlib.util
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("games_runtime", sys.argv.pop(1))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.world = self.directory / "world"
        self.world.mkdir()
        self.item = {
            "id": "survival",
            "unit": "minecraft-server-survival.service",
            "game": "minecraft-paper",
            "available": True,
            "backup": True,
            "container": None,
            "wakeOnJoin": True,
            "serverPort": 25567,
            "worldPaths": [str(self.world)],
            "fingerprint": "old",
            "console": {"method": "rcon"},
        }
        self.cfg = {
            "servers": {"survival": self.item},
            "proxy": {},
            "stateDir": str(self.directory / "state"),
            "runDir": str(self.directory / "run"),
            "backup": {
                "enabled": True,
                "repository": str(self.directory / "repo"),
                "source": "nas:/export",
                "passwordFile": "fixture",
            },
        }
        runtime.atomic_json(
            runtime.stop_result_path(self.cfg, "survival"), {"graceful": True}
        )
        self.root = patch.object(runtime, "root")
        self.root.start()
        self.addCleanup(self.root.stop)

    def test_identifiers_cannot_select_arbitrary_units_or_paths(self):
        for identifier in ("../../etc", "survival.service", "--all", "survival;sh"):
            with self.assertRaises(ValueError):
                runtime.server(self.cfg, identifier)

    def test_root_configuration_rejects_container_planted_directory_symlink(self):
        escape = self.directory / "outside"
        escape.mkdir()
        (self.world / "tModLoader").symlink_to(escape, target_is_directory=True)
        with self.assertRaises(ValueError):
            runtime.safe_directory(self.world / "tModLoader/Mods")
        self.assertFalse((escape / "Mods").exists())

    def test_backup_rejects_symlinked_world_root_before_running_restic(self):
        escape = self.directory / "outside"
        escape.mkdir()
        (self.world / "tModLoader").symlink_to(escape, target_is_directory=True)
        self.item["worldPaths"] = [str(self.world / "tModLoader/Worlds")]
        with (
            patch.object(runtime, "validate_repository"),
            patch.object(runtime, "run") as run,
            self.assertRaises(ValueError),
        ):
            runtime.snapshot(self.cfg, "survival")
        run.assert_not_called()

    def test_no_argument_status_and_prune_dispatch(self):
        path = self.directory / "inventory.json"
        path.write_text(json.dumps(self.cfg))
        with patch.object(
            runtime, "status", return_value={"state": "sleeping"}
        ) as status:
            runtime.main(["--inventory", str(path), "status"])
            status.assert_called_once_with(self.cfg, "survival")
        with patch.object(runtime, "prune") as prune:
            runtime.main(["--inventory", str(path), "prune"])
            prune.assert_called_once_with(self.cfg)

    def test_container_logs_use_valid_fixed_match_groups(self):
        self.item["container"] = "games-survival"
        self.cfg["commands"] = {"journalctl": "/fixture/journalctl"}
        path = self.directory / "inventory.json"
        path.write_text(json.dumps(self.cfg))
        with patch.object(runtime.os, "execv") as execute:
            runtime.main(["--inventory", str(path), "logs", "survival", "--follow"])
        executable, argv = execute.call_args.args
        self.assertEqual(executable, "/fixture/journalctl")
        self.assertEqual(argv[-1], "--follow")
        # Every OR has real positional terms on both sides; -u options alone
        # cannot precede +. Matches stay confined to this registered game and
        # its fixed backup unit/container, including root manager records.
        terms = argv[4:-1]
        groups = [[]]
        for term in terms:
            if term == "+":
                self.assertTrue(groups[-1])
                groups.append([])
            else:
                self.assertIn("=", term)
                groups[-1].append(term)
        self.assertTrue(groups[-1])
        self.assertEqual(groups[-1], ["CONTAINER_NAME=games-survival"])
        for group in groups[:-1]:
            identity = next(term for term in group if "UNIT=" in term)
            self.assertIn(
                identity.split("=", 1)[1],
                {
                    "minecraft-server-survival.service",
                    "restic-backups-games-survival.service",
                },
            )

    def test_first_empty_world_and_unchanged_version_do_not_need_backup(self):
        with patch.object(runtime, "snapshot") as snapshot:
            runtime.prechange(self.cfg, "survival")
            runtime.prechange(self.cfg, "survival")
            snapshot.assert_not_called()
        self.assertEqual(
            json.loads((Path(self.cfg["stateDir"]) / "survival.json").read_text())[
                "fingerprint"
            ],
            "old",
        )

    def test_upgrade_snapshots_old_version_before_recording_new_version(self):
        runtime.prechange(self.cfg, "survival")
        (self.world / "level.dat").write_text("irreplaceable")
        self.item["fingerprint"] = "new"

        def snapshot(_cfg, _id):
            self.assertEqual(
                json.loads((Path(self.cfg["stateDir"]) / "survival.json").read_text())[
                    "fingerprint"
                ],
                "old",
            )

        with patch.object(runtime, "snapshot", side_effect=snapshot) as operation:
            runtime.prechange(self.cfg, "survival")
            operation.assert_called_once()
        self.assertEqual(
            json.loads((Path(self.cfg["stateDir"]) / "survival.json").read_text())[
                "fingerprint"
            ],
            "new",
        )

    def test_failed_prechange_snapshot_preserves_old_fingerprint(self):
        runtime.prechange(self.cfg, "survival")
        (self.world / "level.dat").touch()
        self.item["fingerprint"] = "new"
        with (
            patch.object(runtime, "snapshot", side_effect=RuntimeError("offline")),
            self.assertRaises(RuntimeError),
        ):
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(
            json.loads((Path(self.cfg["stateDir"]) / "survival.json").read_text())[
                "fingerprint"
            ],
            "old",
        )

    def test_version_change_after_unclean_shutdown_cannot_snapshot_world(self):
        runtime.prechange(self.cfg, "survival")
        (self.world / "level.dat").touch()
        self.item["fingerprint"] = "new"
        runtime.atomic_json(
            runtime.stop_result_path(self.cfg, "survival"), {"graceful": False}
        )
        with (
            patch.object(runtime, "snapshot") as snapshot,
            self.assertRaises(RuntimeError),
        ):
            runtime.prechange(self.cfg, "survival")
        snapshot.assert_not_called()

    def test_existing_world_without_baseline_requires_snapshot(self):
        (self.world / "level.dat").touch()
        with (
            patch.object(runtime, "snapshot", side_effect=RuntimeError("disabled")),
            self.assertRaises(RuntimeError),
        ):
            runtime.prechange(self.cfg, "survival")
        self.assertFalse((Path(self.cfg["stateDir"]) / "survival.json").exists())

    def test_wrong_mount_is_rejected_before_restic(self):
        (self.directory / "repo").mkdir()
        (self.directory / "repo/config").touch()
        with patch.object(runtime, "run", return_value="/dev/sda1\n") as run:
            with self.assertRaises(RuntimeError):
                runtime.validate_repository(self.cfg)
            self.assertEqual(run.call_count, 1)

    def backup_scenario(self, active, running, result="success", failed=False):
        before = {
            "ActiveState": "active" if active else "inactive",
            "Result": "success",
        }
        after = {
            "ActiveState": "inactive" if result == "success" else "failed",
            "Result": result,
        }
        states = [before, after] if active else [before]
        with (
            patch.object(runtime, "validate_repository"),
            patch.object(runtime, "unit_state", side_effect=states),
            patch.object(runtime, "listening", return_value=running),
            patch.object(runtime, "run") as run,
            patch.object(
                runtime,
                "snapshot",
                side_effect=RuntimeError("failed") if failed else None,
            ) as snapshot,
        ):
            if failed or result != "success":
                with self.assertRaises(RuntimeError):
                    runtime.backup_run(self.cfg, "survival")
            else:
                runtime.backup_run(self.cfg, "survival")
            calls = [call.args[2:] for call in run.call_args_list]
            self.assertEqual(("start", self.item["unit"]) in calls, active)
            self.assertEqual(("stop", self.item["unit"]) in calls, active)
            self.assertEqual(
                (Path(self.cfg["runDir"]) / "survival/wake-once").exists(),
                active and running,
            )
            if result != "success":
                snapshot.assert_not_called()

    def test_stopped_server_stays_stopped(self):
        self.backup_scenario(False, False)

    def test_previously_failed_unit_cannot_be_snapshotted(self):
        with (
            patch.object(runtime, "validate_repository"),
            patch.object(
                runtime,
                "unit_state",
                return_value={"ActiveState": "failed", "Result": "oom-kill"},
            ),
            patch.object(runtime, "snapshot") as snapshot,
            self.assertRaises(RuntimeError),
        ):
            runtime.backup_run(self.cfg, "survival")
        snapshot.assert_not_called()

    def test_inactive_unit_requires_persistent_clean_shutdown_proof(self):
        runtime.stop_result_path(self.cfg, "survival").unlink()
        with (
            patch.object(runtime, "validate_repository"),
            patch.object(
                runtime,
                "unit_state",
                return_value={"ActiveState": "inactive", "Result": "success"},
            ),
            patch.object(runtime, "snapshot") as snapshot,
            self.assertRaises(RuntimeError),
        ):
            runtime.backup_run(self.cfg, "survival")
        snapshot.assert_not_called()

    def test_sleeping_server_returns_to_sleep(self):
        self.backup_scenario(True, False)

    def test_running_server_is_woken_after_snapshot(self):
        self.backup_scenario(True, True)

    def test_failed_backup_recovers_running_server(self):
        self.backup_scenario(True, True, failed=True)

    def test_recovery_replaces_wake_marker_without_following_symlink(self):
        runtime.atomic_json(
            runtime.recovery_path(self.cfg, "survival"),
            {"active": True, "running": True},
        )
        outside = self.directory / "outside-file"
        outside.write_text("preserve")
        marker = Path(self.cfg["runDir"]) / "survival/wake-once"
        marker.symlink_to(outside)
        with patch.object(runtime, "run"):
            runtime.recover(self.cfg, "survival")
        self.assertFalse(marker.is_symlink())
        self.assertEqual(outside.read_text(), "preserve")

    def test_forced_stop_refuses_snapshot_and_recovers(self):
        self.backup_scenario(True, True, result="timeout")

    def test_status_poll_does_not_start_server(self):
        with (
            patch.object(
                runtime,
                "unit_state",
                return_value={"ActiveState": "active", "MainPID": "0"},
            ),
            patch.object(runtime, "listening", return_value=False),
            patch.object(runtime, "run") as run,
        ):
            result = runtime.status(self.cfg, "survival")
            self.assertEqual(result["state"], "sleeping")
            self.assertEqual(result["playersOnline"], 0)
            run.assert_not_called()

    def test_paper_stop_finds_jvm_spawned_by_non_leader_thread(self):
        marker = self.directory / "paper-exit.json"
        marker.write_text("true\n")
        self.item["childExitFile"] = str(marker)
        leader, worker = self.directory / "leader", self.directory / "worker"
        leader.write_text("")
        worker.write_text("123456789 ")
        with patch.object(Path, "glob", return_value=[leader, worker]):
            self.assertEqual(runtime.process_children("100"), ["123456789"])
        self.item["console"]["port"] = 25575
        with (
            patch.object(runtime, "process_children", return_value=["123456789"]),
            patch.object(runtime, "listening", return_value=True),
            patch.object(
                runtime, "rcon", side_effect=["Saved the game", "Stopping server"]
            ) as rcon,
        ):
            runtime.paper_stop(self.cfg, "survival", "100")
        self.assertEqual(
            [call.args[1] for call in rcon.call_args_list], ["save-all flush", "stop"]
        )

    def test_sleeping_paper_after_forced_idle_kill_cannot_create_save_proof(self):
        marker = self.directory / "paper-exit.json"
        self.item["childExitFile"] = str(marker)
        marker.write_text("false\n")
        with (
            patch.object(runtime, "process_children", return_value=[]),
            patch.object(runtime.time, "monotonic", side_effect=[0, 4]),
            self.assertRaises(RuntimeError),
        ):
            runtime.paper_stop(self.cfg, "survival", "100")
        self.assertFalse(
            json.loads(runtime.stop_result_path(self.cfg, "survival").read_text())[
                "graceful"
            ]
        )

    def test_shutdown_waits_for_tokio_to_publish_exit_after_reaping(self):
        with (
            patch.object(runtime, "paper_exit_clean", side_effect=[False, True]),
            patch.object(runtime.time, "sleep") as sleep,
        ):
            runtime.wait_for_paper_exit(self.item)
        sleep.assert_called_once_with(0.05)

    def test_clean_sleeping_paper_preserves_verified_proof(self):
        marker = self.directory / "paper-exit.json"
        self.item["childExitFile"] = str(marker)
        marker.write_text("true\n")
        with patch.object(runtime, "process_children", return_value=[]):
            runtime.paper_stop(self.cfg, "survival", "100")
        runtime.paper_result(self.cfg, "survival")
        self.assertTrue(
            json.loads(runtime.stop_result_path(self.cfg, "survival").read_text())[
                "graceful"
            ]
        )

    def test_post_stop_new_child_or_failed_exit_invalidates_old_proof(self):
        marker = self.directory / "paper-exit.json"
        self.item["childExitFile"] = str(marker)
        marker.write_text("false\n")
        runtime.paper_result(self.cfg, "survival")
        self.assertFalse(
            json.loads(runtime.stop_result_path(self.cfg, "survival").read_text())[
                "graceful"
            ]
        )

    def test_child_exit_flag_must_be_plain_boolean_regular_file(self):
        marker = self.directory / "paper-exit.json"
        self.item["childExitFile"] = str(marker)
        for value in ('{"graceful":true}', '"true"', "true" * 100, "invalid"):
            marker.write_text(value)
            self.assertFalse(runtime.paper_exit_clean(self.item))
        marker.unlink()
        os.mkfifo(marker)
        self.assertFalse(runtime.paper_exit_clean(self.item))

    def test_console_cannot_inject_extra_arguments_or_newlines(self):
        path = self.directory / "inventory.json"
        path.write_text(json.dumps(self.cfg))
        for command in ("stop\nsave", "\0", "", "x" * 1025):
            with self.assertRaises(ValueError):
                runtime.main(
                    ["--inventory", str(path), "console-root", "survival", command]
                )

    def test_container_console_uses_literal_tmux_input(self):
        self.item.update(
            container="games-terraria", console={"method": "container-inject"}
        )
        with patch.object(runtime, "run") as run:
            runtime.console_root(self.cfg, "survival", "say $(touch /escape)")
            self.assertEqual(
                run.call_args_list[0].args[2:],
                (
                    "exec",
                    "--",
                    "games-terraria",
                    "tmux",
                    "send-keys",
                    "-l",
                    "--",
                    "say $(touch /escape)",
                ),
            )

    def container_fixture(self):
        self.item.update(
            container="games-terraria",
            console={"method": "container-inject"},
            logDir=str(self.directory / "logs"),
            worldFiles=[str(self.world / "Finn.wld"), str(self.world / "Finn.twld")],
        )
        Path(self.item["logDir"]).mkdir()
        (Path(self.item["logDir"]) / "server.log").write_text("Startup complete\n")
        for path in self.item["worldFiles"]:
            Path(path).write_text("old saved world")
            os.utime(path, ns=(1, 1))
        result = runtime.stop_result_path(self.cfg, "survival")
        runtime.atomic_json(result, {"graceful": False})
        return result

    def test_container_exit_zero_without_fresh_save_is_rejected(self):
        result = self.container_fixture()
        with (
            patch.object(runtime, "console_root"),
            patch.object(runtime, "run", side_effect=["0\n", '{"ExitCode":0}']),
            self.assertRaisesRegex(RuntimeError, "fresh, complete"),
        ):
            runtime.container_stop(self.cfg, "survival")
        self.assertFalse(json.loads(result.read_text())["graceful"])

    def test_container_requires_fresh_world_and_modded_saves_then_normal_exit(self):
        result = self.container_fixture()

        def exit_command(*args):
            with (Path(self.item["logDir"]) / "server.log").open("a") as stream:
                stream.write(
                    "Saving world data\nValidating world save\nSaving modded world data\n"
                )
            for path in self.item["worldFiles"]:
                Path(path).write_text("fresh saved world")

        with (
            patch.object(runtime, "console_root", side_effect=exit_command),
            patch.object(
                runtime, "run", side_effect=["0\n", '{"ExitCode":0,"OOMKilled":false}']
            ),
        ):
            runtime.container_stop(self.cfg, "survival")
        self.assertTrue(json.loads(result.read_text())["graceful"])

    def test_entrypoint_exit_zero_does_not_replace_verified_stop(self):
        result = self.container_fixture()
        with patch.object(
            runtime, "run", return_value='{"ExitCode":0,"OOMKilled":false}'
        ):
            runtime.container_result(self.cfg, "survival")
        self.assertFalse(json.loads(result.read_text())["graceful"])

    def test_container_out_of_memory_invalidates_confirmed_save(self):
        result = self.container_fixture()
        runtime.atomic_json(result, {"graceful": True})
        with patch.object(
            runtime, "run", return_value='{"ExitCode":0,"OOMKilled":true}'
        ):
            runtime.container_result(self.cfg, "survival")
        self.assertFalse(json.loads(result.read_text())["graceful"])

    def test_rcon_handles_empty_auth_value_then_auth_response(self):
        password = self.directory / "password"
        password.write_text("fixture-password")
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        self.addCleanup(listener.close)

        def packet(identifier, kind, text):
            body = struct.pack("<ii", identifier, kind) + text.encode() + b"\0\0"
            return struct.pack("<i", len(body)) + body

        def fixture():
            connection, _ = listener.accept()
            with connection:
                n = struct.unpack("<i", runtime.read_exact(connection, 4))[0]
                runtime.read_exact(connection, n)
                connection.sendall(packet(1, 0, "") + packet(1, 2, ""))
                n = struct.unpack("<i", runtime.read_exact(connection, 4))[0]
                runtime.read_exact(connection, n)
                connection.sendall(
                    packet(2, 0, "There are 3 of a max of 20 players online")
                )

        thread = threading.Thread(target=fixture)
        thread.start()
        self.item["console"] = {
            "host": "127.0.0.1",
            "port": listener.getsockname()[1],
            "passwordFile": str(password),
        }
        self.assertIn("There are 3", runtime.rcon(self.item, "list"))
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())

    @unittest.skipUnless(
        os.environ.get("RESTIC_EXE"), "real restic supplied by Nix check"
    )
    def test_real_restic_snapshot_can_restore_world_and_version_metadata(self):
        self.cfg["commands"] = {"restic": os.environ["RESTIC_EXE"]}
        password = self.directory / "restic-password"
        password.write_text("disposable-check-password")
        self.cfg["backup"]["passwordFile"] = str(password)
        runtime.run(
            self.cfg,
            "restic",
            "-r",
            self.cfg["backup"]["repository"],
            "-p",
            password,
            "init",
        )
        runtime.prechange(self.cfg, "survival")
        (self.world / "level.dat").write_bytes(b"world-before-upgrade")
        with patch.object(runtime, "validate_repository"):
            runtime.snapshot(self.cfg, "survival")
        (self.world / "level.dat").write_bytes(b"world-after-upgrade")
        restore = self.directory / "restore"
        runtime.run(
            self.cfg,
            "restic",
            "-r",
            self.cfg["backup"]["repository"],
            "-p",
            password,
            "restore",
            "latest",
            "--target",
            restore,
        )
        restored = restore / str(self.world / "level.dat").lstrip("/")
        self.assertEqual(restored.read_bytes(), b"world-before-upgrade")
        metadata = restore / str(Path(self.cfg["stateDir"]) / "survival.json").lstrip(
            "/"
        )
        self.assertEqual(json.loads(metadata.read_text())["fingerprint"], "old")
        proof = restore / str(runtime.stop_result_path(self.cfg, "survival")).lstrip(
            "/"
        )
        self.assertTrue(json.loads(proof.read_text())["graceful"])


unittest.main()
