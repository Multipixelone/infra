"""Exercise lifecycle delivery with synthetic telemetry and no Discord access."""

import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("discord_status", sys.argv.pop(1))
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)
exposition, metrics_source, patterns = (sys.argv.pop(1) for _ in range(3))

CONFIG = {
    "serverId": "survival",
    "channelId": "123",
    "displayName": "Survival",
    "colors": {
        "awake": "#a6e3a1",
        "starting": "#fab387",
        "resting": "#6c7086",
        "stopped": "#f38ba8",
        "failed": "#f38ba8",
        "disabled": "#6c7086",
    },
}


def metrics(timestamp, state="running", ready=1, failed=0, success=1):
    labels = 'server_id="survival",host="link",game="minecraft-paper"'
    text = f'games_metrics_last_update_timestamp_seconds{{host="link"}} {timestamp}\n'
    for name, value in (("ready", ready), ("failed", failed)):
        text += f"games_server_{name}{{{labels}}} {value}\n"
    text += f"games_metrics_collection_success{{{labels}}} {success}\n"
    for candidate in ("running", "sleeping", "stopped", "disabled"):
        text += f'games_server_state{{{labels},state="{candidate}"}} {int(candidate == state)}\n'
    # Other scopes/servers must not introduce duplicate lifecycle samples.
    text += f'games_resource_collection_success{{{labels},scope="server"}} 1\n'
    text += f'games_resource_collection_success{{{labels},scope="container"}} 1\n'
    text += 'games_server_ready{server_id="terraria"} 0\n'
    return text


class Discord:
    def __init__(self):
        self.calls = []
        self.errors = []
        self.messages = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if self.errors:
            error = self.errors.pop(0)
            if error:
                raise error
        if method == "GET":
            return self.messages
        return {"id": "456"}


