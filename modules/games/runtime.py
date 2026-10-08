"""Fixed-inventory game helpers. Installed only through writeShellApplication."""

import contextlib
import fcntl
import json
import os
import pwd
import re
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run(cfg, tool, *args, timeout=30):
    return subprocess.run(
        [cfg["commands"][tool], *map(str, args)],
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout,
    ).stdout


def server(cfg, identifier, proxy=False):
    if identifier in cfg["servers"]:
        return cfg["servers"][identifier]
    if proxy and identifier == "velocity" and cfg["proxy"]:
        return cfg["proxy"]
    raise ValueError("unknown game server")


def root():
    if os.geteuid() != 0:
        raise PermissionError("this internal helper requires root")


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, filename = tempfile.mkstemp(dir=path.parent, prefix=".games-")
    temporary = Path(filename)
    with os.fdopen(fd, "w") as stream:
        stream.write(json.dumps(value) + "\n")
    temporary.replace(path)


def reject_symlinks(path):
    """Root helpers never follow game-writable directory symlinks."""
    path = Path(path)
    for ancestor in [*reversed(path.parents), path]:
        if ancestor.is_symlink():
            raise ValueError("game configuration directory must not be a symlink")


def safe_directory(path):
    path = Path(path)
    reject_symlinks(path)
    path.mkdir(mode=0o750, parents=True, exist_ok=True)


def stop_result_path(cfg, identifier):
    return Path(cfg["stateDir"]) / (identifier + "-stop.json")


def require_saved(cfg, identifier):
    path = stop_result_path(cfg, identifier)
    if not path.exists() or not json.loads(path.read_text()).get("graceful", False):
        raise RuntimeError("no verified clean game shutdown; snapshot refused")


@contextlib.contextmanager
def lock(cfg, name):
    directory = Path(cfg["runDir"]) / "locks"
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / (name + ".lock")).open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def unit_state(cfg, item):
    try:
        output = run(
            cfg,
            "systemctl",
            "show",
            item["unit"],
            "--property=ActiveState,SubState,Result,MainPID,ControlGroup",
        )
    except subprocess.CalledProcessError:
        if not item["available"]:
            return {"ActiveState": "inactive", "Result": "missing-secrets"}
        raise
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def read_exact(connection, count):
    data = b""
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise ConnectionError("RCON closed the connection")
        data += part
    return data


def rcon(item, command):
    console = item["console"]
    password = Path(console["passwordFile"]).read_text().strip()
    with socket.create_connection(
        (console["host"], console["port"]), timeout=3
    ) as connection:
        connection.settimeout(15)

        def send(identifier, kind, body):
            packet = struct.pack("<ii", identifier, kind) + body.encode() + b"\0\0"
            connection.sendall(struct.pack("<i", len(packet)) + packet)

        def receive():
            length = struct.unpack("<i", read_exact(connection, 4))[0]
            if length < 10 or length > 1024 * 1024:
                raise ValueError("invalid RCON response length")
            packet = read_exact(connection, length)
            identifier, kind = struct.unpack("<ii", packet[:8])
            return identifier, kind, packet[8:-2].decode(errors="replace")

        send(1, 3, password)
        # Minecraft may send an empty RESPONSE_VALUE before AUTH_RESPONSE.
        for _ in range(3):
            identifier, kind, _ = receive()
            if identifier == -1:
                raise PermissionError("RCON authentication failed")
            if identifier == 1 and kind == 2:
                break
        else:
            raise ConnectionError("missing RCON authentication response")
        send(2, 2, command)
        try:
            identifier, _, body = receive()
        except ConnectionError:
            if command == "stop":
                return "Server stopping"
            raise
        if identifier != 2:
            raise ConnectionError("unexpected RCON response")
        return body


def process_children(pid):
    children = set()
    # Tokio can spawn Java from a non-leader thread. Its children appear under
    # that thread's task entry, rather than /task/$MAINPID/children.
    for path in Path(f"/proc/{int(pid)}/task").glob("*/children"):
        try:
            children.update(path.read_text().split())
        except FileNotFoundError:
            pass  # A worker thread may exit while its task entry is read.
    return sorted(children)


