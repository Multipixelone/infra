"""Fixture tests for telemetry without touching any real game or host unit."""

import importlib.util
import json
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("metrics", sys.argv.pop(1))
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
patterns = json.loads(Path(sys.argv.pop(1)).read_text())
fixtures = json.loads(Path(sys.argv.pop(1)).read_text())


def sample(output, name, **labels):
    found = []
    for line in output.splitlines():
        if not line.startswith(name + "{"):
            continue
        head, value = line.rsplit(" ", 1)
        if all(
            f"{key}={json.dumps(str(value))}" in head for key, value in labels.items()
        ):
            found.append(float(value))
    if len(found) != 1:
        raise AssertionError(f"expected one {name} {labels}, found {found}")
    return found[0]


class ExporterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.secret = self.root / "credential"
        self.secret.write_text("do-not-expose-this-secret")
        self.proof = self.root / "paper-exit.json"
        self.state = {}
        self.status = fixtures["sleeping"]
        self.active, self.result = "active", "success"
        self.entries = []
        self.item = {
            "game": "minecraft-paper",
            "enabled": True,
            "available": True,
            "unit": "minecraft-server-survival.service",
            "container": None,
            "wakeOnJoin": True,
            "serverPort": 25567,
            "childExitFile": str(self.proof),
            "secretPaths": [str(self.secret)],
            "capacity": 20,
            "memoryBytes": 6442450944,
            "backupEnabled": False,
        }
        self.inventory = {
            "host": "link",
            "servers": {"survival": self.item},
            "patterns": patterns,
            "cgroupRoot": str(self.root / "cgroup"),
            "procRoot": str(self.root / "proc"),
            "backupStateDir": str(self.root),
            "backupPasswordPath": str(self.secret),
            "commands": {},
        }

    def runner(self, inventory, tool, *args, **kwargs):
        if tool == "journalctl":
            return "\n".join(json.dumps(entry) for entry in self.entries)
        if tool == "systemctl":
            if args[1].startswith("restic-backups-"):
                return "ActiveState=inactive\nResult=success\n"
            if args[-1] == "--value":
                return "inactive\n"
            return f"ActiveState={self.active}\nResult={self.result}\nMainPID=0\nControlGroup=\nInvocationID=invocation\n"
        if tool == "status":
            self.assertEqual(args, ("--no-query", "survival"))
            return json.dumps(self.status)
        raise AssertionError((tool, args))

    def collect(self, query=None):
        with (
            patch.object(metrics, "command", side_effect=self.runner),
            patch.object(
                metrics,
                "minecraft_players",
                side_effect=query
                or AssertionError("must not query a sleeping/stopped game"),
            ) as request,
        ):
            result = metrics.collect(self.inventory, self.state, now=1000)
        self.assertNotIn("do-not-expose-this-secret", result)
        return result, request

    def test_sleeping_never_queries_and_has_zero_players(self):
        output, request = self.collect()
        request.assert_not_called()
        self.assertEqual(sample(output, "games_server_state", state="sleeping"), 1)
        self.assertEqual(sample(output, "games_players_online"), 0)
        self.assertEqual(sample(output, "games_server_failed"), 0)

    def test_explicit_unclean_child_exit_is_failure_not_sleep(self):
        self.proof.write_text("false")
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_server_state", state="stopped"), 1)
        self.assertEqual(sample(output, "games_server_failed"), 1)
        self.assertEqual(sample(output, "games_players_known"), 0)

    def test_clean_proof_is_normal_sleep(self):
        self.proof.write_text("true")
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_server_failed"), 0)

    def test_missing_proof_after_launch_is_unknown(self):
        self.state["servers"] = {"survival": {"launched": True}}
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_metrics_collection_success"), 0)
        self.assertEqual(sample(output, "games_server_failed"), 0)

    def test_clean_stop_is_not_failure(self):
        self.active = "inactive"
        self.status = fixtures["stopped"]
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_server_failed"), 0)
        self.assertEqual(sample(output, "games_server_state", state="stopped"), 1)

    def test_unit_failure_is_reported(self):
        self.active, self.result = "failed", "exit-code"
        self.status = fixtures["stopped"]
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_server_failed"), 1)

    def test_operator_disabled_and_missing_secret_are_not_failures(self):
        for scenario in ("disabled", "missing-secret"):
            with self.subTest(scenario=scenario):
                self.item["enabled"] = scenario != "disabled"
                self.item["available"] = False
                self.status = fixtures[scenario]
                output, request = self.collect()
                request.assert_not_called()
                self.assertEqual(
                    sample(output, "games_server_state", state="disabled"), 1
                )
                self.assertEqual(sample(output, "games_server_failed"), 0)

    def test_runtime_credential_absence_disables_collection(self):
        self.secret.unlink()
        output, _ = self.collect()
        self.assertEqual(
            sample(output, "games_server_disabled", reason="missing-secrets"), 1
        )

    def test_awake_query_uses_actual_paper_port(self):
        self.status = fixtures["running"]
        output, query = self.collect(query=lambda port: 3)
        query.assert_called_once_with(25567)
        self.assertEqual(sample(output, "games_players_online"), 3)
        self.assertEqual(sample(output, "games_player_capacity"), 20)

    def test_awake_query_failure_leaves_players_unknown(self):
        self.status = fixtures["running"]
        output, _ = self.collect(query=OSError("private diagnostic"))
        self.assertEqual(sample(output, "games_players_known"), 0)
        self.assertEqual(sample(output, "games_server_failed"), 0)

    def test_malformed_status_is_collection_failure(self):
        for value in ([{"id": "other", "state": "running"}], [None], None, []):
            with self.subTest(value=value):
                self.status = value
                output, _ = self.collect()
                self.assertEqual(sample(output, "games_metrics_collection_success"), 0)
                self.assertEqual(sample(output, "games_server_failed"), 0)

    def test_backup_disabled_exports_configuration_and_history(self):
        (self.root / "survival-backup.json").write_text(
            json.dumps({"lastSuccess": 500, "lastSize": 123, "failed": True})
        )
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_backup_configured"), 0)
        self.assertEqual(
            sample(output, "games_backup_last_success_timestamp_seconds"), 500
        )
        self.assertEqual(sample(output, "games_backup_last_size_bytes"), 123)

    def test_backup_enable_epoch_survives_poll_and_resets_after_disable(self):
        self.item["backupEnabled"] = True
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_backup_enabled_timestamp_seconds"), 1000)
        self.state["servers"]["survival"]["backupEnabledSince"] = 900
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_backup_enabled_timestamp_seconds"), 900)
        self.item["backupEnabled"] = False
        self.collect()
        self.item["backupEnabled"] = True
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_backup_enabled_timestamp_seconds"), 1000)

    def test_backup_unit_failure_before_wrapper_is_reported(self):
        self.item["backupEnabled"] = True
        original = self.runner

        def runner(inventory, tool, *args, **kwargs):
            if tool == "systemctl" and args[1].startswith("restic-backups-"):
                return "ActiveState=failed\nResult=exit-code\n"
            return original(inventory, tool, *args, **kwargs)

        with patch.object(metrics, "command", side_effect=runner):
            output = metrics.collect(self.inventory, self.state, 1000)
        self.assertEqual(sample(output, "games_backup_failed"), 1)

    def test_journal_failure_retains_counters_and_invalidates_estimate(self):
        self.state["servers"] = {
            "survival": {"events": {"join": 4}, "playersKnown": True}
        }
        original = self.runner

        def runner(inventory, tool, *args, **kwargs):
            if tool == "journalctl":
                raise subprocess.CalledProcessError(1, ["fixture"])
            return original(inventory, tool, *args, **kwargs)

        with patch.object(metrics, "command", side_effect=runner):
            output = metrics.collect(self.inventory, self.state, 1000)
        self.assertEqual(sample(output, "games_player_events_total", event="join"), 4)
        self.assertEqual(sample(output, "games_journal_collection_success"), 0)
        self.assertFalse(self.state["servers"]["survival"]["playersKnown"])

    def test_journal_gap_does_not_recount_old_events(self):
        self.state.update(journalGap=True, journalTimestamp=10)
        self.entries = [
            {
                "__CURSOR": "old",
                "__REALTIME_TIMESTAMP": "9",
                "_SYSTEMD_UNIT": self.item["unit"],
                "MESSAGE": "Finn joined the game",
            }
        ]
        output, _ = self.collect()
        self.assertEqual(sample(output, "games_player_events_total", event="join"), 0)

    def test_cursor_and_atomic_textfile(self):
        self.entries = [
            {
                "__CURSOR": "new",
                "__REALTIME_TIMESTAMP": "100",
                "_SYSTEMD_UNIT": self.item["unit"],
                "MESSAGE": "Finn joined the game",
            }
        ]
        output, _ = self.collect()
        self.assertEqual(self.state["cursor"], "new")
        self.assertEqual(sample(output, "games_player_events_total", event="join"), 1)
        target = self.root / "games.prom"
        metrics.atomic(target, output, 0o644)
        self.assertEqual(target.read_text(), output)
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        self.assertEqual(list(self.root.glob(".games-*")), [])

    def test_missing_container_inspect_never_reports_launcher_as_workload(self):
        self.item.update(
            game="terraria-tmodloader", container="games-terraria", wakeOnJoin=False
        )
        self.status = fixtures["terraria"]
        self.status = [self.status[0] | {"id": "survival"}]
        original = self.runner

        def runner(inventory, tool, *args, **kwargs):
            if tool == "podman":
                raise subprocess.CalledProcessError(1, ["fixture"])
            if tool == "systemctl" and args[-1] != "--value":
                return original(inventory, tool, *args, **kwargs).replace(
                    "ControlGroup=\n", "ControlGroup=/games.slice/launcher\n"
                )
            return original(inventory, tool, *args, **kwargs)

        with patch.object(metrics, "command", side_effect=runner):
            output = metrics.collect(self.inventory, self.state, 1000)
        self.assertEqual(sample(output, "games_metrics_collection_success"), 1)
        self.assertEqual(
            sample(output, "games_resource_collection_success", scope="server"), 0
        )
        self.assertNotIn("games_memory_current_bytes{", output)

    def test_container_sibling_scope_is_included_once_in_server_totals(self):
        self.item.update(
            game="terraria-tmodloader", container="games-terraria", wakeOnJoin=False
        )
        self.status = [fixtures["terraria"][0] | {"id": "survival"}]
        cgroups = Path(self.inventory["cgroupRoot"])
        for name, memory, cpu in (
            ("launcher", 1024, 2500000),
            ("libpod", 4096, 5000000),
        ):
            path = cgroups / "games.slice" / name
            path.mkdir(parents=True)
            (path / "cpu.stat").write_text(f"usage_usec {cpu}\n")
            (path / "memory.current").write_text(str(memory))
            (path / "io.stat").write_text("8:0 rbytes=10 wbytes=20\n")
        proc = Path(self.inventory["procRoot"]) / "7"
        proc.mkdir(parents=True)
        (proc / "cgroup").write_text("0::/games.slice/libpod\n")
        original = self.runner

        def runner(inventory, tool, *args, **kwargs):
            if tool == "podman":
                return json.dumps(
                    [
                        {
                            "Id": "container",
                            "State": {"Pid": 7, "StartedAt": "2026-10-08T00:00:00Z"},
                        }
                    ]
                )
            if tool == "systemctl" and not args[1].startswith("restic-backups-"):
                return original(inventory, tool, *args, **kwargs).replace(
                    "ControlGroup=\n", "ControlGroup=/games.slice/launcher\n"
                )
            return original(inventory, tool, *args, **kwargs)

        with patch.object(metrics, "command", side_effect=runner):
            output = metrics.collect(self.inventory, self.state, 1000)
        self.assertEqual(
            sample(output, "games_memory_current_bytes", scope="server"), 5120
        )
        self.assertEqual(
            sample(output, "games_memory_current_bytes", scope="container"), 4096
        )
        self.assertEqual(sample(output, "games_cpu_seconds_total", scope="server"), 7.5)
        self.assertEqual(
            sample(output, "games_io_read_bytes_total", scope="server"), 20
        )

    def test_velocity_queries_only_proxy_port_and_has_no_enforced_capacity(self):
        self.inventory["servers"] = {
            "velocity": self.item
            | {
                "game": "minecraft-velocity",
                "unit": "minecraft-server-velocity.service",
                "wakeOnJoin": False,
                "serverPort": 25565,
            }
        }
        self.inventory["servers"]["velocity"].pop("capacity")
        output, query = self.collect(query=lambda port: 4)
        query.assert_called_once_with(25565)
        self.assertEqual(sample(output, "games_server_ready"), 1)
        self.assertEqual(sample(output, "games_players_online"), 4)
        self.assertNotIn("games_player_capacity{", output)