class LifecycleTest(unittest.TestCase):
    def setUp(self):
        self.record = {}
        self.discord = Discord()
        self.saved = []

    def tick(self, now, text=None, boot="boot-a", **kwargs):
        return status.update(
            CONFIG,
            self.record,
            metrics(now, **kwargs) if text is None else text,
            now,
            boot,
            self.discord,
            lambda value: self.saved.append(copy.deepcopy(value)),
        )

    def stable(self, start=1000, **kwargs):
        for now in range(start, start + 91, 30):
            outcome = self.tick(now, **kwargs)
        return outcome

    def test_one_card_then_edits_without_chat_spam(self):
        self.assertEqual(self.stable(), "updated")
        self.assertEqual(self.discord.calls[0][0], "POST")
        self.assertTrue(self.saved[0]["creationUncertain"])
        self.assertEqual(self.saved[0]["nonce"], self.discord.calls[0][2]["nonce"])
        self.assertTrue(self.discord.calls[0][2]["enforce_nonce"])
        self.assertEqual(self.tick(1120), "unchanged")
        self.assertEqual(len(self.discord.calls), 1)
        self.assertEqual(self.stable(1150, state="sleeping", ready=0), "updated")
        method, path, body = self.discord.calls[-1]
        self.assertEqual((method, path), ("PATCH", "/channels/123/messages/456"))
        self.assertIn("join Minecraft to wake it", body["embeds"][0]["description"])
        self.assertEqual(body["allowed_mentions"], {"parse": []})

    def test_awake_rest_awake_flap_never_posts_notice(self):
        self.stable()
        for now in (1120, 1150):
            self.tick(now, state="sleeping", ready=0)
        self.stable(1180)
        self.assertEqual(len(self.discord.calls), 1)
        self.assertEqual(self.record["published"], "awake")

    def test_short_initial_wake_is_coalesced(self):
        self.tick(1000)
        self.tick(1030, state="sleeping", ready=0)
        self.tick(1060)
        self.assertFalse(self.discord.calls)
        self.assertEqual(self.tick(1090), "pending")
        self.assertEqual(self.tick(1120), "pending")
        self.assertEqual(self.tick(1150), "updated")
        self.assertEqual(len(self.discord.calls), 1)

    def test_correct_state_and_palette(self):
        for expected, inputs in (
            ("awake", {}),
            ("starting", {"ready": 0}),
            ("resting", {"state": "sleeping", "ready": 0}),
            ("stopped", {"state": "stopped", "ready": 0}),
            ("failed", {"state": "stopped", "ready": 0, "failed": 1}),
            ("failed", {"state": "sleeping", "ready": 0, "failed": 1}),
            ("disabled", {"state": "disabled", "ready": 0}),
        ):
            with self.subTest(expected=expected):
                self.record.clear()
                self.assertEqual(self.stable(**inputs), "updated")
                embed = self.discord.calls[-1][2]["embeds"][0]
                self.assertEqual(
                    embed["color"], int(CONFIG["colors"][expected][1:], 16)
                )
                self.assertEqual(set(embed), {"description", "color"})
                self.assertEqual(self.record["published"], expected)

    def test_bad_telemetry_retains_card_and_resets_pending(self):
        self.stable()
        for text in (
            "",
            "garbage",
            metrics(900),
            metrics(2000),
            metrics(1120, success=0),
            metrics(1120, ready=2),
            metrics(1120).replace('state="sleeping"} 0', 'state="sleeping"} 1'),
        ):
            with self.subTest(text=text):
                self.assertEqual(self.tick(1120, text), "unavailable")
                self.assertNotIn("pending", self.record)
                self.assertEqual(self.record["messageId"], "456")
        self.assertEqual(len(self.discord.calls), 1)

    def test_repeated_snapshot_cannot_satisfy_debounce(self):
        text = metrics(1000)
        for now in (1000, 1030, 1060, 1090):
            self.assertEqual(self.tick(now, text), "pending")
        self.assertFalse(self.discord.calls)

    def test_restart_preserves_card_but_restarts_observations(self):
        self.stable()
        self.tick(1120, state="sleeping", ready=0)
        self.record = json.loads(json.dumps(self.record))
        self.assertEqual(
            self.tick(1150, boot="boot-b", state="sleeping", ready=0), "pending"
        )
        self.assertEqual(self.record["messageId"], "456")
        self.assertEqual(self.record["pending"]["since"], 1150)
        self.assertEqual(len(self.discord.calls), 1)

    def test_gap_and_clock_rollback_restart_observations(self):
        self.tick(1000)
        self.assertEqual(self.tick(1120), "pending")
        self.assertEqual(self.record["pending"]["since"], 1120)
        self.assertEqual(self.tick(1050), "pending")
        self.assertEqual(self.record["pending"]["since"], 1050)
        self.assertFalse(self.discord.calls)

    def test_only_unknown_message_recreates(self):
        for code, creates in ((10008, True), (10003, False)):
            with self.subTest(code=code):
                self.record.clear()
                self.discord = Discord()
                self.stable()
                self.discord.errors = [status.DeliveryError(404, code)]
                outcome = self.stable(1120, state="stopped", ready=0)
                self.assertEqual(outcome, "updated" if creates else "delivery-failed")
                self.assertEqual(
                    sum(call[0] == "POST" for call in self.discord.calls),
                    2 if creates else 1,
                )

    def test_rate_limit_retains_card_and_respects_retry_after(self):
        self.stable()
        self.discord.errors = [status.DeliveryError(429, retry_after=125)]
        self.assertEqual(
            self.stable(1120, state="sleeping", ready=0), "delivery-failed"
        )
        self.assertEqual(self.tick(1240, state="sleeping", ready=0), "deferred")
        self.assertEqual(self.record["retryAt"], 1335)
        self.assertEqual(self.record["published"], "awake")
        self.assertEqual(self.record["messageId"], "456")

    def test_transient_edit_failure_retries_same_card(self):
        self.stable()
        self.discord.errors = [status.DeliveryError(503)]
        self.assertEqual(
            self.stable(1120, state="sleeping", ready=0), "delivery-failed"
        )
        self.assertEqual(self.tick(1240, state="sleeping", ready=0), "updated")
        self.assertEqual(self.discord.calls[-1][0], "PATCH")
        self.assertEqual(sum(call[0] == "POST" for call in self.discord.calls), 1)

    def test_uncertain_create_recovers_nonce_or_fails_closed(self):
        self.discord.errors = [status.DeliveryError()]
        self.assertEqual(self.stable(), "delivery-failed")
        self.assertTrue(self.record["creationUncertain"])
        # A busy recent history cannot establish absence of the attempted card.
        # Override the recorded request time to Discord's epoch for this fixture.
        self.record["creationAfter"] = 1420070400
        snowflake = str(100000 << 22)
        self.discord.messages = [{"id": snowflake, "nonce": "other"}] * 100
        self.assertEqual(self.tick(1120), "delivery-failed")
        self.assertEqual(self.discord.calls[-1][0], "GET")
        self.discord.messages = [{"id": "789", "nonce": self.record["nonce"]}]
        self.tick(1150)
        self.assertEqual(self.tick(1180), "updated")
        self.assertEqual(self.record["messageId"], "789")
        self.assertEqual(self.discord.calls[-1][1], "/channels/123/messages/789")
        self.assertEqual(sum(call[0] == "POST" for call in self.discord.calls), 1)

    def test_failed_initial_request_retries_when_history_proves_absence(self):
        self.discord.errors = [status.DeliveryError()]
        self.assertEqual(self.stable(), "delivery-failed")
        original_nonce = self.record["nonce"]
        self.assertEqual(self.tick(1120), "updated")
        self.assertEqual(
            [call[0] for call in self.discord.calls], ["POST", "GET", "POST"]
        )
        self.assertEqual(self.discord.calls[-1][2]["nonce"], original_nonce)
        self.assertNotIn("creationUncertain", self.record)
        self.assertNotIn("creationAfter", self.record)

    def test_oldest_history_entry_can_prove_absence(self):
        record = {
            "nonce": "missing",
            "creationAfter": 1420071000,
            "creationUncertain": True,
        }
        messages = [{"id": str(1000 << 22), "nonce": "other"}] * 100
        status.reconcile(messages, record)
        self.assertNotIn("creationUncertain", record)

    def test_atomic_state_is_private_and_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "status.json"
            status.atomic_json(path, {"messageId": "123"})
            status.atomic_json(path, {"messageId": "456"})
            self.assertEqual(json.loads(path.read_text()), {"messageId": "456"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(path.parent.glob(".discord-*")), [])

    def test_actual_games_exporter_is_compatible(self):
        text = subprocess.run(
            [sys.executable, exposition, metrics_source, patterns],
            check=True,
            text=True,
            capture_output=True,
        ).stdout
        self.assertEqual(status.observation(text, "survival", 1000), ("disabled", 1000))

    def test_malformed_discord_response_retains_uncertain_creation(self):
        def broken(method, path, body=None):
            return {}

        for now in (1000, 1030, 1060):
            self.tick(now)
        outcome = status.update(
            CONFIG,
            self.record,
            metrics(1090),
            1090,
            "boot-a",
            broken,
            lambda value: None,
        )
        self.assertEqual(outcome, "delivery-failed")
        self.assertTrue(self.record["creationUncertain"])
        self.assertNotIn("messageId", self.record)
        outcome = status.update(
            CONFIG,
            self.record,
            metrics(1120),
            1120,
            "boot-a",
            broken,
            lambda value: None,
        )
        self.assertEqual(outcome, "delivery-failed")

    def test_http_failures_do_not_expose_credentials(self):
        with (
            patch.object(
                status.urllib.request, "urlopen", side_effect=OSError("secret token")
            ),
            self.assertRaises(status.DeliveryError) as caught,
        ):
            status.transport("secret token")("POST", "/channels/123/messages", {})
        self.assertNotIn("secret", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