def status(cfg, identifier):
    item = server(cfg, identifier)
    state = unit_state(cfg, item)
    active = state.get("ActiveState") in ("active", "activating", "reloading")
    ready = active and listening(item["serverPort"])
    value = "running" if active else "stopped"
    if active and item["wakeOnJoin"] and not ready:
        pid = state.get("MainPID", "0")
        if not process_children(pid):
            value = "sleeping"
    players = 0 if value == "sleeping" else None
    if ready and item["console"]["method"] == "rcon":
        try:
            response = rcon(item, "list")
            match = re.search(r"There are (\d+) of a max", response)
            if match:
                players = int(match.group(1))
        except (OSError, ValueError, PermissionError):
            pass
    return {
        "id": identifier,
        "state": value,
        "unitState": state.get("ActiveState"),
        "ready": ready,
        "playersOnline": players,
        "available": item["available"],
    }


def prepare(cfg, identifier):
    root()
    item = server(cfg, identifier, proxy=True)
    if identifier in cfg["servers"]:
        atomic_json(stop_result_path(cfg, identifier), {"graceful": False})
    identity = pwd.getpwnam(item["owner"])
    runtime = Path(cfg["runDir"]) / identifier
    safe_directory(runtime)
    os.chown(runtime, identity.pw_uid, identity.pw_gid)
    if identity.pw_uid != 0:
        # Writable Minecraft paths are not trusted by root. Perform all writes
        # as their owner, including any paths an in-game plugin could symlink.
        os.setgroups([])
        os.setgid(identity.pw_gid)
        os.setuid(identity.pw_uid)
    for destination, template in item.get("configTemplates", {}).items():
        path = Path(destination)
        if identity.pw_uid == 0:
            safe_directory(path.parent)
        else:
            path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        if "secret" in template:
            content = Path(template["secret"]).read_bytes()
        else:
            text = Path(template["source"]).read_text()
            for token, secret in template.get("replacements", {}).items():
                value = Path(secret).read_text().strip()
                if not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", value):
                    raise ValueError(
                        "passwords and forwarding secrets must be 16–256 URL-safe characters"
                    )
                text = text.replace(token, value)
            if path.name == "lazymc.toml" and (runtime / "wake-once").exists():
                text = text.replace("wake_on_start = false", "wake_on_start = true")
                (runtime / "wake-once").unlink()
            content = text.encode()
        fd, filename = tempfile.mkstemp(dir=path.parent, prefix=".games-")
        temporary = Path(filename)
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        temporary.replace(path)
    if "mods" in item:
        safe_directory(item["logDir"])
        directory = Path(item["dataDir"]) / "tModLoader/Mods"
        safe_directory(directory)
        # The adapter owns this directory: removing a Nix declaration removes
        # the mod too, before the new modpack can open the world.
        for path in directory.glob("*.tmod"):
            path.unlink()
        for name, artifact in item["mods"].items():
            if not re.fullmatch(r"[A-Za-z0-9_]+", name):
                raise ValueError("invalid internal mod name")
            (directory / (name + ".tmod")).write_bytes(Path(artifact).read_bytes())
        atomic_json(directory / "enabled.json", sorted(item["mods"]))
        configs = Path(item["dataDir"]) / "tModLoader/ModConfigs"
        safe_directory(configs)
        for path in configs.glob("*.json"):
            path.unlink()
        for name, value in item["modConfigs"].items():
            if not re.fullmatch(r"[A-Za-z0-9_]+", name):
                raise ValueError("invalid mod configuration name")
            atomic_json(configs / (name + ".json"), value)


