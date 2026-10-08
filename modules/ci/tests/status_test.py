"""Offline status reconciliation tests using nix-fast-build 2.0.4's JSON schema.

results.Result.as_dict emits drvPath on EVAL; workers.run_builds emits BUILD
with attr/success/duration/error but no drvPath. No Forgejo or Nix daemon needed.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

if sys.argv[1:2] == ["mock-curl"]:
    payload = json.load(sys.stdin)
    with Path(os.environ["MOCK_POSTS"]).open("a") as posts:
        posts.write(json.dumps(payload) + "\n")
    sys.stdout.write("201")
    sys.exit(0)

STATUS = sys.argv.pop(1)
BASH = sys.argv.pop(1)
DRV = "/nix/store/shared-check.drv"
OTHER_DRV = "/nix/store/other-check.drv"
GUI = "home-manager/gui"
GAMING = "home-manager/gaming"
GATE = "configurations/nixos/link"


def evaluation(attr, drv: str | None = DRV, **fields):
    return {
        "type": "EVAL",
        "attr": attr,
        "success": True,
        "duration": 0.0,
        "error": None,
        **({"drvPath": drv} if drv is not None else {}),
        **fields,
    }


def build(attr, success=True, **fields):
    return {
        "type": "BUILD",
        "attr": attr,
        "success": success,
        "duration": 2.9,
        "error": None if success else "build exited with 1",
        **fields,
    }


class StatusTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.posts = self.root / "posts.jsonl"
        self.env = {
            **os.environ,
            "FORGE_API": "https://invalid.example.test/api/v1",
            "FORGE_REPO": "test/repository",
            "FORGE_SHA": "mock-commit",
            "FORGE_TOKEN": "mock-token",
            "CI_STATUS_DIR": str(self.root / "status"),
            "MOCK_POSTS": str(self.posts),
            "MOCK_PYTHON": sys.executable,
            "MOCK_TEST": str(Path(__file__).resolve()),
        }

    def invoke(self, command, payload="", *args):
        # An exported function overrides even writeShellApplication's runtime
        # PATH, so the actual packaged script can never reach a real curl.
        return subprocess.run(
            [
                BASH,
                "-c",
                (
                    'curl() { "$MOCK_PYTHON" "$MOCK_TEST" mock-curl "$@"; }; '
                    'export -f curl; exec "$@"'
                ),
                "--",
                STATUS,
                command,
                *args,
            ],
            input=payload,
            text=True,
            capture_output=True,
            env=self.env,
            check=False,
        )

    def reconcile(self, attrs, rows, rc=0):
        seed = self.invoke("seed", json.dumps(attrs))
        self.assertEqual(seed.returncode, 0, seed.stderr)
        consume = self.invoke(
            "consume", "".join(json.dumps(row) + "\n" for row in rows)
        )
        self.assertEqual(consume.returncode, 0, consume.stderr)
        finished = self.invoke("finish", "", str(rc))
        posts = [json.loads(line) for line in self.posts.read_text().splitlines()]
        terminal = {}
        for post in posts:
            attr = post["context"].removeprefix("checks / ")
            self.assertIn(attr, attrs)
            if post["state"] == "pending":
                continue
            self.assertNotIn(attr, terminal, "more than one terminal status")
            terminal[attr] = post
        self.assertEqual(set(terminal), set(attrs))
        return terminal, finished

    def test_duplicate_success_with_one_build(self):
        results, finished = self.reconcile(
            [GUI, GAMING], [evaluation(GUI), evaluation(GAMING), build(GAMING)]
        )
        self.assertEqual(finished.returncode, 0)
        for result in results.values():
            self.assertEqual(result["state"], "success")
            self.assertEqual(result["description"], "Built in 2s")

    def test_duplicate_failure_preserves_per_alias_gating(self):
        results, finished = self.reconcile(
            [GUI, GATE], [evaluation(GUI), evaluation(GATE), build(GUI, False)], rc=1
        )
        self.assertEqual(finished.returncode, 1)
        self.assertEqual(results[GUI]["state"], "warning")
        self.assertEqual(results[GATE]["state"], "failure")
        for result in results.values():
            self.assertEqual(result["description"], "build exited with 1")

    def test_late_alias_inherits_success_or_failure(self):
        for success in (True, False):
            with self.subTest(success=success):
                self.posts.unlink(missing_ok=True)
                results, finished = self.reconcile(
                    [GUI, GAMING],
                    [evaluation(GAMING), build(GAMING, success), evaluation(GUI)],
                    rc=0 if success else 1,
                )
                self.assertEqual(finished.returncode, 0)
                for result in results.values():
                    self.assertEqual(
                        result["state"], "success" if success else "warning"
                    )

    def test_distinct_derivation_does_not_inherit_result(self):
        results, finished = self.reconcile(
            [GUI, GATE],
            [evaluation(GUI), evaluation(GATE, OTHER_DRV), build(GUI)],
        )
        self.assertEqual(finished.returncode, 1)
        self.assertEqual(results[GUI]["state"], "success")
        self.assertEqual(results[GATE]["state"], "error")
        self.assertEqual(results[GATE]["description"], "No result reported")

    def test_late_gating_alias_inherits_advisory_build_failure(self):
        results, finished = self.reconcile(
            [GUI, GATE], [evaluation(GUI), build(GUI, False), evaluation(GATE)], rc=1
        )
        self.assertEqual(finished.returncode, 1)
        self.assertEqual(results[GUI]["state"], "warning")
        self.assertEqual(results[GATE]["state"], "failure")

    def test_distinct_derivations_have_independent_build_outcomes(self):
        results, finished = self.reconcile(
            [GUI, GAMING],
            [
                evaluation(GUI),
                evaluation(GAMING, OTHER_DRV),
                build(GUI, False),
                build(GAMING),
            ],
            rc=1,
        )
        self.assertEqual(finished.returncode, 0)
        self.assertEqual(results[GUI]["state"], "warning")
        self.assertEqual(results[GAMING]["state"], "success")

    def test_unresolved_fallback_without_rows(self):
        results, finished = self.reconcile([GATE], [], rc=1)
        self.assertEqual(finished.returncode, 1)
        self.assertEqual(results[GATE]["state"], "error")

    def test_cached_and_local_results_need_no_build(self):
        results, finished = self.reconcile(
            [GUI, GAMING],
            [
                evaluation(GUI, cacheStatus="cached"),
                evaluation(GAMING, cacheStatus="local"),
            ],
        )
        self.assertEqual(finished.returncode, 0)
        self.assertEqual(results[GUI]["description"], "Substituted from cache")
        self.assertEqual(results[GAMING]["description"], "Already in store")
        self.assertTrue(
            all(result["state"] == "success" for result in results.values())
        )

    def test_cached_result_is_not_overwritten_by_shared_build(self):
        results, finished = self.reconcile(
            [GUI, GAMING],
            [evaluation(GUI, cacheStatus="cached"), evaluation(GAMING), build(GAMING)],
        )
        self.assertEqual(finished.returncode, 0)
        self.assertEqual(results[GUI]["description"], "Substituted from cache")
        self.assertEqual(results[GAMING]["description"], "Built in 2s")

    def test_evaluation_error_is_not_overwritten_by_shared_build(self):
        results, finished = self.reconcile(
            [GATE, GUI],
            [
                evaluation(GATE, success=False, error="bad\nexpression\tmessage"),
                evaluation(GUI),
                build(GUI),
            ],
            rc=1,
        )
        self.assertEqual(finished.returncode, 1)
        self.assertEqual(results[GATE]["state"], "failure")
        self.assertEqual(
            results[GATE]["description"], "Evaluation failed: bad expression message"
        )
        self.assertEqual(results[GUI]["state"], "success")

    def test_missing_derivation_identity_never_groups_attributes(self):
        results, finished = self.reconcile(
            [GUI, GAMING], [evaluation(GUI, None), evaluation(GAMING, None), build(GUI)]
        )
        self.assertEqual(finished.returncode, 0)
        self.assertEqual(results[GUI]["state"], "success")
        self.assertEqual(results[GAMING]["state"], "error")

    def test_quoted_attribute_and_skipped_evaluation(self):
        quoted = "files:.gitignore"
        results, finished = self.reconcile(
            [quoted, GUI],
            [
                evaluation(f'"{quoted}"'),
                build(f'"{quoted}"'),
                evaluation(GUI, None, skipped=True, error="unsupported platform"),
            ],
        )
        self.assertEqual(finished.returncode, 0)
        self.assertEqual(results[quoted]["state"], "success")
        self.assertEqual(results[GUI]["description"], "Skipped: unsupported platform")

    def test_upload_failure_remains_infrastructure_fallback(self):
        results, finished = self.reconcile(
            [GUI],
            [
                evaluation(GUI),
                build(GUI),
                {"type": "ATTIC", "attr": GUI, "success": False},
            ],
            rc=1,
        )
        self.assertEqual(results[GUI]["state"], "success")
        self.assertEqual(finished.returncode, 1)
        self.assertIn("with no failing check", finished.stderr)


if __name__ == "__main__":
    unittest.main()
