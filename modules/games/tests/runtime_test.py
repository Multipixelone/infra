"""Behavior checks for the fixed-inventory privilege and backup boundaries."""

import importlib.util
import json
import os
import socket
import struct
import subprocess
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

    def prepare_secret(self, value, game="terraria-tmodloader", token="@PASSWORD@"):
        source = self.directory / "template"
        source.write_text(f"password={token}\n")
        secret = self.directory / "secret"
        secret.write_text(value)
        destination = self.directory / "rendered" / "serverconfig.txt"
        item = self.item if game != "velocity" else {}
        item.update(
            owner="root",
            configTemplates={
                str(destination): {
                    "source": str(source),
                    "replacements": {token: str(secret)},
                }
            },
        )
        if game == "velocity":
            self.cfg["proxy"] = item
            identifier = "velocity"
        else:
            item["game"] = game
            identifier = "survival"
        with (
            patch.object(runtime.pwd, "getpwnam") as identity,
            patch.object(runtime.os, "chown"),
        ):
            identity.return_value.pw_uid = 0
            identity.return_value.pw_gid = 0
            runtime.prepare(self.cfg, identifier)
        return destination.read_text()

    def test_public_assets_are_readable_and_secret_templates_stay_private(self):
        self.prepare_secret("a" * 16)
        private = self.directory / "rendered/serverconfig.txt"
        self.assertEqual(private.stat().st_mode & 0o777, 0o600)
        source = self.directory / "theme.css"
        source.write_text(":root { --theme-bg: paper; }\n")
        public = self.directory / "web/css/theme.css"
        self.item["configTemplates"][str(public)] = {
            "source": str(source),
            "mode": "0644",
        }
        with (
            patch.object(runtime.pwd, "getpwnam") as identity,
            patch.object(runtime.os, "chown"),
        ):
            identity.return_value.pw_uid = 0
            identity.return_value.pw_gid = 0
            # Repeated preparation replaces assets with the intended mode.
            for _ in range(2):
                runtime.prepare(self.cfg, "survival")
                self.assertEqual(public.read_text(), source.read_text())
                self.assertEqual(public.stat().st_mode & 0o777, 0o644)
                self.assertEqual(private.stat().st_mode & 0o777, 0o600)
            for mode in ("0644", "0777"):
                self.item["configTemplates"][str(private)]["mode"] = mode
                with self.assertRaisesRegex(ValueError, "non-secret templates"):
                    runtime.prepare(self.cfg, "survival")
            self.item["configTemplates"] = {
                str(private): {"secret": str(source), "mode": "0644"},
            }
            with self.assertRaisesRegex(ValueError, "non-secret templates"):
                runtime.prepare(self.cfg, "survival")
        self.assertEqual(private.stat().st_mode & 0o777, 0o600)

    def test_terraria_join_password_accepts_short_phrase_and_boundaries(self):
        for value in ("abcdefgh", "friendtime", "a" * 256, "ABcd_012-", "friendtime\n"):
            with self.subTest(value=value):
                self.assertEqual(
                    self.prepare_secret(value), f"password={value.strip()}\n"
                )

    def test_terraria_join_password_rejects_empty_short_and_malformed_values(self):
        for value in (
            "",
            "\n",
            "abcdefg",
            "a" * 257,
            "friend time",
            "friend\ntime",
            "friendtime!",
        ):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "8–256"):
                self.prepare_secret(value)

    def test_other_secret_replacements_keep_sixteen_character_minimum(self):
        for game, token in (
            ("minecraft-paper", "@RCON@"),
            ("minecraft-paper", "@PASSWORD@"),
            ("velocity", "@FORWARDING@"),
            ("terraria-tmodloader", "@OTHER@"),
        ):
            with self.subTest(game=game, token=token):
                with self.assertRaisesRegex(ValueError, "16–256"):
                    self.prepare_secret("friendtime", game, token)
                self.assertEqual(
                    self.prepare_secret("a" * 16, game, token),
                    f"password={'a' * 16}\n",
                )

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
            status.assert_called_once_with(self.cfg, "survival", query=True)
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

    def test_clean_change_without_backups_publishes_fingerprint_without_nas_access(
        self,
    ):
        for global_enabled, server_enabled in (
            (False, True),
            (True, False),
            (False, False),
        ):
            with self.subTest(
                global_enabled=global_enabled, server_enabled=server_enabled
            ):
                self.cfg["backup"]["enabled"] = global_enabled
                self.item["backup"] = server_enabled
                runtime.prechange(self.cfg, "survival")
                (self.world / "level.dat").touch()
                self.item["fingerprint"] += "-new"
                with (
                    patch.object(runtime, "snapshot") as snapshot,
                    patch.object(runtime, "run") as run,
                    patch("builtins.print") as output,
                ):
                    runtime.prechange(self.cfg, "survival")
                snapshot.assert_not_called()
                run.assert_not_called()
                self.assertIn("no snapshot was taken", output.call_args.args[0])
                self.assertEqual(self.fingerprint(), self.item["fingerprint"])

    def test_disabled_backups_do_not_allow_unacknowledged_unclean_changes(self):
        self.cfg["backup"]["enabled"] = False
        runtime.prechange(self.cfg, "survival")
        (self.world / "level.dat").touch()
        self.item["fingerprint"] = "new"
        runtime.record_stop(self.cfg, "survival", False, new=True)
        with self.assertRaisesRegex(RuntimeError, "no verified clean"):
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(self.fingerprint(), "old")

    def fingerprint(self):
        path = Path(self.cfg["stateDir"]) / "survival.json"
        return json.loads(path.read_text())["fingerprint"]

    def unclean_change(self, *, unchanged=False, baseline=True):
        if baseline:
            runtime.prechange(self.cfg, "survival")
        (self.world / "level.dat").write_text("irreplaceable")
        if not unchanged:
            self.item["fingerprint"] = "new"
        runtime.record_stop(self.cfg, "survival", False, new=True)

    def acknowledge(self):
        with patch.object(
            runtime,
            "unit_state",
            return_value={"ActiveState": "failed", "MainPID": "0"},
        ):
            runtime.acknowledge_unclean(self.cfg, "survival")
        return json.loads(
            runtime.acknowledgement_path(self.cfg, "survival").read_text()
        )

    def audit(self):
        paths = list((Path(self.cfg["stateDir"]) / "unclean").glob("survival-*.json"))
        self.assertEqual(len(paths), 1)
        self.assertEqual(paths[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(paths[0].parent.stat().st_mode & 0o777, 0o700)
        return json.loads(paths[0].read_text())

    def test_disabled_backup_recovery_audits_before_publishing_and_consumes_ack(self):
        self.unclean_change()
        self.cfg["backup"]["enabled"] = False
        accepted = self.acknowledge()
        original_atomic = runtime.atomic_json

        def persist(path, value):
            if Path(path).name == "survival.json":
                self.assertEqual(self.audit()["stopProof"], accepted["stopProof"])
                self.assertFalse(runtime.stop_proof(self.cfg, "survival")["graceful"])
            original_atomic(path, value)

        with (
            patch.object(
                runtime,
                "unit_state",
                return_value={
                    "ActiveState": "activating",
                    "SubState": "start-pre",
                    "MainPID": "0",
                },
            ),
            patch.object(runtime, "snapshot") as snapshot,
            patch.object(runtime, "run") as run,
            patch.object(runtime, "atomic_json", side_effect=persist),
            patch("builtins.print") as output,
        ):
            runtime.prechange(self.cfg, "survival")
        snapshot.assert_not_called()
        run.assert_not_called()
        self.assertIn("acknowledged unclean recovery", output.call_args.args[0])
        self.assertIn("no snapshot was taken", output.call_args.args[0])
        audit = self.audit()
        self.assertEqual(audit["previousFingerprint"], "old")
        self.assertEqual(audit["newFingerprint"], "new")
        self.assertIsInstance(audit["acknowledgedAt"], float)
        self.assertGreaterEqual(audit["appliedAt"], audit["acknowledgedAt"])
        self.assertFalse(audit["snapshotTaken"])
        self.assertIsNone(audit["snapshotId"])
        self.assertEqual(self.fingerprint(), "new")
        self.assertFalse(runtime.acknowledgement_path(self.cfg, "survival").exists())
        self.assertEqual(
            runtime.stop_proof(self.cfg, "survival"), accepted["stopProof"]
        )
        self.item["fingerprint"] = "newer"
        with self.assertRaisesRegex(RuntimeError, "no verified clean"):
            runtime.prechange(self.cfg, "survival")

    def test_server_disabled_backups_also_allow_acknowledged_recovery(self):
        self.unclean_change()
        self.item["backup"] = False
        self.acknowledge()
        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            patch.object(runtime, "snapshot") as snapshot,
            patch.object(runtime, "validate_repository") as repository,
        ):
            runtime.prechange(self.cfg, "survival")
        snapshot.assert_not_called()
        repository.assert_not_called()
        self.assertFalse(self.audit()["snapshotTaken"])

    def test_enabled_recovery_requires_unclean_snapshot_before_publication(self):
        self.unclean_change()
        accepted = self.acknowledge()

        def snapshot(cfg, identifier, *, unclean=False):
            self.assertTrue(unclean)
            self.assertEqual(self.fingerprint(), "old")
            self.assertEqual(runtime.stop_proof(cfg, identifier), accepted["stopProof"])
            self.assertTrue(runtime.acknowledgement_path(cfg, identifier).exists())
            return "unclean-snapshot-id"

        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            patch.object(runtime, "snapshot", side_effect=snapshot) as operation,
        ):
            runtime.prechange(self.cfg, "survival")
        operation.assert_called_once_with(self.cfg, "survival", unclean=True)
        self.assertTrue(self.audit()["snapshotTaken"])
        self.assertEqual(self.audit()["snapshotId"], "unclean-snapshot-id")
        self.assertEqual(self.fingerprint(), "new")
        self.assertFalse(runtime.acknowledgement_path(self.cfg, "survival").exists())

    def test_acknowledgement_for_unchanged_fingerprint_still_takes_snapshot(self):
        self.unclean_change(unchanged=True)
        self.acknowledge()
        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            patch.object(
                runtime, "snapshot", return_value="unchanged-snapshot"
            ) as snapshot,
        ):
            runtime.prechange(self.cfg, "survival")
            runtime.prechange(self.cfg, "survival")
        snapshot.assert_called_once_with(self.cfg, "survival", unclean=True)
        self.assertFalse(runtime.acknowledgement_path(self.cfg, "survival").exists())

    def test_failed_unclean_snapshot_keeps_acknowledgement_and_old_fingerprint(self):
        self.unclean_change()
        accepted = self.acknowledge()
        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            patch.object(runtime, "snapshot", side_effect=RuntimeError("offline")),
            self.assertRaisesRegex(RuntimeError, "offline"),
        ):
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(self.fingerprint(), "old")
        self.assertEqual(
            json.loads(runtime.acknowledgement_path(self.cfg, "survival").read_text()),
            accepted,
        )
        self.assertFalse((Path(self.cfg["stateDir"]) / "unclean").exists())
        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            patch.object(runtime, "snapshot", return_value="retry-snapshot"),
        ):
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(self.fingerprint(), "new")

    def test_enabled_recovery_with_uninitialized_repo_does_not_fall_back(self):
        self.unclean_change()
        self.acknowledge()
        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            self.assertRaisesRegex(RuntimeError, "not initialized"),
        ):
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(self.fingerprint(), "old")
        self.assertTrue(runtime.acknowledgement_path(self.cfg, "survival").exists())

    def test_acknowledgement_audit_failure_blocks_publication(self):
        self.unclean_change()
        self.cfg["backup"]["enabled"] = False
        self.acknowledge()
        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            patch.object(runtime, "atomic_json", side_effect=OSError("disk full")),
            self.assertRaises(OSError),
        ):
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(self.fingerprint(), "old")
        self.assertTrue(runtime.acknowledgement_path(self.cfg, "survival").exists())

    def test_recovery_without_baseline_records_null_previous_fingerprint(self):
        self.unclean_change(baseline=False)
        self.cfg["backup"]["enabled"] = False
        self.acknowledge()
        with patch.object(
            runtime, "unit_state", return_value={"ActiveState": "inactive"}
        ):
            runtime.prechange(self.cfg, "survival")
        self.assertIsNone(self.audit()["previousFingerprint"])

    def test_acknowledgement_requires_root_and_fixed_identifier(self):
        with (
            patch.object(runtime, "root", side_effect=PermissionError("root required")),
            self.assertRaises(PermissionError),
        ):
            runtime.acknowledge_unclean(self.cfg, "survival")
        for identifier in ("../survival", "velocity", "--all"):
            with self.assertRaises(ValueError):
                runtime.acknowledge_unclean(self.cfg, identifier)

    def test_acknowledgement_and_consumption_reject_live_or_stopping_server(self):
        self.unclean_change()
        for state in (
            {"ActiveState": "active", "MainPID": "123"},
            {"ActiveState": "activating", "SubState": "start", "MainPID": "0"},
            {"ActiveState": "deactivating", "MainPID": "0"},
            {"ActiveState": "failed", "MainPID": "123"},
            {"ActiveState": "activating", "SubState": "start-pre", "MainPID": "0"},
        ):
            with (
                patch.object(runtime, "unit_state", return_value=state),
                self.assertRaisesRegex(RuntimeError, "stopped game"),
            ):
                runtime.acknowledge_unclean(self.cfg, "survival")
        self.acknowledge()
        with (
            patch.object(runtime, "unit_state", return_value={"ActiveState": "active"}),
            self.assertRaisesRegex(RuntimeError, "stopped game"),
        ):
            runtime.prechange(self.cfg, "survival")

    def test_production_legacy_unclean_proof_with_removed_container_can_recover(self):
        self.unclean_change()
        self.cfg["backup"]["enabled"] = False
        self.item["container"] = "games-terraria"
        runtime.atomic_json(
            runtime.stop_result_path(self.cfg, "survival"), {"graceful": False}
        )
        inventory = self.directory / "inventory.json"
        inventory.write_text(json.dumps(self.cfg))

        def operation(cfg, tool, *args, **kwargs):
            if tool == "systemctl":
                return "ActiveState=failed\nMainPID=0\n"
            if args[0] == "inspect":
                raise subprocess.CalledProcessError(125, ["podman", "inspect"])
            self.assertEqual(args, ("container", "exists", "games-terraria"))
            raise subprocess.CalledProcessError(1, ["podman", "container", "exists"])

        with patch.object(runtime, "run", side_effect=operation):
            runtime.main(
                ["--inventory", str(inventory), "acknowledge-unclean", "survival"]
            )
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(self.fingerprint(), "new")
        self.assertEqual(self.audit()["stopProof"], {"graceful": False})

    def test_acknowledgement_with_missing_proof_records_unclean_evidence(self):
        self.unclean_change()
        runtime.stop_result_path(self.cfg, "survival").unlink()
        accepted = self.acknowledge()
        self.assertFalse(accepted["stopProof"]["graceful"])
        self.assertEqual(
            accepted["stopProof"], runtime.stop_proof(self.cfg, "survival")
        )

    def test_clean_shutdown_cannot_be_acknowledged_as_unclean(self):
        with (
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
            self.assertRaisesRegex(RuntimeError, "already verified clean"),
        ):
            runtime.acknowledge_unclean(self.cfg, "survival")

    def test_malformed_acknowledgement_cannot_bypass_unchanged_shortcut(self):
        self.unclean_change(unchanged=True)
        for value in ({}, [], {"token": "../../escape"}):
            runtime.atomic_json(
                runtime.acknowledgement_path(self.cfg, "survival"), value
            )
            with self.assertRaisesRegex(RuntimeError, "stale"):
                runtime.prechange(self.cfg, "survival")

    def test_acknowledgement_rejects_running_retained_container(self):
        self.unclean_change()
        self.item["container"] = "games-terraria"
        with (
            patch.object(runtime, "unit_state", return_value={"ActiveState": "failed"}),
            patch.object(
                runtime,
                "container_state",
                return_value={"Running": True, "Status": "running"},
            ),
            self.assertRaisesRegex(RuntimeError, "stopped container"),
        ):
            runtime.acknowledge_unclean(self.cfg, "survival")

    def test_stale_acknowledgement_cannot_authorize_different_change_or_proof(self):
        self.unclean_change()
        self.acknowledge()
        self.item["fingerprint"] = "different"
        with self.assertRaisesRegex(RuntimeError, "stale"):
            runtime.prechange(self.cfg, "survival")
        self.item["fingerprint"] = "new"
        runtime.atomic_json(
            runtime.stop_result_path(self.cfg, "survival"),
            {"graceful": False, "generation": "different"},
        )
        with self.assertRaisesRegex(RuntimeError, "stale"):
            runtime.prechange(self.cfg, "survival")
        self.assertEqual(self.fingerprint(), "old")

    def test_new_run_or_stop_invalidates_pending_acknowledgement(self):
        self.unclean_change()
        accepted = self.acknowledge()
        runtime.record_stop(self.cfg, "survival", False, new=True)
        self.assertNotEqual(
            runtime.stop_proof(self.cfg, "survival"), accepted["stopProof"]
        )
        self.assertFalse(runtime.acknowledgement_path(self.cfg, "survival").exists())
        with self.assertRaisesRegex(RuntimeError, "no verified clean"):
            runtime.prechange(self.cfg, "survival")

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

    def test_no_query_status_never_connects_or_reads_rcon(self):
        with (
            patch.object(
                runtime,
                "unit_state",
                return_value={"ActiveState": "active", "MainPID": "0"},
            ),
            patch.object(runtime, "passive_listening", return_value=False),
            patch.object(runtime, "process_children", return_value=[]),
            patch.object(runtime.socket, "create_connection") as connection,
            patch.object(runtime, "rcon") as rcon,
        ):
            result = runtime.status(self.cfg, "survival", query=False)
        self.assertEqual(result["state"], "sleeping")
        connection.assert_not_called()
        rcon.assert_not_called()

    def test_passive_socket_table_and_no_query_dispatch(self):
        socket_table = "header\n0: 0100007F:63DF 00000000:0000 0A\n"
        with patch.object(Path, "read_text", return_value=socket_table):
            self.assertTrue(runtime.passive_listening(25567))
            self.assertFalse(runtime.passive_listening(25566))
        path = self.directory / "inventory.json"
        path.write_text(json.dumps(self.cfg))
        with patch.object(runtime, "status", return_value={}) as status:
            runtime.main(["--inventory", str(path), "status", "--no-query", "survival"])
        status.assert_called_once_with(self.cfg, "survival", query=False)

    def test_backup_metadata_records_validation_failure(self):
        with (
            patch.object(
                runtime,
                "validate_repository",
                side_effect=RuntimeError("not configured"),
            ),
            self.assertRaises(RuntimeError),
        ):
            runtime.backup_run(self.cfg, "survival")
        metadata = json.loads(
            (Path(self.cfg["stateDir"]) / "survival-backup.json").read_text()
        )
        self.assertTrue(metadata["failed"])

    def test_backup_metadata_records_recovery_failure_without_erasing_snapshot(self):
        path = Path(self.cfg["stateDir"]) / "survival-backup.json"
        runtime.atomic_json(path, {"lastSuccess": 100, "lastSize": 123})
        with (
            patch.object(
                runtime, "backup_run_inner", side_effect=RuntimeError("recovery failed")
            ),
            self.assertRaises(RuntimeError),
        ):
            runtime.backup_run(self.cfg, "survival")
        metadata = json.loads(path.read_text())
        self.assertEqual(metadata["lastSuccess"], 100)
        self.assertEqual(metadata["lastSize"], 123)
        self.assertTrue(metadata["failed"])

    def test_successful_backup_clears_failure_and_records_duration(self):
        with (
            patch.object(runtime, "backup_run_inner"),
            patch.object(runtime.time, "monotonic", side_effect=[100, 112]),
        ):
            runtime.backup_run(self.cfg, "survival")
        metadata = json.loads(
            (Path(self.cfg["stateDir"]) / "survival-backup.json").read_text()
        )
        self.assertFalse(metadata["failed"])
        self.assertEqual(metadata["lastDuration"], 12)

    def test_snapshot_exports_restic_summary_without_logging_raw_output(self):
        output = '{"message_type":"status","current_files":["private-path"]}\n{"message_type":"summary","total_bytes_processed":1234}\n'
        with (
            patch.object(runtime, "validate_repository"),
            patch.object(runtime, "run", return_value=output) as run,
            patch.object(runtime.time, "time", return_value=321),
            patch("builtins.print") as print_output,
        ):
            runtime.snapshot(self.cfg, "survival")
        self.assertIn("--json", run.call_args.args)
        print_output.assert_called_once_with("World snapshot completed", flush=True)
        metadata = json.loads(
            (Path(self.cfg["stateDir"]) / "survival-backup.json").read_text()
        )
        self.assertEqual(metadata, {"lastSuccess": 321, "lastSize": 1234})

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
        with (
            patch.object(runtime, "rcon") as rcon,
            patch.object(runtime, "console_root") as writer,
            patch.object(runtime.os, "execv") as execv,
        ):
            for action, prefix in (
                ("console", ["/fixed/writer"]),
                ("console-root", []),
            ):
                arguments = [
                    ["survival", command]
                    for command in ("stop\nsave", "stop\rsave", "\0", "", "x" * 1025)
                ] + [
                    [],
                    ["survival"],
                    ["survival", "list", "extra"],
                    ["unknown", "list"],
                ]
                for args in arguments:
                    with (
                        self.subTest(action=action, args=args),
                        self.assertRaises(ValueError),
                    ):
                        runtime.main(["--inventory", str(path), action, *prefix, *args])
            rcon.assert_not_called()
            writer.assert_not_called()
            execv.assert_not_called()

    def test_readable_rcon_console_prints_response_without_sudo(self):
        path = self.directory / "inventory.json"
        path.write_text(json.dumps(self.cfg))
        with (
            patch.object(
                runtime, "rcon", return_value="There are 3 players online"
            ) as rcon,
            patch.object(runtime.os, "execv") as execv,
            patch("builtins.print") as output,
        ):
            for command in ("list", "x" * 1024, "say $(touch /escape)"):
                runtime.main(
                    [
                        "--inventory",
                        str(path),
                        "console",
                        "/fixed/writer",
                        "survival",
                        command,
                    ]
                )
                rcon.assert_called_with(self.item, command)
                output.assert_called_with("There are 3 players online")
            execv.assert_not_called()

    def rcon_password_fixture(self):
        password = self.directory / "password"
        password.write_text("fixture-password")
        self.item["console"] = {
            "method": "rcon",
            "host": "127.0.0.1",
            "port": 25575,
            "passwordFile": str(password),
        }
        return password

    def test_unreadable_rcon_secret_has_actionable_error_without_connecting(self):
        password = self.rcon_password_fixture()
        with (
            patch.object(
                Path,
                "read_text",
                side_effect=PermissionError(13, "Permission denied", str(password)),
            ),
            patch.object(runtime.socket, "create_connection") as connect,
            self.assertRaises(PermissionError) as raised,
        ):
            runtime.rcon(self.item, "list")
        message = str(raised.exception)
        self.assertIn(f"cannot read RCON secret '{password}'", message)
        self.assertIn("sudo", message)
        self.assertIn("games-dashboard", message)
        self.assertIn("new login session", message)
        self.assertNotIn("Errno", message)
        self.assertNotIn("fixture-password", message)
        self.assertTrue(raised.exception.__suppress_context__)
        connect.assert_not_called()

    def test_missing_rcon_secret_keeps_file_not_found_error(self):
        password = self.rcon_password_fixture()
        password.unlink()
        with (
            patch.object(runtime.socket, "create_connection") as connect,
            self.assertRaises(FileNotFoundError),
        ):
            runtime.rcon(self.item, "list")
        connect.assert_not_called()

    def test_rcon_authentication_failure_is_not_a_secret_read_error(self):
        self.rcon_password_fixture()
        packet = struct.pack("<ii", -1, 2) + b"\0\0"
        with patch.object(runtime.socket, "create_connection") as connect:
            connection = connect.return_value.__enter__.return_value
            connection.recv.side_effect = [struct.pack("<i", len(packet)), packet]
            with self.assertRaisesRegex(
                PermissionError, "^RCON authentication failed$"
            ):
                runtime.rcon(self.item, "list")
            self.assertEqual(connection.sendall.call_count, 1)

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

        with (
            patch.object(runtime, "console_root", side_effect=self.container_save),
            patch.object(
                runtime,
                "run",
                side_effect=["0\n", '{"Running":false,"ExitCode":0,"OOMKilled":false}'],
            ),
        ):
            runtime.container_stop(self.cfg, "survival")
        self.assertTrue(json.loads(result.read_text())["graceful"])

    def container_save(self, *args):
        with (Path(self.item["logDir"]) / "server.log").open("a") as stream:
            stream.write(
                "Saving world data\nValidating world save\nSaving modded world data\n"
            )
        for path in self.item["worldFiles"]:
            Path(path).write_text("fresh saved world")

    def test_auto_removed_container_before_stop_inspect_fails_closed(self):
        result = self.container_fixture()
        with (
            patch.object(runtime, "console_root", side_effect=self.container_save),
            patch.object(
                runtime,
                "run",
                side_effect=[
                    "0\n",
                    subprocess.CalledProcessError(125, ["podman", "inspect"]),
                    subprocess.CalledProcessError(1, ["podman", "container", "exists"]),
                ],
            ) as operation,
            self.assertRaisesRegex(RuntimeError, "disappeared"),
        ):
            runtime.container_stop(self.cfg, "survival")
        self.assertEqual(
            operation.call_args.args[2:], ("container", "exists", "games-terraria")
        )
        self.assertFalse(json.loads(result.read_text())["graceful"])

    def test_container_result_after_removal_preserves_only_verified_proof(self):
        result = self.container_fixture()
        for verified in (True, False):
            proof = {"graceful": verified, "generation": "retained-proof"}
            runtime.atomic_json(result, proof)
            with patch.object(
                runtime,
                "run",
                side_effect=[
                    subprocess.CalledProcessError(125, ["podman", "inspect"]),
                    subprocess.CalledProcessError(1, ["podman", "container", "exists"]),
                ],
            ):
                runtime.container_result(self.cfg, "survival")
            self.assertEqual(json.loads(result.read_text()), proof)

    def test_verified_retained_stop_survives_result_then_oci_removal(self):
        result = self.container_fixture()
        state = '{"Running":false,"ExitCode":0,"OOMKilled":false}'
        with (
            patch.object(runtime, "console_root", side_effect=self.container_save),
            patch.object(runtime, "run", side_effect=["0\n", state, state]),
        ):
            runtime.container_stop(self.cfg, "survival")
            proof = json.loads(result.read_text())
            runtime.container_result(self.cfg, "survival")
        self.assertTrue(proof["graceful"])
        with patch.object(
            runtime,
            "run",
            side_effect=[
                subprocess.CalledProcessError(125, ["podman", "inspect"]),
                subprocess.CalledProcessError(1, ["podman", "container", "exists"]),
            ],
        ):
            runtime.container_result(self.cfg, "survival")
        self.assertEqual(json.loads(result.read_text()), proof)

    def test_container_result_inspection_errors_are_not_treated_as_absence(self):
        result = self.container_fixture()
        for responses in (
            [subprocess.CalledProcessError(125, ["inspect"]), ""],
            [
                subprocess.CalledProcessError(125, ["inspect"]),
                subprocess.CalledProcessError(125, ["exists"]),
            ],
            [subprocess.TimeoutExpired(["inspect"], 30)],
            ["invalid json"],
            ["[]"],
        ):
            with self.subTest(responses=responses):
                runtime.atomic_json(result, {"graceful": True})
                with patch.object(runtime, "run", side_effect=responses):
                    runtime.container_result(self.cfg, "survival")
                self.assertFalse(json.loads(result.read_text())["graceful"])

    def test_container_stop_rejects_abnormal_or_unknown_exit_even_after_save(self):
        result = self.container_fixture()
        for exit_code, state in (
            ("137\n", {"Running": False, "ExitCode": 0, "OOMKilled": False}),
            ("0\n", {"Running": False, "ExitCode": 137, "OOMKilled": False}),
            ("0\n", {"Running": False, "ExitCode": 0, "OOMKilled": True}),
            ("0\n", {"Running": True, "ExitCode": 0, "OOMKilled": False}),
            ("0\n", {"ExitCode": 0}),
        ):
            with self.subTest(exit_code=exit_code, state=state):
                with (
                    patch.object(
                        runtime, "console_root", side_effect=self.container_save
                    ),
                    patch.object(
                        runtime, "run", side_effect=[exit_code, json.dumps(state)]
                    ),
                    self.assertRaisesRegex(RuntimeError, "exit normally"),
                ):
                    runtime.container_stop(self.cfg, "survival")
                self.assertFalse(json.loads(result.read_text())["graceful"])

    def test_container_stop_requires_ordered_markers_and_each_advancing_file(self):
        self.container_fixture()
        state = '{"Running":false,"ExitCode":0,"OOMKilled":false}'

        def incomplete_save(*args):
            self.container_save()
            Path(self.item["worldFiles"][1]).write_text("")

        with (
            patch.object(runtime, "console_root", side_effect=incomplete_save),
            patch.object(runtime, "run", side_effect=["0\n", state]),
            self.assertRaisesRegex(RuntimeError, "files did not advance"),
        ):
            runtime.container_stop(self.cfg, "survival")

        def reversed_markers(*args):
            with (Path(self.item["logDir"]) / "server.log").open("a") as stream:
                stream.write(
                    "Saving modded world data\nValidating world save\nSaving world data\n"
                )

        with (
            patch.object(runtime, "console_root", side_effect=reversed_markers),
            patch.object(runtime, "run", side_effect=["0\n", state]),
            self.assertRaisesRegex(RuntimeError, "fresh, complete"),
        ):
            runtime.container_stop(self.cfg, "survival")

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
            runtime,
            "run",
            return_value='{"Running":false,"ExitCode":0,"OOMKilled":true}',
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
    def test_real_unclean_snapshot_restores_acknowledgement_proof_and_old_fingerprint(
        self,
    ):
        self.unclean_change()
        accepted = self.acknowledge()
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
        with (
            patch.object(runtime, "validate_repository"),
            patch.object(
                runtime, "unit_state", return_value={"ActiveState": "inactive"}
            ),
        ):
            runtime.prechange(self.cfg, "survival")
        snapshots = json.loads(
            runtime.run(
                self.cfg,
                "restic",
                "-r",
                self.cfg["backup"]["repository"],
                "-p",
                password,
                "snapshots",
                "--json",
            )
        )
        self.assertEqual(
            set(snapshots[0]["tags"]),
            {"games:survival", "games:unclean", "games:unverified"},
        )
        self.assertIn(
            self.audit()["snapshotId"], (snapshots[0]["id"], snapshots[0]["short_id"])
        )
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
        metadata = restore / str(Path(self.cfg["stateDir"]) / "survival.json").lstrip(
            "/"
        )
        self.assertEqual(json.loads(metadata.read_text())["fingerprint"], "old")
        proof = restore / str(runtime.stop_result_path(self.cfg, "survival")).lstrip(
            "/"
        )
        self.assertEqual(json.loads(proof.read_text()), accepted["stopProof"])
        acknowledgement = restore / str(
            runtime.acknowledgement_path(self.cfg, "survival")
        ).lstrip("/")
        self.assertEqual(json.loads(acknowledgement.read_text()), accepted)
        self.assertEqual(self.fingerprint(), "new")
        self.assertFalse(runtime.acknowledgement_path(self.cfg, "survival").exists())

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
