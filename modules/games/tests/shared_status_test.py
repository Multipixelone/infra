"""Shared status contracts without modifying the server runtime helper."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper_path, runtime_path = sys.argv[1:3]
del sys.argv[1:3]
shared = load("shared_status", helper_path)
runtime = load("runtime", runtime_path)


class SharedStatusTest(unittest.TestCase):
    def setUp(self):
        self.item = {
            "id": "velocity",
            "unit": "minecraft-server-velocity.service",
            "serverPort": 25565,
            "available": True,
        }
        self.cfg = {"proxy": self.item, "commands": {"systemctl": "/fixed/systemctl"}}

    def check_status(self, active, sub, result, expected, listening=True, ready=False):
        with (
            patch.object(
                runtime,
                "run",
                return_value=f"ActiveState={active}\nSubState={sub}\nResult={result}\n",
            ) as run,
            patch.object(
                runtime, "passive_listening", return_value=listening
            ) as passive,
            patch.object(
                runtime, "listening", side_effect=AssertionError("must not connect")
            ),
            patch.object(
                runtime, "rcon", side_effect=AssertionError("must not query players")
            ),
        ):
            value = shared.status(runtime, self.cfg, "velocity", self.item)
            self.assertEqual(
                value,
                {
                    "id": "velocity",
                    "state": expected,
                    "unitState": active,
                    "ready": ready,
                    "playersOnline": None,
                    "available": self.item["available"],
                },
            )
            run.assert_called_once_with(
                self.cfg,
                "systemctl",
                "show",
                self.item["unit"],
                "--property=ActiveState,SubState,Result,MainPID,ControlGroup",
            )
            if ready or (
                listening is False and expected == "running" and active == "active"
            ):
                passive.assert_called_once_with(25565)
            else:
                passive.assert_not_called()

    def test_lifecycle(self):
        for active, sub, result, expected, listening, ready in [
            ("active", "running", "success", "running", True, True),
            ("active", "running", "success", "running", False, False),
            ("reloading", "reload", "success", "running", True, True),
            ("activating", "start", "success", "running", True, False),
            ("inactive", "dead", "success", "stopped", True, False),
            ("deactivating", "stop-sigterm", "success", "stopped", True, False),
            ("failed", "failed", "exit-code", "failed", True, False),
            ("inactive", "failed", "success", "failed", True, False),
            ("inactive", "dead", "oom-kill", "failed", True, False),
            ("active", "running", "exit-code", "failed", True, False),
        ]:
            with self.subTest(active=active, result=result):
                self.check_status(active, sub, result, expected, listening, ready)

    def test_no_port(self):
        del self.item["serverPort"]
        self.check_status("active", "running", "success", "running")

    def test_unavailable(self):
        self.item["available"] = False
        self.check_status("active", "running", "success", "running")
        self.check_status("inactive", "dead", "missing-secrets", "stopped")
        with patch.object(
            runtime, "run", side_effect=subprocess.CalledProcessError(1, ["systemctl"])
        ):
            self.assertEqual(
                shared.status(runtime, self.cfg, "velocity", self.item)["state"],
                "stopped",
            )

    def test_unexpected_systemd_failure_propagates(self):
        with (
            patch.object(
                runtime,
                "run",
                side_effect=subprocess.CalledProcessError(1, ["systemctl"]),
            ),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            shared.status(runtime, self.cfg, "velocity", self.item)

    def test_empty_inventory_cli(self):
        with tempfile.TemporaryDirectory() as temporary:
            inventory = Path(temporary) / "inventory.json"
            inventory.write_text(json.dumps({"proxy": {}}))
            result = subprocess.run(
                [
                    sys.executable,
                    helper_path,
                    "--inventory",
                    str(inventory),
                    "--runtime",
                    runtime_path,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(json.loads(result.stdout), [])


if __name__ == "__main__":
    unittest.main()