def paper_stop(cfg, identifier, pid):
    root()
    item = server(cfg, identifier)
    result = stop_result_path(cfg, identifier)
    atomic_json(result, {"graceful": False})
    children = process_children(pid)
    if not children:
        atomic_json(result, {"graceful": True})
        return
    if listening(item["console"]["port"]):
        response = rcon(item, "save-all flush")
        if "Saved" not in response and "saved" not in response:
            raise RuntimeError("Paper did not confirm its flushed save")
        rcon(item, "stop")
    else:
        # During startup, Java's own shutdown hook is the safe fallback.
        for child in children:
            os.kill(int(child), signal.SIGTERM)
    deadline = time.monotonic() + 150
    while any(Path(f"/proc/{child}").exists() for child in children):
        if time.monotonic() >= deadline:
            raise TimeoutError("Paper did not exit gracefully; do not snapshot")
        time.sleep(0.2)
    atomic_json(result, {"graceful": True})


def validate_repository(cfg):
    backup = cfg["backup"]
    if not backup["enabled"]:
        raise RuntimeError(
            "game backups are disabled; initialize the NAS repo and enable gameServers.backup.enable"
        )
    path = Path(backup["repository"])
    # Trigger the automount, then verify its source before any repository write.
    if not (path / "config").is_file():
        raise RuntimeError("NAS restic repository is not initialized")
    source = run(cfg, "findmnt", "-n", "-o", "SOURCE", "--target", path).strip()
    if source != backup["source"]:
        raise RuntimeError("refusing backup: expected alexandria NFS mount")
    run(cfg, "restic", "-r", path, "-p", backup["passwordFile"], "snapshots", "--json")


def snapshot(cfg, identifier):
    item = server(cfg, identifier)
    if not item["backup"]:
        raise RuntimeError("world backups are disabled for this server")
    validate_repository(cfg)
    for path in item["worldPaths"]:
        reject_symlinks(path)
    paths = [path for path in item["worldPaths"] if Path(path).exists()]
    if not paths:
        raise RuntimeError("no world exists to back up")
    metadata = Path(cfg["stateDir"]) / (identifier + ".json")
    if metadata.exists():
        paths.append(str(metadata))
    proof = stop_result_path(cfg, identifier)
    if proof.exists():
        paths.append(str(proof))
    output = run(
        cfg,
        "restic",
        "-r",
        cfg["backup"]["repository"],
        "-p",
        cfg["backup"]["passwordFile"],
        "backup",
        "--retry-lock",
        "30s",
        "--tag",
        "games:" + identifier,
        *paths,
        timeout=1700,
    )
    print(output, end="", flush=True)


def prechange(cfg, identifier):
    root()
    item = server(cfg, identifier)
    path = Path(cfg["stateDir"]) / (identifier + ".json")
    with lock(cfg, identifier):
        old = json.loads(path.read_text()) if path.exists() else None
        if old and old["fingerprint"] == item["fingerprint"]:
            return
        for world in item["worldPaths"]:
            reject_symlinks(world)
        worlds_exist = any(
            Path(p).exists() and any(Path(p).iterdir()) for p in item["worldPaths"]
        )
        if worlds_exist:
            require_saved(cfg, identifier)
            print("Taking required pre-change snapshot for " + identifier, flush=True)
            snapshot(cfg, identifier)
        atomic_json(
            path,
            {
                "id": identifier,
                "game": item["game"],
                "fingerprint": item["fingerprint"],
            },
        )


def log_tail(path, offset=0):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("container save log must be a regular file")
        stream.seek(offset)
        return stream.read(1024 * 1024).decode(errors="replace")


def container_stop(cfg, identifier):
    root()
    item = server(cfg, identifier)
    result = stop_result_path(cfg, identifier)
    atomic_json(result, {"graceful": False})
    logfile = Path(item["logDir"]) / "server.log"
    # Direct console exit avoids the entrypoint's SIGTERM/tee exit-code bug.
    # Fresh log evidence and both saved world files are mandatory, too.
    offset = logfile.stat(follow_symlinks=False).st_size
    before = {
        path: Path(path).stat(follow_symlinks=False).st_mtime_ns
        for path in item["worldFiles"]
    }
    console_root(cfg, identifier, "exit")
    exit_code = run(cfg, "podman", "wait", item["container"], timeout=150).strip()
    state = json.loads(
        run(cfg, "podman", "inspect", "--format", "{{json .State}}", item["container"])
    )
    fresh = log_tail(logfile, offset)
    position = 0
    for marker in (
        "Saving world data",
        "Validating world save",
        "Saving modded world data",
    ):
        found = fresh.find(marker, position)
        if found < 0:
            raise RuntimeError("container did not confirm a fresh, complete world save")
        position = found + len(marker)
    for path, modified in before.items():
        value = Path(path).stat(follow_symlinks=False)
        if (
            not stat.S_ISREG(value.st_mode)
            or value.st_size == 0
            or value.st_mtime_ns <= modified
        ):
            raise RuntimeError("container world save files did not advance")
    if exit_code != "0" or state.get("ExitCode") != 0 or state.get("OOMKilled", False):
        raise RuntimeError("container did not exit normally after saving")
    atomic_json(result, {"graceful": True})


