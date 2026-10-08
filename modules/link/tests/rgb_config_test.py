"""Reconcile real LedFx fixture bytes with a fake SDK; never contact hardware."""

import copy
import importlib.util
import json
import logging
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SOURCE, SETTINGS_FILE, CONFIG_FIXTURE, SDK_FIXTURE, LEGACY_BOARD_FIXTURE = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("link_argb_config", SOURCE)
argb = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = argb
spec.loader.exec_module(argb)
SETTINGS = json.loads(Path(SETTINGS_FILE).read_text())
DEVICES = json.loads(Path(SDK_FIXTURE).read_text())
BOARD = "x570-aorus-elite-wifi"
SMART = "nzxt-smart-device-v2"
MOUSE = "tunable-rgb-gaming-mouse-g502"
RAM = "corsair-vengeance-pro-rgb"


class FakeClient:
    def __init__(self, devices=DEVICES):
        self.records = copy.deepcopy(devices)
        self.closed = False
        self.resizes = []
        self.updates = 0
        self.devices = []
        for record in self.records:
            live = SimpleNamespace()
            self.devices.append(live)
            self.refresh(live, record)

    def refresh(self, live, record):
        live.id, live.name = record["id"], record["name"]
        live.metadata = SimpleNamespace(
            **{key: record[key] for key in ("vendor", "serial", "location")}
        )
        live.leds = [SimpleNamespace(id=i) for i in range(record["pixelCount"])]
        live.data = SimpleNamespace(
            zones=[
                SimpleNamespace(
                    name=z["name"], start_idx=z["start"], leds=[None] * z["count"]
                )
                for z in record["zones"]
            ]
        )
        # Live Zone.leds IDs intentionally retain their original offsets when
        # D_LED1 grows; the helper must read fresh ControllerData offsets.
        if not hasattr(live, "zones"):
            live.zones = [
                SimpleNamespace(
                    name=z["name"],
                    leds=[
                        SimpleNamespace(id=i)
                        for i in range(z["start"], z["start"] + z["count"])
                    ],
                    resize=lambda count, index=i: self.resize(
                        live, record, index, count
                    ),
                )
                for i, z in enumerate(record["zones"])
            ]

    def resize(self, live, record, index, count):
        self.resizes.append((record["id"], record["zones"][index]["name"], count))
        delta = count - record["zones"][index]["count"]
        record["zones"][index]["count"] = count
        record["pixelCount"] += delta
        for zone in record["zones"][index + 1 :]:
            zone["start"] += delta
        self.refresh(live, record)
        live.zones[index].leds = [None] * count

    def update(self):
        self.updates += 1

    def disconnect(self):
        self.closed = True


def hang_worker(sender, *args):
    time.sleep(10)


class RgbTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="link-rgb-test-", dir="/tmp/opencode"
        )
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "config.json"
        self.original = Path(CONFIG_FIXTURE).read_bytes()
        self.path.write_bytes(self.original)
        self.settings = copy.deepcopy(SETTINGS)
        self.sleeps = []
        self.clients = []
        self.kwargs = []

    def configure(self, devices=DEVICES, factory=None):
        def client_factory(**kwargs):
            self.kwargs.append(kwargs)
            client = factory(len(self.clients)) if factory else FakeClient(devices)
            self.clients.append(client)
            return client

        def sdk(settings, enabled, resize_allowed):
            return argb.collect_sdk(
                settings, enabled, resize_allowed, client_factory, self.sleeps.append
            )

        with self.assertLogs(argb.LOG, level=logging.INFO) as logged:
            changed = argb.configure(self.path, self.settings, sdk=sdk)
        self.logs = logged.output
        self.assertTrue(all(c.closed for c in self.clients))
        return changed, json.loads(self.path.read_bytes())

    @staticmethod
    def device(document, identity):
        return next(d for d in document["devices"] if d["id"] == identity)["config"]

    @staticmethod
    def virtual(document, identity):
        return next(v for v in document["virtuals"] if v["id"] == identity)

    def test_real_identity_inventory_reorder_and_stale_collisions(self):
        devices = copy.deepcopy(DEVICES)
        indices = [4, 0, 6, 2, 1, 3, 5]
        for device, index in zip(devices, indices):
            device["id"] = index
            device["location"] = device["location"].replace(
                "/dev/i2c-10", "/dev/i2c-42"
            )
        changed, result = self.configure(devices)
        self.assertTrue(changed)
        for identity, declaration in self.settings["devices"].items():
            matched = next(
                (d for d in devices if argb.matches(d, declaration["match"])), None
            )
            if matched:
                self.assertEqual(
                    self.device(result, identity)["openrgb_id"], matched["id"]
                )
                self.assertEqual(
                    self.device(result, identity)["pixel_count"],
                    declaration["pixelCount"],
                )
        self.assertEqual(self.sleeps, [])
        self.assertTrue(all(k["protocol_version"] == 3 for k in self.kwargs))
        self.assertEqual(self.clients[0].resizes, [(3, "D_LED1", 9)])

    def test_absent_optional_collision_parks_and_reappearance_resolves(self):
        _, result = self.configure()
        for identity in (MOUSE, "razer-mouse-bungee-v3-chroma"):
            self.assertEqual(self.device(result, identity)["openrgb_id"], 7)
            self.assertTrue(
                any(
                    "INFO" in log and identity in log and "parking" in log
                    for log in self.logs
                )
            )
        self.assertEqual(self.device(result, "mk750")["openrgb_id"], 9)
        self.assertEqual(self.sleeps, [])
        records = copy.deepcopy(DEVICES)
        for index, identity in enumerate(
            (MOUSE, "razer-mouse-bungee-v3-chroma", "mk750"), 7
        ):
            decl = self.settings["devices"][identity]
            records.append(
                {
                    "id": index,
                    "name": decl["match"]["name"],
                    "vendor": "fixture",
                    "serial": identity,
                    "location": f"HID: /dev/hidraw{index}",
                    "pixelCount": decl["pixelCount"],
                    "zones": [{"name": "all", "start": 0, "count": decl["pixelCount"]}],
                }
            )
        _, result = self.configure(records)
        self.assertEqual(self.device(result, MOUSE)["openrgb_id"], 7)
        self.assertEqual(self.device(result, "mk750")["openrgb_id"], 9)
        self.assertEqual(
            self.device(result, "razer-mouse-bungee-v3-chroma")["openrgb_id"], 8
        )

    def test_idempotence_no_replacement_or_new_backup(self):
        self.configure()
        before = self.path.read_bytes()
        stat = self.path.stat()
        backups = list(self.path.parent.glob("*.pre-link-nix.*"))
        changed, _ = self.configure()
        self.assertFalse(changed)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.path.stat().st_mtime_ns, stat.st_mtime_ns)
        self.assertEqual(self.path.stat().st_ino, stat.st_ino)
        self.assertEqual(list(self.path.parent.glob("*.pre-link-nix.*")), backups)
        self.assertEqual(backups[0].read_bytes(), self.original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)

    def test_missing_required_device_preserves_its_fields_and_virtuals(self):
        original = json.loads(self.original)
        records = [
            d
            for d in DEVICES
            if d["name"] != self.settings["devices"][SMART]["match"]["name"]
        ]
        _, result = self.configure(records)
        self.assertEqual(self.sleeps, [2] * 4)
        self.assertEqual(self.device(result, SMART), self.device(original, SMART))
        for identity, segments in self.settings["virtuals"].items():
            if any(s["device"] == SMART for s in segments):
                self.assertEqual(
                    self.virtual(result, identity), self.virtual(original, identity)
                )
        self.assertEqual(self.device(result, BOARD)["openrgb_id"], 5)
        self.assertTrue(any("ERROR" in log and SMART in log for log in self.logs))

    def test_missing_only_declared_device_leaves_entire_file_untouched(self):
        self.settings["devices"] = {RAM: self.settings["devices"][RAM]}
        self.settings["virtuals"] = {RAM: self.settings["virtuals"][RAM]}
        changed, _ = self.configure([])
        self.assertFalse(changed)
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(list(self.path.parent.glob("*.pre-link-nix.*")), [])

    def test_required_detection_retries_optional_devices_do_not(self):
        def factory(attempt):
            return FakeClient([] if attempt < 2 else DEVICES)

        self.configure(factory=factory)
        self.assertEqual(self.sleeps, [2, 2])
        self.assertEqual(len(self.clients), 3)

    def test_serial_disambiguates_and_hid_path_can_change(self):
        records = copy.deepcopy(DEVICES)
        twin = copy.deepcopy(records[5])
        twin.update(id=7, serial="other-board", location="HID: /dev/hidraw12")
        records[5]["location"] = "HID: /dev/hidraw55"
        records.append(twin)
        _, result = self.configure(records)
        self.assertEqual(self.device(result, BOARD)["openrgb_id"], 5)
        self.assertEqual(self.clients[0].resizes, [(5, "D_LED1", 9)])

    def test_ambiguous_name_never_guesses_or_delays(self):
        self.settings["devices"][RAM]["match"]["location"] = None
        _, result = self.configure()
        self.assertEqual(
            self.device(result, RAM), self.device(json.loads(self.original), RAM)
        )
        self.assertEqual(self.sleeps, [])
        self.assertTrue(
            any("ERROR" in log and "multiple distinct" in log for log in self.logs)
        )

    def test_duplicate_twins_choose_lowest_and_warn(self):
        records = copy.deepcopy(DEVICES)
        twins = copy.deepcopy(records[:5] + records[6:])
        for twin in twins:
            twin["id"] += 7
        _, result = self.configure(records + twins)
        self.assertEqual(self.device(result, RAM)["openrgb_id"], 0)
        self.assertEqual(self.device(result, SMART)["openrgb_id"], 6)
        self.assertTrue(
            any(
                "WARNING" in log and "duplicate physical identity" in log
                for log in self.logs
            )
        )

    def test_duplicate_motherboard_resize_keeps_proven_canonical_controller(self):
        records = copy.deepcopy(DEVICES)
        twin = copy.deepcopy(records[5])
        twin["id"] = 12
        records.append(twin)
        _, result = self.configure(records)
        self.assertEqual(self.device(result, BOARD)["openrgb_id"], 5)
        self.assertEqual(self.device(result, BOARD)["pixel_count"], 13)
        self.assertEqual(self.clients[0].resizes, [(5, "D_LED1", 9)])
        self.assertTrue(any("duplicate physical identity" in log for log in self.logs))

    def test_optional_only_sdk_failure_does_not_retry(self):
        settings = copy.deepcopy(self.settings)
        settings["devices"] = {MOUSE: settings["devices"][MOUSE]}
        sleeps = []
        with self.assertRaises(ConnectionError):
            argb.collect_sdk(
                settings,
                {MOUSE},
                False,
                client_factory=lambda **_: (_ for _ in ()).throw(
                    ConnectionRefusedError()
                ),
                sleep=sleeps.append,
            )
        self.assertEqual(sleeps, [])

    def test_conflicting_declarations_cannot_claim_controller_twice(self):
        self.settings["devices"]["corsair-vengeance-pro-rgb-1"]["match"] = (
            copy.deepcopy(self.settings["devices"][RAM]["match"])
        )
        _, result = self.configure()
        original = json.loads(self.original)
        for identity in (RAM, "corsair-vengeance-pro-rgb-1"):
            self.assertEqual(
                self.device(result, identity), self.device(original, identity)
            )
        self.assertTrue(any("claimed by multiple" in log for log in self.logs))

    def test_exact_declared_segments_and_preserved_unowned_spans(self):
        _, result = self.configure()
        self.assertEqual(
            self.virtual(result, "top-front-fan")["segments"],
            [[SMART, 10, 17, True], [BOARD, 0, 8, False]],
        )
        self.assertEqual(
            self.virtual(result, BOARD)["segments"],
            [[BOARD, i, i, False] for i in range(9, 13)],
        )
        before, after = (
            argb.JsonDocument(self.original),
            argb.JsonDocument(self.path.read_bytes()),
        )
        for path, (start, end) in before.spans.items():
            if len(path) == 4 and path[0] == "devices" and path[2] == "config":
                if (
                    path[3] in ("openrgb_id", "pixel_count")
                    and before.value["devices"][path[1]]["id"]
                    in self.settings["devices"]
                ):
                    continue
            elif len(path) >= 3 and path[0] == "virtuals" and path[2] == "segments":
                continue
            # Compare non-overlapping leaf spans and entire untouched top-level
            # values, including presets, effects, scenes, and startup selectors.
            if path and (
                len(path) == 1
                and path[0] not in ("devices", "virtuals")
                or not isinstance(self.at(before.value, path), (list, dict))
            ):
                new_start, new_end = after.spans[path]
                self.assertEqual(
                    before.text[start:end], after.text[new_start:new_end], path
                )

        def masked(document):
            spans = []
            for identity in self.settings["devices"]:
                index = next(
                    i
                    for i, d in enumerate(document.value["devices"])
                    if d["id"] == identity
                )
                spans.extend(
                    document.spans[("devices", index, "config", key)]
                    for key in ("openrgb_id", "pixel_count")
                )
            for identity in self.settings["virtuals"]:
                index = next(
                    i
                    for i, v in enumerate(document.value["virtuals"])
                    if v["id"] == identity
                )
                spans.append(document.spans[("virtuals", index, "segments")])
            text = document.text
            for start, end in sorted(spans, reverse=True):
                text = text[:start] + "<owned>" + text[end:]
            return text

        self.assertEqual(masked(before), masked(after))
        self.assertEqual(set(before.value), set(after.value))
        self.assertEqual(list(before.value), list(after.value))

    @staticmethod
    def at(document, path):
        for key in path:
            document = document[key]
        return document

    def test_nonempty_scenes_and_presets_are_byte_identical(self):
        raw = self.original.replace(
            b'"scenes": {}',
            b'"scenes": { "Keep": { "effect": "rainbow", "escaped": "\\u00e9", "rate": 1.00 } }',
        )
        self.assertNotEqual(raw, self.original)
        self.path.write_bytes(raw)
        self.configure()
        before, after = (
            argb.JsonDocument(raw),
            argb.JsonDocument(self.path.read_bytes()),
        )
        for key in (
            "scenes",
            "user_presets",
            "user_colors",
            "user_gradients",
            "startup_scene_id",
            "startup_playlist_id",
        ):
            a, b = before.spans[(key,)], after.spans[(key,)]
            self.assertEqual(before.text[a[0] : a[1]], after.text[b[0] : b[1]])

    def test_owned_ui_edits_reset_and_effects_survive(self):
        self.configure()
        document = json.loads(self.path.read_bytes())
        target = self.virtual(document, "top-front-fan")
        target["segments"] = [[SMART, 0, 1, False]]
        target["effect"] = {
            "type": "rainbow",
            "config": {"speed": 2.25, "color": "#abcdef"},
        }
        self.path.write_text(json.dumps(document, indent=4) + "\n")
        _, result = self.configure()
        self.assertEqual(
            self.virtual(result, "top-front-fan")["segments"],
            [[SMART, 10, 17, True], [BOARD, 0, 8, False]],
        )
        self.assertEqual(
            self.virtual(result, "top-front-fan")["effect"], target["effect"]
        )
        self.assertEqual(len(list(self.path.parent.glob("*.pre-link-nix.*"))), 2)

    def test_count_mismatch_and_bad_range_skip_affected_records(self):
        records = copy.deepcopy(DEVICES)
        records[0]["pixelCount"] = 9
        _, result = self.configure(records)
        self.assertEqual(
            self.device(result, RAM), self.device(json.loads(self.original), RAM)
        )
        self.assertTrue(any("expected 10 LEDs, found 9" in log for log in self.logs))
        self.settings["virtuals"]["gpu"][0]["end"] = 4
        _, result = self.configure()
        self.assertEqual(
            self.virtual(result, "gpu")["segments"], [["gpu", 0, 3, False]]
        )
        self.assertTrue(any("segment exceeds" in log for log in self.logs))

    def test_zone_alias_old_board_layout_and_server_reset(self):
        records = copy.deepcopy(DEVICES)
        records[5]["zones"][0]["name"] = "D_LED1 Bottom"
        self.configure(records)
        first = self.path.read_bytes()
        self.configure(records)
        self.assertEqual(self.path.read_bytes(), first)
        self.configure(self.clients[-1].records)
        self.assertEqual(self.path.read_bytes(), first)

    def test_six_pixel_migration_activates_only_declared_cooler_virtuals(self):
        for alias in ("D_LED1", "D_LED1 Bottom"):
            with self.subTest(alias=alias):
                records = copy.deepcopy(DEVICES)
                records[5] = json.loads(Path(LEGACY_BOARD_FIXTURE).read_text())
                records[5]["zones"][0]["name"] = alias
                document = json.loads(self.original)
                self.device(document, BOARD)["pixel_count"] = 10
                target = self.virtual(document, "top-front-fan")
                target["segments"] = [[SMART, 10, 17, True], [BOARD, 0, 5, False]]
                target["active"] = False
                self.virtual(document, BOARD)["segments"] = [
                    [BOARD, i, i, False] for i in range(6, 10)
                ]
                self.virtual(document, BOARD)["active"] = False
                self.virtual(document, "back-fan")["active"] = False
                # An undeclared virtual using the same cooler pixels is user state.
                document["virtuals"].append(
                    {
                        "id": "user-cooler",
                        "active": False,
                        "segments": [[BOARD, 0, 5, False]],
                    }
                )
                raw = (json.dumps(document, indent=4) + "\n").encode()
                self.path.write_bytes(raw)
                changed, result = self.configure(records)
                self.assertTrue(changed)
                self.assertEqual(self.clients[-1].resizes, [(5, alias, 9)])
                self.assertEqual(self.device(result, BOARD)["pixel_count"], 13)
                self.assertEqual(
                    self.virtual(result, "top-front-fan")["segments"],
                    [[SMART, 10, 17, True], [BOARD, 0, 8, False]],
                )
                self.assertEqual(
                    self.virtual(result, BOARD)["segments"],
                    [[BOARD, i, i, False] for i in range(9, 13)],
                )
                self.assertTrue(self.virtual(result, "top-front-fan")["active"])
                self.assertFalse(self.virtual(result, BOARD)["active"])
                self.assertFalse(self.virtual(result, "back-fan")["active"])
                self.assertEqual(
                    self.virtual(result, "user-cooler"),
                    self.virtual(document, "user-cooler"),
                )
                self.assertEqual(
                    self.virtual(result, "top-front-fan")["effect"], target["effect"]
                )
                before, after = (
                    argb.JsonDocument(raw),
                    argb.JsonDocument(self.path.read_bytes()),
                )
                # Activation changes only its scalar span, retaining effect bytes.
                index = next(
                    i
                    for i, v in enumerate(document["virtuals"])
                    if v["id"] == "top-front-fan"
                )
                path = ("virtuals", index, "effect")
                a, b = before.spans[path], after.spans[path]
                self.assertEqual(before.text[a[0] : a[1]], after.text[b[0] : b[1]])
                first = self.path.read_bytes()
                backups = sorted(self.path.parent.glob("*.pre-link-nix.*"))
                changed, _ = self.configure(self.clients[-1].records)
                self.assertFalse(changed)
                self.assertEqual(self.clients[-1].resizes, [])
                self.assertEqual(self.path.read_bytes(), first)
                self.assertEqual(
                    sorted(self.path.parent.glob("*.pre-link-nix.*")), backups
                )

    def test_activation_requires_valid_segments_and_boolean_false(self):
        for active in (False, True, None, 0, "false"):
            with self.subTest(active=active):
                document = json.loads(self.original)
                self.virtual(document, "top-front-fan")["active"] = active
                self.path.write_text(json.dumps(document))
                _, result = self.configure()
                expected = True if active is False else active
                actual = self.virtual(result, "top-front-fan")["active"]
                self.assertEqual(actual, expected)
                self.assertIs(type(actual), type(expected))
        document = json.loads(self.original)
        self.virtual(document, "top-front-fan")["active"] = False
        self.path.write_text(json.dumps(document))
        records = [d for d in DEVICES if d["name"] != "NZXT Smart Device V2"]
        _, result = self.configure(records)
        self.assertEqual(
            self.virtual(result, "top-front-fan"),
            self.virtual(document, "top-front-fan"),
        )

    def test_interrupted_replace_retries_canonical_layout(self):
        with (
            patch.object(argb.os, "replace", side_effect=OSError("interrupted")),
            self.assertRaises(OSError),
        ):
            self.configure()
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(list(self.path.parent.glob(".config.json.*")), [])
        _, result = self.configure(self.clients[0].records)
        self.assertEqual(
            self.virtual(result, BOARD)["segments"],
            [[BOARD, i, i, False] for i in range(9, 13)],
        )
        self.assertEqual(self.device(result, BOARD)["pixel_count"], 13)

    def test_missing_cooler_virtual_prevents_resize(self):
        document = json.loads(self.original)
        document["virtuals"] = [
            v for v in document["virtuals"] if v["id"] != "top-front-fan"
        ]
        self.path.write_text(json.dumps(document))
        self.configure()
        self.assertEqual(self.clients[0].resizes, [])

    def test_symlink_duplicate_keys_and_malformed_json_are_rejected(self):
        for raw in (
            b'{"devices": [], "devices": []}',
            b'{"devices": [}',
            b'{"foo": NaN}',
        ):
            self.path.write_bytes(raw)
            with self.assertRaises(ValueError):
                argb.configure(
                    self.path,
                    self.settings,
                    sdk=lambda *_: self.fail("SDK must not run"),
                )
            self.assertEqual(self.path.read_bytes(), raw)
        self.path.unlink()
        self.path.symlink_to(CONFIG_FIXTURE)
        with self.assertRaises(ValueError):
            argb.configure(self.path, self.settings)

    def test_concurrent_edit_is_not_overwritten(self):
        edited = self.original + b"\n"

        def sdk(*args):
            self.path.write_bytes(edited)
            return argb.collect_sdk(
                *args, client_factory=lambda **_: FakeClient(), sleep=self.sleeps.append
            )

        with self.assertRaises(ValueError):
            argb.configure(self.path, self.settings, sdk=sdk)
        self.assertEqual(self.path.read_bytes(), edited)

    def test_sdk_hard_deadline_terminates_worker(self):
        with (
            patch.object(argb, "sdk_worker", hang_worker),
            self.assertRaises(TimeoutError),
        ):
            argb.bounded_sdk(
                self.settings, set(self.settings["devices"]), True, timeout=0.05
            )

    def test_fixture_token_redacted(self):
        document = json.loads(self.original)
        tokens = [
            d["config"]["auth_token"]
            for d in document["devices"]
            if "auth_token" in d.get("config", {})
        ]
        self.assertEqual(tokens, ["REDACTED-FIXTURE-TOKEN"])
        self.assertEqual(len(self.settings["devices"]), 10)
        self.assertEqual(len(self.settings["virtuals"]), 25)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