class SourceTests(unittest.TestCase):
    def test_child_proof_rejects_symlinks_and_oversized_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "proof"
            path.write_text("true")
            self.assertTrue(metrics.exit_proof(path))
            link = Path(directory) / "link"
            link.symlink_to(path)
            self.assertIsNone(metrics.exit_proof(link))
            path.write_text(" " * 129 + "false")
            self.assertIsNone(metrics.exit_proof(path))

    def test_cgroup_units_and_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "games.slice"
            path.mkdir()
            (path / "cpu.stat").write_text("usage_usec 2500000\n")
            (path / "memory.current").write_text("1024")
            (path / "io.stat").write_text(
                "8:0 rbytes=100 wbytes=200 rios=1\n8:1 rbytes=40 wbytes=60\n"
            )
            self.assertEqual(
                metrics.cgroup(directory, "/games.slice"),
                {"cpu": 2.5, "memory": 1024, "read": 140, "write": 260},
            )
            self.assertEqual(
                set(
                    metrics.distinct_cgroups(
                        [
                            "/games.slice/unit",
                            "/games.slice/unit/child",
                            "/games.slice/libpod",
                        ]
                    )
                ),
                {"/games.slice/unit", "/games.slice/libpod"},
            )
            with self.assertRaises(ValueError):
                metrics.cgroup(directory, "/../outside")

    def test_terraria_membership_and_container_identity(self):
        item = {
            "game": "terraria-tmodloader",
            "unit": "podman-games-terraria.service",
            "container": "games-terraria",
        }
        state = {}

        def entry(message):
            return {
                "CONTAINER_NAME": "games-terraria",
                "CONTAINER_ID_FULL": "container1",
                "_SYSTEMD_UNIT": "libpod.scope",
                "MESSAGE": message,
            }

        metrics.process_journal(
            item,
            [
                entry("Server started"),
                entry("Finn has joined."),
                entry("Finn has joined."),
            ],
            state,
            patterns,
            "container1",
        )
        self.assertTrue(state["playersKnown"])
        self.assertEqual(len(state["players"]), 1)
        self.assertNotIn("Finn", json.dumps(state))
        metrics.process_journal(
            item, [entry("Finn has left.")], state, patterns, "container1"
        )
        self.assertEqual(state["players"], [])
        metrics.process_journal(item, [], state, patterns, "container2")
        self.assertFalse(state["playersKnown"])

    def test_terraria_timestamp_prefix_is_not_part_of_player_identity(self):
        item = {
            "game": "terraria-tmodloader",
            "unit": "podman-games-terraria.service",
            "container": "games-terraria",
        }
        state = {}
        messages = [
            "[12:00:00] Server started",
            "[12:00:01] Finn has joined.",
            "[12:05:01] Finn has left.",
        ]
        metrics.process_journal(
            item,
            [
                {
                    "CONTAINER_NAME": "games-terraria",
                    "CONTAINER_ID_FULL": "container",
                    "MESSAGE": message,
                }
                for message in messages
            ],
            state,
            patterns,
            "container",
        )
        self.assertTrue(state["playersKnown"])
        self.assertEqual(state["players"], [])
        self.assertEqual(state["events"], {"join": 1, "leave": 1})

    def test_chat_cannot_forge_join_and_sleep_events(self):
        item = {
            "game": "minecraft-paper",
            "unit": "minecraft-server-survival.service",
            "container": None,
        }
        state = {}
        messages = [
            "[12:00:00 INFO]: <Finn> Ada joined the game",
            "[12:00:00 INFO]: <Finn> lazymc::monitor: Server is now sleeping",
            "INFO lazymc::monitor: Server is now online",
            "INFO lazymc::monitor: Server is now sleeping",
        ]
        metrics.process_journal(
            item,
            [
                {"_SYSTEMD_UNIT": item["unit"], "MESSAGE": message}
                for message in messages
            ],
            state,
            patterns,
            "invocation",
        )
        self.assertEqual(state["events"], {"wake": 1, "sleep": 1})

    def test_status_protocol_is_bounded_and_not_a_login(self):
        body = json.dumps({"players": {"online": 7}}).encode()
        reply = (
            metrics.varint(len(body) + len(metrics.varint(len(body))) + 1)
            + b"\x00"
            + metrics.varint(len(body))
            + body
        )
        with patch.object(socket, "create_connection") as connection:
            stream = connection.return_value.__enter__.return_value
            parts = iter(bytes([byte]) for byte in reply)
            stream.recv.side_effect = lambda size: next(parts)
            self.assertEqual(metrics.minecraft_players(25567), 7)
            packet = stream.sendall.call_args.args[0]
            self.assertTrue(
                packet.endswith(b"\x01\x01\x00")
            )  # status state, status request
            self.assertIn(struct.pack(">H", 25567), packet)


unittest.main()