def container_result(cfg, identifier):
    root()
    item = server(cfg, identifier)
    try:
        value = json.loads(
            run(
                cfg,
                "podman",
                "inspect",
                "--format",
                "{{json .State}}",
                item["container"],
            )
        )
        result = stop_result_path(cfg, identifier)
        confirmed = result.exists() and json.loads(result.read_text()).get(
            "graceful", False
        )
        ok = (
            confirmed
            and value.get("ExitCode") == 0
            and not value.get("OOMKilled", False)
        )
    except (subprocess.SubprocessError, ValueError):
        ok = False
    atomic_json(stop_result_path(cfg, identifier), {"graceful": ok})


def recovery_path(cfg, identifier):
    return Path(cfg["runDir"]) / identifier / "backup-recovery.json"


def recover(cfg, identifier):
    root()
    path = recovery_path(cfg, identifier)
    if not path.exists():
        return
    previous = json.loads(path.read_text())
    if previous["active"]:
        item = server(cfg, identifier)
        if item["wakeOnJoin"] and previous["running"]:
            # The Minecraft user owns this directory. Replace the marker
            # atomically so a planted symlink cannot make root touch its target.
            atomic_json(Path(cfg["runDir"]) / identifier / "wake-once", True)
        run(cfg, "systemctl", "start", item["unit"], timeout=330)
    path.unlink()


def backup_run(cfg, identifier):
    root()
    item = server(cfg, identifier)
    validate_repository(cfg)
    path = recovery_path(cfg, identifier)
    try:
        with lock(cfg, identifier):
            state = unit_state(cfg, item)
            active = state.get("ActiveState") in ("active", "activating", "reloading")
            atomic_json(
                path,
                {"active": active, "running": active and listening(item["serverPort"])},
            )
            if active:
                run(cfg, "systemctl", "stop", item["unit"], timeout=190)
                state = unit_state(cfg, item)
            if (
                state.get("ActiveState") != "inactive"
                or state.get("Result") != "success"
            ):
                raise RuntimeError("server did not stop cleanly; snapshot refused")
            require_saved(cfg, identifier)
            snapshot(cfg, identifier)
    finally:
        # Release the lock before starting: ExecStartPre takes the same lock.
        recover(cfg, identifier)


def prune(cfg):
    root()
    validate_repository(cfg)
    with lock(cfg, "repository-prune"):
        for identifier, item in cfg["servers"].items():
            if item["backup"]:
                print(
                    run(
                        cfg,
                        "restic",
                        "-r",
                        cfg["backup"]["repository"],
                        "-p",
                        cfg["backup"]["passwordFile"],
                        "forget",
                        "--retry-lock",
                        "30s",
                        "--tag",
                        "games:" + identifier,
                        "--group-by",
                        "tags",
                        "--keep-daily",
                        "7",
                        "--keep-weekly",
                        "4",
                        timeout=1700,
                    ),
                    end="",
                )
        print(
            run(
                cfg,
                "restic",
                "-r",
                cfg["backup"]["repository"],
                "-p",
                cfg["backup"]["passwordFile"],
                "prune",
                "--retry-lock",
                "30s",
                timeout=1700,
            ),
            end="",
        )


