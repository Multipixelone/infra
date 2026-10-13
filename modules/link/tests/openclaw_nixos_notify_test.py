"""Short source-extracted notifier tests: no Nix, gateway, Telegram or deployment.

The VM check separately exercises real privilege dropping and durable approval.
These tests substitute only identity, working directory and the mutable CLI.
"""

import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "openclaw-nixos-activation.nix"
TARGET = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz0-nixos-system-link-fixture"
EXPIRY = "2026-10-12T13:14:15Z"


class NotifierTest(unittest.TestCase):
    source: str = ""
    script: str = ""

    def setUp(self):
        self.source = SOURCE.read_text()
        self.script = self.source.split('name = "openclaw-nixos-approval-notify";', 1)[
            1
        ]
        self.script = self.script.split("text = ''", 1)[1].split("\n        '';", 1)[0]
        self.script = textwrap.dedent(self.script)
        self.assertIn(
            '(( EUID != 0 )) && [[ "$(id -un)" == tunnel ]] || exit 1', self.script
        )
        self.script = (
            self.script.replace(
                '(( EUID != 0 )) && [[ "$(id -un)" == tunnel ]] || exit 1',
                "# Identity enforced by production script and VM check",
            )
            .replace("cd /home/tunnel", 'cd "$TEST_HOME"')
            .replace("/home/tunnel/.npm-global/bin/openclaw", "mock_openclaw")
            .replace("''${", "${")
        )

    def delivery_json(self, outcome="sent", nested_only=False):
        delivery: dict[str, object] = {
            "requested": True,
            "attempted": outcome != "no_visible_payload",
            "status": "suppressed" if outcome == "no_visible_payload" else outcome,
            "succeeded": "partial"
            if outcome == "partial_failed"
            else outcome != "failed",
        }
        if outcome in ("failed", "partial_failed"):
            delivery.update(error=True, errorMessage="mock-secret")
            if outcome == "partial_failed":
                delivery.update(resultCount=1, sentBeforeError=True)
        else:
            delivery["resultCount"] = 1 if outcome == "sent" else 0
            if outcome == "no_visible_payload":
                delivery["reason"] = "no_visible_payload"
            elif outcome == "suppressed":
                delivery["reason"] = "mock-secret"
        response: dict[str, object] = {
            "status": "ok",
            "result": {
                "deliveryStatus": delivery,
                "payloads": [{"text": "mock-secret"}],
            },
        }
        if not nested_only:
            response["deliveryStatus"] = delivery
        return json.dumps(response)

    def invoke(self, mode, status=0, hang=False, payload=None):
        with tempfile.TemporaryDirectory(prefix="openclaw-notify-mock-") as directory:
            # Only the mock input fixture is a file; production captures in memory.
            (Path(directory) / "response").write_text(
                self.delivery_json() if payload is None else payload
            )
            prefix = r"""
set -euo pipefail
mock_openclaw() {
  printf '%s\0' "$@" >> "$TEST_HOME/argv"
  printf '%s' "$(< "$TEST_HOME/response")"
  printf 'mock-secret\n' >&2
  if [[ "$MOCK_HANG" == 1 ]]; then sleep 2; fi
  return "$MOCK_STATUS"
}
"""
            script = self.script
            if hang:
                # Exercise actual GNU timeout behavior without waiting 650s.
                script = script.replace(
                    "--kill-after=5s 650s", "--kill-after=0.1s 0.2s"
                )
                # A shell function isn't a standalone timeout executable.
                prefix += "export -f mock_openclaw\n"
                script = script.replace(
                    "mock_openclaw agent", "bash -c 'mock_openclaw \"$@\"' mock agent"
                )
            else:
                prefix += r"""
timeout() {
  printf '%s\0' "$1" "$2" > "$TEST_HOME/lifetime"
  shift 2
  "$@"
}
"""
            result = subprocess.run(
                [
                    "bash",
                    "--noprofile",
                    "--norc",
                    "-c",
                    prefix + script,
                    "notifier",
                    TARGET,
                    mode,
                    EXPIRY,
                ],
                env={
                    **os.environ,
                    "TEST_HOME": directory,
                    "MOCK_STATUS": str(status),
                    "MOCK_HANG": str(int(hang)),
                },
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            args = (Path(directory) / "argv").read_bytes().decode().split("\0")[:-1]
            if not hang:
                self.assertEqual(
                    (Path(directory) / "lifetime").read_bytes(),
                    b"--kill-after=5s\x00650s\x00",
                )
            self.assertNotIn("mock-secret", result.stdout + result.stderr)
            return result, args

    def assert_route(self, args, mode):
        message = (
            f"Local approval notification: openclaw-nixos-approve: APPROVED mode={mode} "
            f"path={TARGET} expires={EXPIRY}. Read skills/nixos-deploy/SKILL.md again. "
            "Continue only the matching pending deployment once through the root-owned "
            "approval gate, and report the result or blocker. If pending state is "
            "missing, mismatched, expired, or already handled, report the blocker and do not deploy."
        )
        self.assertEqual(
            args,
            [
                "agent",
                "--session-key",
                "agent:main:telegram:direct:763701512",
                "--message",
                message,
                "--timeout",
                "600",
                "--deliver",
                "--reply-channel",
                "telegram",
                "--reply-to",
                "763701512",
                "--reply-account",
                "default",
                "--json",
            ],
        )

    def test_exact_agent_turn_and_delivery(self):
        for mode in ("test", "switch"):
            with self.subTest(mode=mode):
                result, args = self.invoke(mode)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("cli_exit=0 delivery_outcome=sent", result.stderr)
                self.assertIn(
                    "Telegram delivery confirmed by CLI metadata", result.stderr
                )
                self.assert_route(args, mode)

    def test_failure_is_sanitized_and_not_retried(self):
        result, args = self.invoke(
            "test", status=1, payload=self.delivery_json("failed")
        )
        self.assert_route(args, "test")  # Exact single invocation, not a retry.
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.count("couldn't notify Kestrel"), 1)
        for text in (
            "cli_exit=1 delivery_outcome=failed",
            "approval may already be consumed or expired",
            "Notification outcome unknown",
            "No automatic retry",
        ):
            self.assertIn(text, result.stderr)
        self.assertNotIn("approval remains valid", result.stderr)

    def test_bounded_timeout_is_sanitized_and_not_retried(self):
        result, args = self.invoke("switch", hang=True)
        self.assert_route(args, "switch")
        self.assertEqual(result.returncode, 124)
        self.assertIn("cli_exit=124", result.stderr)
        self.assertIn("No automatic retry", result.stderr)
        self.assertNotIn("Telegram delivery confirmed by CLI metadata", result.stderr)

    def test_unconfirmed_json_outcomes_are_not_success_or_retried(self):
        for payload, outcome in (
            (self.delivery_json("suppressed"), "suppressed"),
            (self.delivery_json("no_visible_payload"), "suppressed"),
            (self.delivery_json("failed"), "failed"),
            (self.delivery_json("partial_failed"), "partial_failed"),
            ("", "unknown"),
            ("mock-secret not json", "unknown"),
            ("null", "unknown"),
            ("{}", "unknown"),
            (json.dumps({"deliveryStatus": {"status": "mock-secret"}}), "unknown"),
            (
                json.dumps({"deliveryStatus": {"status": "sent", "succeeded": True}}),
                "unknown",
            ),
            (" " * (1024 * 1024 + 1) + self.delivery_json(), "unknown"),
        ):
            with self.subTest(outcome=outcome, size=len(payload)):
                result, args = self.invoke("test", payload=payload)
                self.assert_route(args, "test")
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"cli_exit=0 delivery_outcome={outcome}", result.stderr)
                self.assertEqual(result.stderr.count("couldn't notify Kestrel"), 1)
                self.assertIn("Notification outcome unknown", result.stderr)
                self.assertIn(
                    "approval may already be consumed or expired", result.stderr
                )
                self.assertIn("No automatic retry", result.stderr)
                self.assertNotIn(
                    "Telegram delivery confirmed by CLI metadata", result.stderr
                )

    def test_nested_gateway_delivery_status(self):
        result, args = self.invoke("test", payload=self.delivery_json(nested_only=True))
        self.assert_route(args, "test")
        self.assertEqual(result.returncode, 0)
        self.assertIn("cli_exit=0 delivery_outcome=sent", result.stderr)

    def test_independent_user_service_and_scrubbed_environment(self):
        tail = self.source.split("# Only immutable helpers run as root.", 1)[1].split(
            "activateLogic =", 1
        )[0]
        for text in (
            "${systemdRun} --quiet --collect --service-type=exec",
            '--unit="openclaw-nixos-approval-notify-$record_id"',
            "--property=User=tunnel --property=RuntimeMaxSec=660",
            "--property=TimeoutStopSec=5 --property=KillMode=control-group",
            "--property=StandardOutput=null --property=StandardError=journal",
            "${coreutils}/env -i HOME=/home/tunnel USER=tunnel LOGNAME=tunnel",
            "OPENCLAW_STATE_DIR=/home/tunnel/.openclaw LANG=C LC_ALL=C",
            '"$TARGET" "$MODE" "$expires_iso"',
            "notification failure does not revoke approval",
            "Notification worker started; Telegram delivery is not yet confirmed.",
        ):
            self.assertIn(text, tail)
        self.assertNotIn("10s", tail)
        self.assertNotIn("--wait", tail)
        self.assertNotIn("${coreutils}/rm", tail)
        self.assertNotIn("${flock}", tail)
        self.assertNotIn("system event", self.script)

    def test_handoff_failure_preserves_approval_and_reports_manual_fallback(self):
        tail = self.source.split("# Only immutable helpers run as root.", 1)[1]
        tail = tail.split("\n      '';", 1)[0]
        tail = "# Only immutable helpers run as root." + tail
        tail = tail.replace("''${", "${").replace("${systemdRun}", "mock_systemd_run")
        tail = tail.replace("${coreutils}/id -u tunnel", "printf 1000")
        tail = tail.replace("${coreutils}/printf", "printf")
        tail = tail.replace("${coreutils}/env", "/usr/bin/env")
        tail = tail.replace("${lib.getExe approvalNotifier}", "/mock/notifier")
        with tempfile.TemporaryDirectory(prefix="openclaw-handoff-mock-") as directory:
            record = Path(directory) / "approval.json"
            record.write_text("root-gate-record-sentinel")
            for status in (0, 1):
                prefix = r"""
set -euo pipefail
SUDO_USER=tunnel
issuer=1000
record_id=approval-fixture
TARGET="$1"
MODE=test
expires_iso="$2"
mock_systemd_run() {
  printf '%s\0' "$@" > "$TEST_HOME/handoff"
  return "$MOCK_STATUS"
}
"""
                result = subprocess.run(
                    [
                        "bash",
                        "--noprofile",
                        "--norc",
                        "-c",
                        prefix + tail,
                        "handoff",
                        TARGET,
                        EXPIRY,
                    ],
                    env={
                        **os.environ,
                        "TEST_HOME": directory,
                        "MOCK_STATUS": str(status),
                    },
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertEqual(result.returncode, 0)
                self.assertEqual(record.read_text(), "root-gate-record-sentinel")
                args = (
                    (Path(directory) / "handoff").read_bytes().decode().split("\0")[:-1]
                )
                self.assertEqual(args[-4:], ["/mock/notifier", TARGET, "test", EXPIRY])
                self.assertEqual(args.count("--property=User=tunnel"), 1)
                if status:
                    self.assertEqual(result.stderr.count("couldn't notify Kestrel"), 1)
                    self.assertIn(
                        "notification failure does not revoke approval", result.stderr
                    )
                    self.assertIn("No automatic retry", result.stderr)
                else:
                    self.assertIn(
                        "Notification worker started; Telegram delivery is not yet confirmed.",
                        result.stdout,
                    )
                    self.assertIn("do not replay approval", result.stdout)


if __name__ == "__main__":
    unittest.main()
