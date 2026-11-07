"""Offline control-flow tests, not TLS/signature/Nix integration proofs.

Uses disposable bare Git repositories only. Nix is mocked at the process seam;
no live store, refs, SSH, deployment or network access is needed.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("prebuild", SOURCE)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class PrebuildTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.previous)
        self.git("init", "--bare", "remote.git")
        self.git("init", "-b", "main", "checkout")
        os.chdir(self.root / "checkout")
        self.git("config", "user.name", "Offline test")
        self.git("config", "user.email", "offline@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        Path("flake.lock").write_text("{}\n")
        self.sha = self.commit("initial")
        self.remote = str(self.root / "remote.git")
        self.git("push", self.remote, "HEAD:refs/heads/main")
        self.cfg = {
            "enable": True,
            "publicKey": "test:" + "A" * 43 + "=",
            "state": str(self.root / "state"),
            "repository": "test/infra",
            "defaultBranch": "main",
            "deployBranch": "deploy",
            "domain": "forge.example.invalid",
            "actor": "test",
            "remote": self.remote,
            "cache": "https://cache.example.invalid:5050",
            "hosts": ["impa", "iot", "marin"],
        }
        self.helper = p.Prebuild(self.cfg)
        self.helper.initialize()
        self.env = patch.dict(
            os.environ,
            {
                "GITHUB_REPOSITORY": "test/infra",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_SHA": self.sha,
                "FORGE_TOKEN": "offline-token",
                "LINK_PREBUILD_PROMOTION": "true",
            },
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        self.counter = 0

    @staticmethod
    def git(*args):
        return subprocess.run(
            ["git", *args], text=True, capture_output=True, check=True
        ).stdout.strip()

    def commit(self, message):
        Path("source").write_text(message)
        self.git("add", ".")
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD")

    def prepared(self, sha=None, age=0):
        self.counter += 1
        run_id = f"{int(time.time())}-{self.counter:032x}"
        directory = self.helper.runs / run_id
        (directory / "roots").mkdir(parents=True)
        (directory / "lock").touch()
        hosts = {}
        for host in self.cfg["hosts"]:
            output = self.root / (host + "-system")
            output.mkdir(exist_ok=True)
            (directory / "roots" / host).symlink_to(output)
            hosts[host] = str(output)
        p.atomic(
            directory / "manifest.json",
            {
                "sha": sha or self.sha,
                "run": run_id,
                "ready": True,
                "lockDigest": self.helper.lock_digest(),
                "hosts": hosts,
                **{key: self.cfg[key] for key in ("repository", "cache", "publicKey")},
            },
        )
        os.utime(directory, (time.time() - age, time.time() - age))
        return run_id

    def deploy(self):
        rows = self.git("ls-remote", self.remote, "refs/heads/deploy")
        return rows.split()[0] if rows else None

    def test_disabled_and_unprovisioned(self):
        self.cfg["enable"] = False
        self.assertIsNone(self.helper.prepare("invalid"))
        self.assertFalse(self.helper.promote("invalid", "anything"))
        self.cfg["enable"] = True
        self.cfg["publicKey"] = None
        with self.assertRaises(p.Failure):
            self.helper.prepare(self.sha)
        self.assertIsNone(self.deploy())

    def test_wrong_event_repo_ref_sha_and_dirty(self):
        for name, value in [
            ("GITHUB_REPOSITORY", "other/repo"),
            ("GITHUB_REF", "refs/heads/deploy"),
            ("GITHUB_SHA", "f" * 40),
            ("GITHUB_EVENT_NAME", "pull_request"),
        ]:
            with (
                self.subTest(name=name),
                patch.dict(os.environ, {name: value}),
                self.assertRaises(p.Failure),
            ):
                self.helper.prepare(self.sha)
        Path("flake.lock").write_text("changed")
        with self.assertRaises(p.Failure):
            self.helper.prepare(self.sha)
        self.assertIsNone(self.deploy())

    def test_host_build_failure_leaves_unready_roots_and_no_ref(self):
        real = p.run

        def mocked(*args, **kwargs):
            if args[0] == "nix":
                if args[1:] == ("--version",):
                    return subprocess.CompletedProcess(args, 0, "nix (mock)\n", "")
                raise p.Failure("mock host build failed")
            return real(*args, **kwargs)

        with patch.object(p, "run", side_effect=mocked), self.assertRaises(p.Failure):
            self.helper.prepare(self.sha)
        directories = list(self.helper.runs.iterdir())
        self.assertEqual(len(directories), 1)
        self.assertFalse(p.load(directories[0] / "manifest.json")["ready"])
        self.assertTrue((directories[0] / "roots").exists())
        self.assertIsNone(self.deploy())

    def test_verify_remote_key_isolation_contents_and_closure_equality(self):
        calls = []

        def mocked(*args, **kwargs):
            calls.append((args, kwargs["env"]))
            return subprocess.CompletedProcess(
                args, 0, "/nix/store/system\n/nix/store/dep\n", ""
            )

        with (
            patch.dict(
                os.environ,
                {
                    "NIX_CONFIG": "extra-trusted-public-keys = unwanted\nsecret-key-files = /private"
                },
            ),
            patch.object(p, "run", side_effect=mocked),
        ):
            self.helper.verify(["/nix/store/system"], self.root)
        self.assertEqual(len(calls), 3)
        verify, env = calls[-1]
        self.assertEqual(
            verify[:7],
            (
                "nix",
                "store",
                "verify",
                "--store",
                self.cfg["cache"],
                "--recursive",
                "--sigs-needed",
            ),
        )
        self.assertNotIn("--no-contents", verify)
        self.assertNotIn("--no-trust", verify)
        self.assertNotIn("unwanted", env["NIX_CONFIG"])
        self.assertIn(
            "extra-trusted-public-keys =\nsecret-key-files =", env["NIX_CONFIG"]
        )
        self.assertEqual(env["NIX_USER_CONF_FILES"], "/dev/null")
        self.assertNotEqual(env["NIX_CONF_DIR"], os.environ.get("NIX_CONF_DIR"))
        self.assertFalse(Path(env["NIX_CONF_DIR"]).exists())
        with (
            patch.object(
                p,
                "run",
                side_effect=[
                    subprocess.CompletedProcess([], 0, "system\ndep\n", ""),
                    subprocess.CompletedProcess([], 0, "system\n", ""),
                ],
            ),
            self.assertRaisesRegex(p.Failure, "closure differs"),
        ):
            self.helper.verify(["system"], self.root)

    def test_remote_tls_or_signature_failure_is_fatal(self):
        for reason in ("TLS verification", "missing dependency", "wrong IA signature"):
            with (
                self.subTest(reason=reason),
                patch.object(p, "run", side_effect=p.Failure(reason)),
                self.assertRaises(p.Failure),
            ):
                self.helper.verify(["system"], self.root)
        self.assertIsNone(self.deploy())

    def test_create_fast_forward_same_sha_and_stable_roots(self):
        first = self.prepared()
        roots = self.helper.runs / first / "roots"
        links = {host: os.readlink(roots / host) for host in self.cfg["hosts"]}
        self.assertTrue(self.helper.promote(self.sha, first))
        self.assertEqual(self.deploy(), self.sha)
        self.assertTrue(self.helper.promote(self.sha, first))
        self.assertEqual(len(p.load(self.helper.state / "promoted.json")), 1)
        second_sha = self.commit("next")
        self.git("push", self.remote, "HEAD:refs/heads/main")
        with patch.dict(os.environ, {"GITHUB_SHA": second_sha}):
            self.assertTrue(self.helper.promote(second_sha, self.prepared(second_sha)))
        self.assertEqual(self.deploy(), second_sha)
        self.assertEqual(
            links, {host: os.readlink(roots / host) for host in self.cfg["hosts"]}
        )

    def test_old_completion_after_new_and_default_advance(self):
        first_sha = self.sha
        old_run = self.prepared()
        second_sha = self.commit("newer")
        self.git("push", self.remote, "HEAD:refs/heads/main")
        with patch.dict(os.environ, {"GITHUB_SHA": second_sha}):
            self.assertTrue(self.helper.promote(second_sha, self.prepared(second_sha)))
        self.git("checkout", "--detach", first_sha)
        self.assertFalse(self.helper.promote(first_sha, old_run))
        self.assertEqual(self.deploy(), second_sha)

    def test_no_promotion_without_interlock_or_ready_roots(self):
        run_id = self.prepared()
        with patch.dict(os.environ, {"LINK_PREBUILD_PROMOTION": "false"}):
            self.assertFalse(self.helper.promote(self.sha, run_id))
        (self.helper.runs / run_id / "roots" / "iot").unlink()
        with self.assertRaises(p.Failure):
            self.helper.promote(self.sha, run_id)
        self.assertIsNone(self.deploy())

    def test_divergent_deploy_is_never_replaced(self):
        run_id = self.prepared()
        competing = self.git(
            "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "out-of-band deploy"
        )
        self.git("push", self.remote, competing + ":refs/heads/deploy")
        with self.assertRaisesRegex(p.Failure, "not an ancestor"):
            self.helper.promote(self.sha, run_id)
        self.assertEqual(self.deploy(), competing)
        self.assertFalse((self.helper.state / "promotion-intent.json").exists())

    def test_discovery_error_is_not_absence(self):
        self.cfg["remote"] = str(self.root / "nonexistent")
        with self.assertRaisesRegex(p.Failure, "discovery failed"):
            self.helper.promote(self.sha, self.prepared())
        self.assertFalse((self.helper.state / "promotion-intent.json").exists())

    def test_push_conflict_preserves_intent_and_roots(self):
        run_id = self.prepared()
        real = self.helper.git

        def conflict(*args, **kwargs):
            if args[0] == "push":
                competing = self.git(
                    "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "competing writer"
                )
                self.git("push", self.remote, competing + ":refs/heads/deploy")
            return real(*args, **kwargs)

        with (
            patch.object(self.helper, "git", side_effect=conflict),
            self.assertRaises(p.Failure),
        ):
            self.helper.promote(self.sha, run_id)
        self.assertTrue((self.helper.state / "promotion-intent.json").exists())
        self.assertTrue((self.helper.runs / run_id / "roots").exists())
        with self.assertRaisesRegex(p.Failure, "unexplained"):
            self.helper.promote(self.sha, run_id)

    def test_lost_push_ack_reconciles_without_rewind(self):
        run_id = self.prepared()
        real = self.helper.git

        def lost_ack(*args, **kwargs):
            result = real(*args, **kwargs)
            if args[0] == "push":
                raise p.Failure("lost acknowledgment after remote accepted")
            return result

        with (
            patch.object(self.helper, "git", side_effect=lost_ack),
            self.assertRaises(p.Failure),
        ):
            self.helper.promote(self.sha, run_id)
        self.assertEqual(self.deploy(), self.sha)
        self.assertTrue((self.helper.state / "promotion-intent.json").exists())
        self.assertTrue(self.helper.promote(self.sha, run_id))
        self.assertFalse((self.helper.state / "promotion-intent.json").exists())
        self.assertEqual(len(p.load(self.helper.state / "promoted.json")), 1)

    def test_before_push_and_before_finalization_recovery(self):
        run_id = self.prepared()
        real = self.helper.git

        def before_push(*args, **kwargs):
            if args[0] == "push":
                raise p.Failure("interrupted before push")
            return real(*args, **kwargs)

        with (
            patch.object(self.helper, "git", side_effect=before_push),
            self.assertRaises(p.Failure),
        ):
            self.helper.promote(self.sha, run_id)
        self.assertIsNone(self.deploy())
        self.assertTrue((self.helper.state / "promotion-intent.json").exists())
        with (
            patch.object(
                self.helper, "finalize", side_effect=OSError("interrupted bookkeeping")
            ),
            self.assertRaises(OSError),
        ):
            self.helper.promote(self.sha, run_id)
        self.assertEqual(self.deploy(), self.sha)
        self.assertTrue(self.helper.promote(self.sha, run_id))

    def test_unexplained_intent_stops_and_preserves(self):
        run_id = self.prepared()
        p.atomic(
            self.helper.state / "promotion-intent.json",
            {"run": run_id, "old": "a" * 40, "candidate": self.sha},
        )
        with self.assertRaisesRegex(p.Failure, "unexplained"):
            self.helper.promote(self.sha, run_id)
        self.assertTrue((self.helper.runs / run_id).exists())

    def test_retention_count_grace_active_and_intent(self):
        old = [self.prepared(age=90000) for _ in range(5)]
        active = self.prepared(age=90000)
        intent = self.prepared(age=90000)
        recent = self.prepared(age=100)
        history = [
            {"run": run_id, "candidate": f"{i:040x}", "promoted": time.time() - 90000}
            for i, run_id in enumerate(old)
        ]
        p.atomic(self.helper.state / "promoted.json", history)
        p.atomic(self.helper.state / "promotion-intent.json", {"run": intent})
        with p.locked(self.helper.runs / active / "lock"):
            self.helper.prune()
        self.assertEqual(
            {path.name for path in self.helper.runs.iterdir()},
            set(old[-3:] + [active, intent, recent]),
        )
        # A promoted closure within the 24h grace survives beyond count 3.
        grace = self.prepared(age=90000)
        history.insert(
            0, {"run": grace, "candidate": "e" * 40, "promoted": time.time() - 86399}
        )
        p.atomic(self.helper.state / "promoted.json", history)
        self.helper.prune()
        self.assertTrue((self.helper.runs / grace).exists())

    def test_same_sha_retries_do_not_evict_distinct_predecessors(self):
        generations = [self.prepared(age=90000) for _ in range(4)]
        history = [
            {"run": run_id, "candidate": f"{i:040x}", "promoted": time.time() - 90000}
            for i, run_id in enumerate(generations)
        ]
        retries = [self.prepared(age=90000) for _ in range(4)]
        history.extend(
            {"run": run_id, "candidate": f"{3:040x}", "promoted": time.time() - 90000}
            for run_id in retries
        )
        p.atomic(self.helper.state / "promoted.json", history)
        self.helper.prune()
        self.assertEqual(
            {path.name for path in self.helper.runs.iterdir()},
            {generations[1], generations[2], retries[-1]},
        )

    def test_credential_file_not_argv_and_environment_restored(self):
        before = {k: v for k, v in os.environ.items() if k.startswith("GIT_CONFIG_")}
        with self.helper.credentials():
            count = int(os.environ["GIT_CONFIG_COUNT"])
            value = os.environ[f"GIT_CONFIG_VALUE_{count - 1}"]
            self.assertNotIn("offline-token", value)
            creds = Path(value.split("--file=", 1)[1])
            self.assertEqual(creds.stat().st_mode & 0o777, 0o600)
            self.assertIn("offline-token", creds.read_text())
        self.assertFalse(creds.exists())
        self.assertEqual(
            before, {k: v for k, v in os.environ.items() if k.startswith("GIT_CONFIG_")}
        )


if __name__ == "__main__":
    unittest.main()
