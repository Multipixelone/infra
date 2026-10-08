"""Exercise configuration migrations with private files and a fake SDK."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import tomlkit

COOLING_COMMAND, DAEMON, COOLING_SOURCE, FAKEROOT, RGB_SETTINGS = sys.argv[1:6]
del sys.argv[1:6]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


cooling = load("link_cooling_config", COOLING_SOURCE)
GPU = "13d8f4a5be256999d60cb90f5cb7c6418a3f5a70946d2761c2049de37081d0d1"


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="link-cooling-test-", dir="/tmp/opencode"
        )
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "coolercontrol"

    def run_cooling(self):
        subprocess.run(
            [COOLING_COMMAND, "--config-dir", str(self.directory)],
            check=True,
            capture_output=True,
        )
        return tomlkit.parse((self.directory / "config.toml").read_text())

    def check_daemon(self):
        env = {
            **os.environ,
            "CC_CONFIG_DIR": str(self.directory),
            "CC_DATA_DIR": str(self.root / "data"),
        }
        checked = subprocess.run(
            [FAKEROOT, DAEMON, "check"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def seed_old(self):
        self.directory.mkdir()
        # Include the real observed GPU assignment, plus a disconnected cooler.
        old = tomlkit.document()
        old["devices"] = {
            cooling.KRAKEN: "NZXT Kraken Z (Z53, Z63 or Z73)",
            GPU: "amdgpu",
            cooling.SMART: "NZXT Smart Device V2",
        }
        old["device-settings"] = {
            GPU: {"fan1": {"profile_uid": cooling.OLD_GPU_GRAPH}},
            cooling.SMART: {
                "fan1": {"profile_uid": cooling.OLD_MIX},
                "fan2": {"profile_uid": cooling.OLD_MIX},
                "fan3": {"speed_fixed": 64},
            },
            cooling.KRAKEN: {
                "lcd": {"lcd": {"mode": "liquid", "brightness": 100}},
                "external": {"lighting": {"mode": "off"}},
            },
        }
        for channels in old["device-settings"].values():
            for channel, setting in list(channels.items()):
                inline = tomlkit.inline_table()
                for key, value in list(setting.items()):
                    if isinstance(value, dict):
                        nested = tomlkit.inline_table()
                        nested.update(value)
                        setting[key] = nested
                inline.update(setting)
                channels[channel] = inline
        old["profiles"] = tomlkit.aot()
        for profile in (
            {
                "uid": cooling.OLD_GPU_GRAPH,
                "name": "AIO Radiator GPU (Performance)",
                "p_type": "Graph",
                "function_uid": "0",
                "speed_profile": [[40.0, 30], [55.0, 65], [70.0, 100]],
                "temp_source": {"device_uid": GPU, "temp_name": "temp1"},
            },
            {
                "uid": cooling.OLD_MIX,
                "name": "AIO Radiator (Performance)",
                "p_type": "Mix",
                "function_uid": "0",
                "member_profile_uids": [cooling.OLD_GPU_GRAPH],
                "mix_function_type": "Max",
            },
            {
                "uid": "old-kraken-graph",
                "name": "Liquid",
                "p_type": "Graph",
                "function_uid": "0",
                "speed_profile": [[30.0, 30], [50.0, 100]],
                "temp_source": {"device_uid": cooling.KRAKEN, "temp_name": "liquid"},
            },
        ):
            if "temp_source" in profile:
                inline = tomlkit.inline_table()
                inline.update(profile["temp_source"])
                profile["temp_source"] = inline
            old["profiles"].append(tomlkit.item(profile))
        (self.directory / "config.toml").write_text(tomlkit.dumps(old))
        ui = {
            "devices": [GPU, cooling.KRAKEN, cooling.SMART],
            "deviceSettings": [{"name": "GPU"}, {"name": "z53"}, {"name": "Smart"}],
            "dashboards": [
                {
                    "deviceChannelNames": [
                        {"deviceUID": cooling.KRAKEN, "channelName": "pump"},
                        {"deviceUID": GPU, "channelName": "fan1"},
                    ]
                }
            ],
        }
        (self.directory / "config-ui.json").write_text(json.dumps(ui))
        return old

    def test_cooler_argb_defaults_match_parallel_fans(self):
        settings = json.loads(Path(RGB_SETTINGS).read_text())
        self.assertEqual(settings["cooler"]["ledCount"], 9)
        board = settings["cooler"]["device"]
        self.assertEqual(settings["devices"][board]["pixelCount"], 13)

    def test_fresh_profiles_are_accepted_by_real_daemon(self):
        document = self.run_cooling()
        self.check_daemon()
        managed = [p for p in document["profiles"] if p["name"].endswith("(Nix)")]
        self.assertEqual(len(managed), 4)
        for profile in managed:
            if profile["p_type"] == "Graph":
                self.assertTrue(
                    all(point[1] >= 30 for point in profile["speed_profile"])
                )
                self.assertEqual(profile["speed_profile"][-1], [80.0, 100])

    def test_migration_preserves_gpu_and_unassigned_fans(self):
        before = self.seed_old()
        document = self.run_cooling()
        self.check_daemon()
        self.assertEqual(
            document["device-settings"][GPU], before["device-settings"][GPU]
        )
        self.assertEqual(
            document["device-settings"][cooling.SMART]["fan3"], {"speed_fixed": 64}
        )
        old_gpu = next(
            p for p in before["profiles"] if p["uid"] == cooling.OLD_GPU_GRAPH
        )
        new_gpu = next(
            p for p in document["profiles"] if p["uid"] == cooling.OLD_GPU_GRAPH
        )
        for key in old_gpu:
            if key != "name":
                self.assertEqual(new_gpu[key], old_gpu[key])
        case = next(
            p for p in document["profiles"] if p["name"] == "Case CPU/GPU max (Nix)"
        )
        self.assertEqual(
            document["device-settings"][cooling.SMART]["fan1"]["profile_uid"],
            case["uid"],
        )

    def test_kraken_and_parallel_ui_entries_are_removed(self):
        self.seed_old()
        document = self.run_cooling()
        self.assertNotIn(cooling.KRAKEN, tomlkit.dumps(document))
        self.assertNotIn("old-kraken-graph", tomlkit.dumps(document))
        ui = json.loads((self.directory / "config-ui.json").read_text())
        self.assertEqual(ui["devices"], [GPU, cooling.SMART])
        self.assertEqual(ui["deviceSettings"], [{"name": "GPU"}, {"name": "Smart"}])
        self.assertEqual(
            ui["dashboards"][0]["deviceChannelNames"],
            [{"deviceUID": GPU, "channelName": "fan1"}],
        )

    def test_repeated_startup_is_idempotent_and_retains_original_backup(self):
        self.seed_old()
        original = (self.directory / "config.toml").read_bytes()
        self.run_cooling()
        first = (self.directory / "config.toml").read_bytes()
        self.run_cooling()
        self.assertEqual((self.directory / "config.toml").read_bytes(), first)
        self.assertEqual(
            (self.directory / "config.toml.pre-link-nix").read_bytes(), original
        )

    def test_malformed_auxiliary_file_does_not_change_toml(self):
        self.seed_old()
        original = (self.directory / "config.toml").read_bytes()
        (self.directory / "modes.json").write_text("{ broken")
        result = subprocess.run(
            [COOLING_COMMAND, "--config-dir", str(self.directory)],
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.directory / "config.toml").read_bytes(), original)

    def test_symlinked_config_is_rejected(self):
        self.seed_old()
        original = (self.directory / "config.toml").read_bytes()
        target = self.root / "managed.toml"
        target.write_bytes(original)
        (self.directory / "config.toml").unlink()
        (self.directory / "config.toml").symlink_to(target)
        result = subprocess.run(
            [COOLING_COMMAND, "--config-dir", str(self.directory)],
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
