"""Link-only closure preparation and monotonic, leased deployment promotion.

No activation and no signing credential. Configuration is supplied by the Nix
wrapper, not by workflow input. Locks/roots live outside runner workspaces.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import quote


class Failure(RuntimeError):
    pass


def run(*args, env=None, check=True):
    result = subprocess.run(args, text=True, capture_output=True, env=env, check=False)
    if check and result.returncode:
        # Do not print argv/environment: authentication can be inherited.
        raise Failure(f"{args[0]} failed ({result.returncode}): {result.stderr}")
    return result


def atomic(path, value):
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    with tmp.open("x") as out:
        os.chmod(tmp, 0o600)
        json.dump(value, out, sort_keys=True)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)
    sync_directory(path.parent)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextlib.contextmanager
def locked(path, blocking=True):
    with Path(path).open("a+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield


def load(path, default=None):
    return json.loads(Path(path).read_text()) if Path(path).exists() else default


def valid_sha(sha):
    return re.fullmatch(r"[0-9a-f]{40}", sha or "") is not None


class Prebuild:
    def __init__(self, config):
        self.cfg = config
        self.state = Path(config["state"])
        self.runs = self.state / "runs"

    def gate(self, sha):
        if not self.cfg["enable"]:
            return False
        if not self.cfg.get("publicKey"):
            raise Failure("cache is enabled without a provisioned public key")
        if (
            os.environ.get("GITHUB_REPOSITORY") != self.cfg["repository"]
            or os.environ.get("GITHUB_REF") != "refs/heads/" + self.cfg["defaultBranch"]
            or os.environ.get("GITHUB_EVENT_NAME") not in ("push", "workflow_dispatch")
            or os.environ.get("GITHUB_SHA") != sha
            or not valid_sha(sha)
        ):
            raise Failure("not an authoritative default-branch event/SHA")
        if self.git("rev-parse", "HEAD").stdout.strip() != sha:
            raise Failure("checkout does not match event SHA")
        self.clean()
        return True

    def clean(self):
        if self.git(
            "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=none"
        ).stdout:
            raise Failure("tracked checkout or submodules are dirty")
        if any(
            not line.startswith(" ")
            for line in self.git(
                "submodule", "status", "--recursive"
            ).stdout.splitlines()
        ):
            raise Failure("submodule checkout differs from recorded source")

    @staticmethod
    def git(*args, check=True):
        return run("git", *args, check=check)

    def initialize(self):
        self.runs.mkdir(parents=True, exist_ok=True, mode=0o700)

    @staticmethod
    def lock_digest():
        return hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest()

    def prepare(self, sha):
        if not self.gate(sha):
            return None
        self.initialize()
        run_id = str(int(time.time())) + "-" + uuid.uuid4().hex
        directory = self.runs / run_id
        directory.mkdir(mode=0o700)
        with locked(directory / "lock"):
            roots = directory / "roots"
            roots.mkdir()
            manifest = {
                "sha": sha,
                "lockDigest": self.lock_digest(),
                "run": run_id,
                "attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
                "workflowRun": os.environ.get("GITHUB_RUN_ID", ""),
                "created": time.time(),
                "ready": False,
                "hosts": {},
                "nixVersion": run("nix", "--version").stdout.strip(),
                "repository": self.cfg["repository"],
                "cache": self.cfg["cache"],
                "publicKey": self.cfg["publicKey"],
            }
            atomic(directory / "manifest.json", manifest)
            for host in self.cfg["hosts"]:
                root = roots / host
                # Do not move roots after the daemon registers indirect roots.
                run(
                    "nix",
                    "--accept-flake-config",
                    "build",
                    "--no-update-lock-file",
                    "--no-write-lock-file",
                    "--store",
                    "daemon",
                    "--builders",
                    "",
                    "--out-link",
                    str(root),
                    f".#nixosConfigurations.{host}.config.system.build.toplevel",
                )
                output = str(root.resolve(strict=True))
                if not re.fullmatch(
                    r"/nix/store/[0-9a-z]{32}-[^/]+", output
                ) or output.endswith(".drv"):
                    raise Failure("build did not produce a concrete system output")
                manifest["hosts"][host] = output
            self.clean()
            if self.lock_digest() != manifest["lockDigest"]:
                raise Failure("lock file changed during preparation")
            self.verify(list(manifest["hosts"].values()), directory)
            manifest["ready"] = True
            manifest["verified"] = time.time()
            manifest["verification"] = (
                "remote recursive closure equality + native signatures and NAR contents"
            )
            atomic(directory / "manifest.json", manifest)
        return run_id

    def verify(self, paths, directory):
        # Separate config AND fresh metadata cache: never verify warm local
        # objects, inherit another public key, or load a private signing key.
        # Native Nix requires signatures for IA objects; CA objects legitimately
        # authenticate by their content identity instead (not a signature proof).
        with tempfile.TemporaryDirectory(prefix="verification-", dir=directory) as temp:
            env = {
                **os.environ,
                "NIX_CONF_DIR": temp,
                "NIX_USER_CONF_FILES": "/dev/null",
                "XDG_CACHE_HOME": temp,
                "NIX_CONFIG": "\n".join(
                    [
                        "experimental-features = nix-command flakes",
                        "trusted-public-keys = " + self.cfg["publicKey"],
                        "extra-trusted-public-keys =",
                        "secret-key-files =",
                        "substituters =",
                        "extra-substituters =",
                        "require-sigs = true",
                        "ssl-verify = true",
                        "narinfo-cache-positive-ttl = 0",
                        "narinfo-cache-negative-ttl = 0",
                        "http-connections = 4",
                        "max-jobs = 4",
                        "connect-timeout = 15",
                        "stalled-download-timeout = 60",
                        "download-attempts = 3",
                    ]
                ),
            }
            local = run(
                "nix", "path-info", "--store", "daemon", "--recursive", *paths, env=env
            )
            remote = run(
                "nix",
                "path-info",
                "--store",
                self.cfg["cache"],
                "--recursive",
                *paths,
                env=env,
            )
            if set(local.stdout.splitlines()) != set(remote.stdout.splitlines()):
                raise Failure("remote runtime closure differs from local closure")
            run(
                "nix",
                "store",
                "verify",
                "--store",
                self.cfg["cache"],
                "--recursive",
                "--sigs-needed",
                "1",
                *paths,
                env=env,
            )

    def manifest(self, run_id, sha=None):
        if not re.fullmatch(r"[0-9]+-[0-9a-f]{32}", run_id):
            raise Failure("invalid prepared run ID")
        directory = self.runs / run_id
        m = load(directory / "manifest.json")
        if (
            not m
            or not m.get("ready")
            or m["run"] != run_id
            or (sha and m["sha"] != sha)
        ):
            raise Failure("run has no ready verification for candidate")
        if any(m.get(k) != self.cfg[k] for k in ("repository", "cache", "publicKey")):
            raise Failure("prepared source/cache configuration differs")
        if set(m["hosts"]) != set(self.cfg["hosts"]) or not valid_sha(m["sha"]):
            raise Failure("invalid prepared host set/SHA")
        for host, output in m["hosts"].items():
            root = directory / "roots" / host
            if not root.is_symlink() or str(root.resolve(strict=True)) != output:
                raise Failure("persistent root missing or changed")
        return m

    @contextlib.contextmanager
    def credentials(self):
        token = os.environ.get("FORGE_TOKEN")
        if not token or "\n" in token:
            raise Failure("FORGE_TOKEN is required")
        # No token in argv or persistent checkout config. Remove checkout's
        # automatic-token extraheader, which otherwise overrides our PAT.
        self.git(
            "config",
            "--local",
            "--unset-all",
            f"http.https://{self.cfg['domain']}/.extraheader",
            check=False,
        )
        with tempfile.TemporaryDirectory(prefix="git-auth-", dir=self.state) as tmp:
            creds = Path(tmp) / "credentials"
            creds.write_text(
                f"https://{quote(self.cfg['actor'], safe='')}:{quote(token, safe='')}@{self.cfg['domain']}\n"
            )
            creds.chmod(0o600)
            # Environment, not git config mutation, so concurrent jobs cannot
            # steal each other's credentials. Keep private-input rewrites.
            saved = {k: v for k, v in os.environ.items() if k.startswith("GIT_CONFIG_")}
            count = int(os.environ.get("GIT_CONFIG_COUNT", "0"))
            values = [
                ("credential.helper", ""),
                ("credential.helper", f"store --file={creds}"),
            ]
            for i, (key, value) in enumerate(values, count):
                os.environ[f"GIT_CONFIG_KEY_{i}"] = key
                os.environ[f"GIT_CONFIG_VALUE_{i}"] = value
            os.environ["GIT_CONFIG_COUNT"] = str(count + len(values))
            try:
                yield
            finally:
                for key in list(os.environ):
                    if key.startswith("GIT_CONFIG_"):
                        del os.environ[key]
                os.environ.update(saved)

    def discover(self, branch):
        ref = "refs/heads/" + branch
        result = self.git(
            "ls-remote", "--exit-code", "--heads", self.cfg["remote"], ref, check=False
        )
        if result.returncode == 2:
            return None
        if result.returncode:
            raise Failure("remote discovery failed (not an absent ref)")
        rows = result.stdout.splitlines()
        if (
            len(rows) != 1
            or rows[0].split()[1] != ref
            or not valid_sha(rows[0].split()[0])
        ):
            raise Failure("ambiguous remote advertisement")
        sha = rows[0].split()[0]
        shallow = (
            self.git("rev-parse", "--is-shallow-repository").stdout.strip() == "true"
        )
        self.git(
            "fetch",
            "--no-tags",
            *(["--unshallow"] if shallow else []),
            self.cfg["remote"],
            ref,
        )
        if self.git("rev-parse", "FETCH_HEAD").stdout.strip() != sha:
            raise Failure("ref advanced during discovery; retry")
        return sha

    def finalize(self, intent):
        # Only durable bookkeeping after a successful push. A failure here can
        # fail CI although deploy advanced; intent+roots remain for recovery.
        history = load(self.state / "promoted.json", [])
        if not any(row["run"] == intent["run"] for row in history):
            history.append({**intent, "promoted": time.time()})
            atomic(self.state / "promoted.json", history)
        (self.state / "promotion-intent.json").unlink()
        sync_directory(self.state)

    def promote(self, sha, run_id):
        if not self.gate(sha) or os.environ.get("LINK_PREBUILD_PROMOTION") != "true":
            return False
        self.initialize()
        with locked(self.state / "promotion.lock"), self.credentials():
            intent_path = self.state / "promotion-intent.json"
            intent = load(intent_path)
            if intent:
                self.manifest(intent["run"], intent["candidate"])
                remote = self.discover(self.cfg["deployBranch"])
                if remote == intent["candidate"]:
                    self.finalize(intent)
                elif remote == intent["old"]:
                    # No ref update occurred. Abort the old intent durably;
                    # roots remain, eligible only for normal grace retention.
                    intent_path.unlink()
                    sync_directory(self.state)
                else:
                    raise Failure(
                        "unexplained deploy ref with unresolved intent; preserve all roots"
                    )
            self.manifest(run_id, sha)  # validate ID before constructing a lock path
            with locked(self.runs / run_id / "lock"):
                m = self.manifest(run_id, sha)
                if self.lock_digest() != m["lockDigest"]:
                    raise Failure("checkout lock differs from prepared manifest")
                current = self.discover(self.cfg["defaultBranch"])
                old = self.discover(self.cfg["deployBranch"])
                if current != sha:
                    return False  # stale successful build, not a release
                if (
                    old
                    and self.git(
                        "merge-base", "--is-ancestor", old, sha, check=False
                    ).returncode
                ):
                    raise Failure(
                        "deploy is not an ancestor; refusing rewind/divergence"
                    )
                intent = {"old": old, "candidate": sha, "run": run_id}
                atomic(intent_path, intent)
                if old != sha:
                    ref = "refs/heads/" + self.cfg["deployBranch"]
                    self.git(
                        "push",
                        f"--force-with-lease={ref}:{old or ''}",
                        self.cfg["remote"],
                        f"{sha}:{ref}",
                    )
                self.finalize(intent)
            self.prune_locked()
        return True

    def prune_locked(self, now=None):
        now = time.time() if now is None else now
        history = load(self.state / "promoted.json", [])
        intent = load(self.state / "promotion-intent.json")
        # Retries at the same revision must never displace predecessors.
        # One rooted run per last three distinct release SHAs is sufficient;
        # every promotion within the grace period is retained independently.
        keep = set()
        releases = set()
        for row in reversed(history):
            if row["candidate"] not in releases:
                releases.add(row["candidate"])
                keep.add(row["run"])
                if len(releases) == 3:
                    break
        keep.update(row["run"] for row in history if now - row["promoted"] < 86400)
        if intent:
            keep.add(intent["run"])
        for directory in self.runs.iterdir():
            if (
                directory.is_symlink()
                or not directory.is_dir()
                or directory.name in keep
            ):
                continue
            if now - directory.stat().st_mtime < 86400:
                continue
            try:
                with locked(directory / "lock", blocking=False):
                    # Deleting roots is allowed; moving them is never allowed.
                    shutil.rmtree(directory)
            except BlockingIOError:
                continue

    def prune(self):
        if not self.cfg["enable"]:
            return
        self.initialize()
        with locked(self.state / "promotion.lock"):
            self.prune_locked()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("command", choices=["prepare", "promote", "prune"])
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument("--run")
    args = parser.parse_args()
    helper = Prebuild(load(args.config))
    if args.command == "prepare":
        prepared = helper.prepare(args.sha)
        if prepared:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as out:
                out.write("prepared-run=" + prepared + "\n")
    elif args.command == "promote":
        helper.promote(args.sha, args.run or "")
    else:
        helper.prune()


if __name__ == "__main__":
    try:
        main()
    except (Failure, OSError, ValueError, KeyError) as error:
        print(f"link-prebuild: {error}", file=sys.stderr)
        sys.exit(1)
