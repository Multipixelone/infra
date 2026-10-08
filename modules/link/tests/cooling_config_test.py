"""Exercise configuration migrations with private files and a fake SDK."""

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import tomlkit

COOLING_COMMAND, DAEMON, COOLING_SOURCE, ARGB_SOURCE, FAKEROOT = sys.argv[1:6]
del sys.argv[1:6]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


cooling = load("link_cooling_config", COOLING_SOURCE)
argb = load("link_argb_config", ARGB_SOURCE)
GPU = "13d8f4a5be256999d60cb90f5cb7c6418a3f5a70946d2761c2049de37081d0d1"
SETTINGS = {
    "controller": "X570 AORUS ELITE WIFI",
    "zone": "D_LED1 Bottom",
    "led_count": 6,
    "ledfx_device": "x570-aorus-elite-wifi",
    "virtual": "top-front-fan",
    "port": 6742,
}


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


class FakeClient:
    def __init__(self, board_index=4, sized=False):
        self.devices = [SimpleNamespace(name="unrelated", id=0)]
        self.board = SimpleNamespace(name=SETTINGS["controller"], id=board_index)
        self.devices.append(self.board)
        self.closed = False
        self.resizes = []
        self.layout(6 if sized else 0)

    def layout(self, count):
        def leds(indices):
            return [SimpleNamespace(id=i) for i in indices]

        self.board.zones = [
            SimpleNamespace(
                name="D_LED1 Bottom", leds=leds(range(count)), resize=self.resize
            ),
            SimpleNamespace(name="D_LED2 Top", leds=[]),
            # Model SDK 0.3.6's cached IDs when an unchanged-length zone moves.
            SimpleNamespace(name="Motherboard", leds=leds(range(4))),
        ]
        self.board.leds = leds(range(count + 4))
        self.board.data = SimpleNamespace(
            zones=[
                SimpleNamespace(
                    name="D_LED1 Bottom", start_idx=0, leds=leds(range(count))
                ),
                SimpleNamespace(name="D_LED2 Top", start_idx=count, leds=[]),
                SimpleNamespace(
                    name="Motherboard", start_idx=count, leds=leds(range(4))
                ),
            ]
        )

    def resize(self, count):
        self.resizes.append(count)
        self.layout(count)

    def update(self):
        pass

    def disconnect(self):
        self.closed = True


class ArgbTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="link-argb-test-", dir="/tmp/opencode"
        )
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "config.json"
        self.original = {
            "devices": [
                {
                    "id": SETTINGS["ledfx_device"],
                    "type": "openrgb",
                    "config": {"openrgb_id": 7, "pixel_count": 4},
                },
                {
                    "id": "other",
                    "config": {"auth_token": "fixture-only", "pixel_count": 8},
                },
            ],
            "virtuals": [
                {
                    "id": SETTINGS["virtual"],
                    "effect": {"type": "blade_power_plus", "config": {"fixture": True}},
                    "segments": [["smart", 10, 17, True]],
                },
                {"id": "board", "segments": [[SETTINGS["ledfx_device"], 0, 3, False]]},
                {"id": "unrelated", "segments": [["other", 0, 7, False]]},
            ],
        }
        self.path.write_text(json.dumps(self.original))

    def configure(self, client):
        argb.configure(self.path, SETTINGS, client_factory=lambda **_: client)
        self.assertTrue(client.closed)
        return json.loads(self.path.read_text())

    def test_identity_lookup_resize_offsets_and_effect_preservation(self):
        client = FakeClient(board_index=9)
        result = self.configure(client)
        self.assertEqual(client.resizes, [6])
        self.assertEqual(result["devices"][0]["config"]["openrgb_id"], 9)
        self.assertEqual(result["devices"][0]["config"]["pixel_count"], 10)
        self.assertEqual(
            result["virtuals"][1]["segments"], [[SETTINGS["ledfx_device"], 6, 9, False]]
        )
        self.assertEqual(
            result["virtuals"][0]["segments"][-1],
            [SETTINGS["ledfx_device"], 0, 5, False],
        )
        self.assertEqual(
            result["virtuals"][0]["effect"], self.original["virtuals"][0]["effect"]
        )
        self.assertEqual(result["devices"][1], self.original["devices"][1])
        self.assertEqual(result["virtuals"][2], self.original["virtuals"][2])

    def test_restart_uses_saved_layout_and_does_not_duplicate_cooler(self):
        first = self.configure(FakeClient())
        self.assertEqual(self.configure(FakeClient()), first)
        self.assertEqual(self.configure(FakeClient(sized=True)), first)

    def test_interrupted_config_replacement_recovers_offsets(self):
        original = self.path.read_bytes()
        write = argb.atomic_write

        def fail_config(path, content):
            if path == self.path:
                raise OSError("simulated interruption before LedFx replacement")
            write(path, content)

        with (
            patch.object(argb, "atomic_write", side_effect=fail_config),
            self.assertRaises(OSError),
        ):
            self.configure(FakeClient())
        self.assertEqual(self.path.read_bytes(), original)
        result = self.configure(FakeClient(sized=True))
        self.assertEqual(
            result["virtuals"][1]["segments"], [[SETTINGS["ledfx_device"], 6, 9, False]]
        )

    def test_other_virtual_cannot_compete_for_cooler_pixels(self):
        self.configure(FakeClient())
        document = json.loads(self.path.read_text())
        document["virtuals"][1]["segments"] = [[SETTINGS["ledfx_device"], 0, 9, False]]
        self.path.write_text(json.dumps(document))
        result = self.configure(FakeClient(sized=True))
        self.assertEqual(
            result["virtuals"][1]["segments"], [[SETTINGS["ledfx_device"], 6, 9, False]]
        )

    def test_missing_or_ambiguous_controller_preserves_files(self):
        original = self.path.read_bytes()
        for devices in (
            [],
            [
                SimpleNamespace(name=SETTINGS["controller"]),
                SimpleNamespace(name=SETTINGS["controller"]),
            ],
        ):
            client = FakeClient()
            client.devices = devices
            with self.assertRaises(ValueError):
                self.configure(client)
            self.assertEqual(self.path.read_bytes(), original)
            self.assertEqual(client.resizes, [])
            self.assertTrue(client.closed)

    def test_missing_virtual_causes_no_hardware_operation(self):
        document = copy.deepcopy(self.original)
        document["virtuals"] = []
        self.path.write_text(json.dumps(document))
        with self.assertRaises(ValueError):
            argb.configure(
                self.path,
                SETTINGS,
                client_factory=lambda **_: self.fail("SDK must not be opened"),
            )

    def test_direction_is_preserved_when_resizing_splits_a_segment(self):
        result = argb.remap_segments(
            [["board", 0, 5, True]],
            "board",
            {"D_LED1": [0, 1], "Motherboard": [2, 3, 4, 5]},
            {"D_LED1": list(range(6)), "Motherboard": [6, 7, 8, 9]},
        )
        self.assertEqual(result, [["board", 6, 9, True], ["board", 0, 1, True]])


if __name__ == "__main__":
    unittest.main()
