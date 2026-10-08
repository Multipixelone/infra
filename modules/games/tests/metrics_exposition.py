"""Emit a disabled registry fixture for promtool's text exposition lint."""

import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("metrics", sys.argv[1])
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
with tempfile.TemporaryDirectory() as directory:
    inventory = {
        "host": "link",
        "patterns": json.loads(Path(sys.argv[2]).read_text()),
        "commands": {},
        "cgroupRoot": directory,
        "backupStateDir": directory,
        "backupPasswordPath": directory + "/missing-password",
        "servers": {
            "survival": {
                "game": "minecraft-paper",
                "unit": "minecraft-server-survival.service",
                "enabled": False,
                "available": False,
                "secretPaths": [],
                "wakeOnJoin": True,
                "backupEnabled": False,
                "capacity": 20,
                "memoryBytes": 6442450944,
            }
        },
    }
    with patch.object(metrics, "command", return_value=""):
        print(metrics.collect(inventory, {}, now=1000), end="")