def console_root(cfg, identifier, command):
    root()
    item = server(cfg, identifier, proxy=True)
    if item["console"]["method"] == "container-inject":
        # Literal tmux input, never a shell string or a Docker/Podman option.
        run(
            cfg,
            "podman",
            "exec",
            "--",
            item["container"],
            "tmux",
            "send-keys",
            "-l",
            "--",
            command,
        )
        run(
            cfg, "podman", "exec", "--", item["container"], "tmux", "send-keys", "Enter"
        )
    elif item["console"]["method"] == "stdin":
        fd = os.open(
            item["console"]["path"], os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW
        )
        if not stat.S_ISFIFO(os.fstat(fd).st_mode):
            os.close(fd)
            raise ValueError("proxy console must be its fixed FIFO")
        with os.fdopen(fd, "w") as stream:
            stream.write(command + "\n")
    else:
        raise ValueError("this console does not require a privileged writer")


def main(argv):
    if len(argv) < 3 or argv[0] != "--inventory":
        raise ValueError("invalid internal invocation")
    cfg = json.loads(Path(argv[1]).read_text())
    action, args = argv[2], argv[3:]
    if action == "status":
        if len(args) > 1:
            raise ValueError("usage: games-status [server]")
        print(
            json.dumps(
                [status(cfg, identifier) for identifier in (args or cfg["servers"])]
            )
        )
    elif action == "logs":
        root()
        if len(args) not in (1, 2) or (len(args) == 2 and args[1] != "--follow"):
            raise ValueError("usage: games-logs server [--follow]")
        item = server(cfg, args[0], proxy=True)
        command = [
            cfg["commands"]["journalctl"],
            "--no-pager",
            "-n",
            "200",
            "-u",
            item["unit"],
        ]
        if item.get("backup"):
            command += ["-u", "restic-backups-games-" + args[0] + ".service"]
        if item.get("container"):
            # Podman emits container stdout with CONTAINER_NAME metadata,
            # possibly from its libpod scope rather than the launcher unit.
            command += ["+", "CONTAINER_NAME=" + item["container"]]
        if len(args) == 2:
            command.append("--follow")
        os.execv(command[0], command)
    elif action in ("console", "console-root"):
        if action == "console" and not args:
            raise ValueError("usage: games-console server 'one command'")
        writer = args.pop(0) if action == "console" else None
        if (
            len(args) != 2
            or not args[1]
            or len(args[1]) > 1024
            or any(c in args[1] for c in "\r\n\0")
        ):
            raise ValueError("usage: games-console server 'one command'")
        item = server(cfg, args[0], proxy=True)
        if action == "console-root":
            console_root(cfg, *args)
        elif item["console"]["method"] == "rcon":
            print(rcon(item, args[1]))
        else:
            os.execv("/run/wrappers/bin/sudo", ["sudo", "-n", writer, *args])
    elif action == "backup":
        if len(args) != 1:
            raise ValueError("usage: games-backup server")
        item = server(cfg, args[0])
        if not cfg["backup"]["enabled"] or not item["backup"] or not item["available"]:
            raise RuntimeError("backups are not enabled for this server")
        run(
            cfg,
            "systemctl",
            "start",
            "restic-backups-games-" + args[0] + ".service",
            timeout=2400,
        )
    elif action == "prune" and not args:
        prune(cfg)
    elif action == "paper-stop" and len(args) == 2:
        paper_stop(cfg, *args)
    elif (
        action
        in (
            "prepare",
            "prechange",
            "backup-run",
            "recover",
            "container-stop",
            "container-result",
        )
        and len(args) == 1
    ):
        functions = {
            "prepare": prepare,
            "prechange": prechange,
            "backup-run": backup_run,
            "recover": recover,
            "container-stop": container_stop,
            "container-result": container_result,
        }
        if action == "backup-run":

            def interrupted(_signal, _frame):
                raise RuntimeError("backup interrupted; recovering server")

            signal.signal(signal.SIGTERM, interrupted)
        functions[action](cfg, args[0])
    else:
        raise ValueError("invalid helper arguments")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Never print captured child output: it could contain credentials.
        print(str(error), file=sys.stderr)
        sys.exit(1)
