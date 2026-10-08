"""Read-only game telemetry. Network queries never target a sleeping proxy."""

import argparse
import hashlib
import json
import os
import re
import socket
import stat
import struct
import subprocess
import tempfile
import time
from pathlib import Path

HELP = {
    "games_server_enabled": "Whether the server is effectively enabled with required credentials present.",
    "games_server_disabled": "One-hot reason for a disabled server.",
    "games_server_state": "One-hot workload state; a failed Paper child is stopped rather than sleeping.",
    "games_server_ready": "Whether the enabled workload is ready to accept connections.",
    "games_server_failed": "Whether a systemd failure or unclean Paper child exit is confirmed.",
    "games_players_online": "Online players; Terraria is a journal-derived estimate.",
    "games_players_known": "Whether the current player count is known.",
    "games_player_capacity": "Configured enforced maximum player count.",
    "games_server_start_time_seconds": "Unix start time of the workload process or container.",
    "games_player_events_total": "Observed player join and leave journal events.",
    "games_lazymc_events_total": "Observed lazymc online and sleeping journal transitions.",
    "games_metrics_collection_success": "Whether core state telemetry was collected for this server.",
    "games_journal_collection_success": "Whether game journals were read without an observed cursor gap.",
    "games_metrics_last_update_timestamp_seconds": "Unix time of the last published collection.",
    "games_cpu_seconds_total": "Cumulative cgroup CPU usage in seconds.",
    "games_memory_current_bytes": "Current cgroup memory use in bytes.",
    "games_memory_limit_bytes": "Configured effective cgroup memory limit in bytes.",
    "games_io_read_bytes_total": "Cumulative cgroup bytes read across devices.",
    "games_io_write_bytes_total": "Cumulative cgroup bytes written across devices.",
    "games_resource_collection_success": "Whether cgroup resource telemetry is available for this scope.",
    "games_backup_configured": "Whether world backups are effectively configured; zero is not a failure.",
    "games_backup_in_progress": "Whether the world backup unit is active.",
    "games_backup_failed": "Whether the latest completed backup attempt failed, including recovery.",
    "games_backup_enabled_timestamp_seconds": "Unix time of the start of the current backup-enabled period.",
    "games_backup_last_success_timestamp_seconds": "Unix time of the last successful world snapshot, or zero.",
    "games_backup_last_duration_seconds": "Duration of the last successful complete backup run in seconds.",
    "games_backup_last_size_bytes": "Total world bytes processed by the last successful restic snapshot.",
}


def atomic(path, value, mode=0o600):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix=".games-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def load(path, default):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def exit_proof(path):
    """The game-writable proof is a bounded regular file, never a symlink."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 128:
                return None
            value = json.loads(stream.read(128))
            return value if type(value) is bool else None
    except (OSError, ValueError):
        return None


def command(inventory, tool, *args, timeout=10):
    return subprocess.run(
        [inventory["commands"][tool], *map(str, args)],
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout,
    ).stdout


class Metrics:
    def __init__(self):
        self.samples = []
        self.types = {}

    def add(self, name, labels, value, kind="gauge"):
        if value is None:
            return
        self.types[name] = kind
        label_text = ",".join(
            f"{key}={json.dumps(str(value))}" for key, value in sorted(labels.items())
        )
        self.samples.append(f"{name}{{{label_text}}} {float(value):.17g}\n")

    def render(self):
        return "".join(
            f"# HELP {name} {HELP[name]}\n# TYPE {name} {kind}\n"
            for name, kind in sorted(self.types.items())
        ) + "".join(self.samples)


def varint(value):
    encoded = bytearray()
    while value >= 128:
        encoded.append((value & 127) | 128)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def read_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        part = connection.recv(size - len(result))
        if not part:
            raise ValueError("short Minecraft status packet")
        result.extend(part)
    return bytes(result)


def read_varint(connection):
    result = 0
    for index in range(5):
        byte = read_exact(connection, 1)[0]
        result |= (byte & 127) << (index * 7)
        if byte < 128:
            return result
    raise ValueError("oversized Minecraft varint")


def minecraft_players(port):
    """Only called for awake direct Paper ports or ping-isolated Velocity."""
    with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
        connection.settimeout(2)
        handshake = (
            b"\x00" + varint(777) + b"\x09localhost" + struct.pack(">H", port) + b"\x01"
        )
        connection.sendall(varint(len(handshake)) + handshake + b"\x01\x00")
        length = read_varint(connection)
        if not 2 <= length <= 65536:
            raise ValueError("invalid Minecraft packet size")
        packet = read_exact(connection, length)
        if packet[0] != 0:
            raise ValueError("unexpected Minecraft status packet")
        # Decode the JSON string's VarInt inside the already bounded packet.
        size, offset = 0, 1
        for index in range(5):
            byte = packet[offset]
            offset += 1
            size |= (byte & 127) << (7 * index)
            if byte < 128:
                break
        else:
            raise ValueError("oversized Minecraft string")
        if size != len(packet) - offset:
            raise ValueError("invalid Minecraft JSON length")
        response = json.loads(packet[offset:])
        if not isinstance(response, dict) or not isinstance(
            response.get("players"), dict
        ):
            # Malformed wire data is a protocol error, not a caller type error.
            raise ValueError("invalid Minecraft status object")  # noqa: TRY004
        players = response["players"].get("online")
        if type(players) is not int or players < 0:
            raise ValueError("invalid player count")
        return players


def cgroup_path(root, relative):
    if not relative or ".." in Path(relative).parts:
        raise ValueError("invalid cgroup path")
    path = (Path(root) / relative.lstrip("/")).resolve()
    if not path.is_relative_to(Path(root).resolve()):
        raise ValueError("cgroup escapes root")
    return path


def cgroup(root, relative):
    path = cgroup_path(root, relative)
    cpu = dict(line.split() for line in (path / "cpu.stat").read_text().splitlines())
    result = {
        "cpu": int(cpu["usage_usec"]) / 1e6,
        "memory": int((path / "memory.current").read_text()),
    }
    io = path / "io.stat"
    if io.exists():
        result.update(read=0, write=0)
        for line in io.read_text().splitlines():
            fields = dict(field.split("=", 1) for field in line.split()[1:])
            result["read"] += int(fields.get("rbytes", 0))
            result["write"] += int(fields.get("wbytes", 0))
    return result


def distinct_cgroups(paths):
    return [
        path
        for path in set(paths)
        if not any(
            path != other and Path(path).is_relative_to(Path(other)) for other in paths
        )
    ]


def resource_samples(metrics, labels, values, limit=None):
    metrics.add("games_resource_collection_success", labels, 1)
    for field, name, kind in (
        ("cpu", "games_cpu_seconds_total", "counter"),
        ("memory", "games_memory_current_bytes", "gauge"),
        ("read", "games_io_read_bytes_total", "counter"),
        ("write", "games_io_write_bytes_total", "counter"),
    ):
        metrics.add(name, labels, values.get(field), kind)
    metrics.add("games_memory_limit_bytes", labels, limit)


def journal_entry(item, entry):
    if item.get("container") and entry.get("CONTAINER_NAME"):
        return entry["CONTAINER_NAME"] == item["container"]
    return entry.get("_SYSTEMD_UNIT") == item["unit"] and not entry.get(
        "CONTAINER_NAME"
    )


def process_journal(item, entries, state, patterns, invocation):
    """Counters survive invocations; player membership requires complete history."""
    if state.get("invocation") != invocation:
        state.update(invocation=invocation, players=[], playersKnown=False)
    counters = state.setdefault("events", {})
    for entry in entries:
        if not journal_entry(item, entry):
            continue
        entry_invocation = (
            entry.get("CONTAINER_ID_FULL")
            if item.get("container")
            else entry.get("_SYSTEMD_INVOCATION_ID")
        )
        message = entry.get("MESSAGE", "")
        if not isinstance(message, str):
            continue
        message = re.sub(r"\x1b\[[0-9;]*m", "", message)
        # Terraria's complete startup establishes an empty membership baseline.
        if (
            item["game"] == "terraria-tmodloader"
            and entry_invocation == invocation
            and re.search(
                r"(?:^|\]:? )(?:Server started\.?|Listening on port [0-9]+)$", message
            )
        ):
            state.update(players=[], playersKnown=True)
        for event, pattern in patterns.get(item["game"], {}).items():
            match = re.search(pattern, message)
            if not match:
                continue
            if event in ("join", "leave", "sleep", "wake"):
                counters[event] = counters.get(event, 0) + 1
            if event in ("join", "leave") and entry_invocation == invocation:
                # Persist no names, IPs, or messages; hashes only deduplicate membership.
                player = hashlib.sha256(match["player"].encode()).hexdigest()
                players = set(state["players"])
                if event == "join":
                    players.add(player)
                elif player in players:
                    players.remove(player)
                else:
                    state["playersKnown"] = False
                state["players"] = sorted(players)
            break


def collect(inventory, persisted, now=None):
    now = time.time() if now is None else now
    metrics = Metrics()
    host = inventory["host"]
    items = inventory["servers"]
    states = persisted.setdefault("servers", {})
    entries, journal_ok = [], True
    try:
        args = ["--no-pager", "--output=json"]
        if persisted.get("cursor") and not persisted.get("journalGap"):
            args += ["--after-cursor=" + persisted["cursor"]]
        elif persisted.get("journalTimestamp"):
            args += ["--since=@" + str(persisted["journalTimestamp"] / 1e6)]
        else:
            args += ["--since=-12h"]
        # A single OR filter avoids ingesting the same container line twice.
        matches = []
        for item in items.values():
            if matches:
                matches.append("+")
            matches.append("_SYSTEMD_UNIT=" + item["unit"])
            if item.get("container"):
                matches += ["+", "CONTAINER_NAME=" + item["container"]]
        if matches:
            entries = [
                json.loads(line)
                for line in command(
                    inventory, "journalctl", *args, *matches
                ).splitlines()
            ]
            if persisted.get("journalGap"):
                entries = [
                    entry
                    for entry in entries
                    if int(entry.get("__REALTIME_TIMESTAMP", 0))
                    > persisted.get("journalTimestamp", 0)
                ]
            if entries:
                persisted["cursor"] = entries[-1]["__CURSOR"]
                persisted["journalTimestamp"] = int(entries[-1]["__REALTIME_TIMESTAMP"])
            persisted["journalGap"] = False
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        journal_ok = False
        # Do not silently resume a player baseline after a journal cursor gap.
        persisted["journalGap"] = True
        for state in states.values():
            state["playersKnown"] = False
    for identifier, item in items.items():
        labels = {
            "host": host,
            "server_id": identifier,
            "game": item["game"],
            "unit": item["unit"],
        }
        state = states.setdefault(identifier, {})
        enabled = (
            item["enabled"]
            and item["available"]
            and all(Path(path).is_file() for path in item["secretPaths"])
        )
        metrics.add("games_server_enabled", labels, enabled)
        for reason in ("operator-disabled", "missing-secrets"):
            disabled_reason = (
                "operator-disabled" if not item["enabled"] else "missing-secrets"
            )
            metrics.add(
                "games_server_disabled",
                labels | {"reason": reason},
                not enabled and reason == disabled_reason,
            )
        value, ready, failed, players, success, show = (
            "disabled",
            False,
            False,
            None,
            True,
            {},
        )
        container = None
        if enabled:
            try:
                output = command(
                    inventory,
                    "systemctl",
                    "show",
                    item["unit"],
                    "--property=ActiveState,Result,MainPID,ControlGroup,InvocationID",
                )
                show = dict(
                    line.split("=", 1) for line in output.splitlines() if "=" in line
                )
                if "ActiveState" not in show:
                    raise ValueError("missing unit state")
                active = show["ActiveState"] in ("active", "activating", "reloading")
                failed = show["ActiveState"] == "failed" or show.get(
                    "Result", "success"
                ) not in ("success", "")
                value = "running" if active else "stopped"
                if item["game"] != "minecraft-velocity":
                    statuses = json.loads(
                        command(inventory, "status", "--no-query", identifier)
                    )
                    if (
                        not isinstance(statuses, list)
                        or not statuses
                        or not isinstance(statuses[0], dict)
                    ):
                        raise ValueError("invalid games-status object")
                    status = statuses[0]
                    if status["id"] != identifier or status["state"] not in (
                        "running",
                        "sleeping",
                        "stopped",
                    ):
                        raise ValueError("invalid games-status")
                    value, ready = status["state"], status["ready"]
                    if item["wakeOnJoin"] and value == "sleeping":
                        proof = exit_proof(item["childExitFile"])
                        if proof is False:
                            failed, value = True, "stopped"
                        elif proof is not True and state.get("launched"):
                            success = False
                        else:
                            players = 0
                    if item["wakeOnJoin"] and ready:
                        state["launched"] = True
                if (
                    active
                    and (ready or item["game"] == "minecraft-velocity")
                    and item["game"].startswith("minecraft-")
                ):
                    try:
                        players = minecraft_players(item["serverPort"])
                        ready = True
                    except (OSError, ValueError, KeyError, IndexError):
                        if item["game"] == "minecraft-velocity":
                            ready = False
            except (
                OSError,
                subprocess.SubprocessError,
                ValueError,
                KeyError,
                IndexError,
            ):
                success = False
                value, ready, failed = "stopped", False, False
        if enabled and item.get("container") and value == "running":
            try:
                container = json.loads(
                    command(inventory, "podman", "inspect", item["container"])
                )[0]
            except (
                OSError,
                subprocess.SubprocessError,
                ValueError,
                KeyError,
                IndexError,
            ):
                metrics.add(
                    "games_resource_collection_success",
                    labels | {"scope": "container", "container": item["container"]},
                    0,
                )
        invocation = (
            container.get("Id", "") if container else show.get("InvocationID", "")
        )
        if journal_ok:
            process_journal(item, entries, state, inventory["patterns"], invocation)
        if (
            item["game"] == "terraria-tmodloader"
            and enabled
            and ready
            and state.get("playersKnown")
            and journal_ok
        ):
            players = len(state["players"])
        metrics.add("games_metrics_collection_success", labels, success)
        metrics.add("games_journal_collection_success", labels, journal_ok)
        for candidate in ("running", "sleeping", "stopped", "disabled"):
            metrics.add(
                "games_server_state", labels | {"state": candidate}, candidate == value
            )
        metrics.add("games_server_failed", labels, failed)
        metrics.add("games_server_ready", labels, ready and enabled)
        metrics.add("games_players_known", labels, players is not None)
        metrics.add(
            "games_players_online",
            labels | {"source": "journal" if item.get("container") else "status"},
            players,
        )
        metrics.add("games_player_capacity", labels, item.get("capacity"))
        for event in ("join", "leave"):
            metrics.add(
                "games_player_events_total",
                labels | {"event": event},
                state.get("events", {}).get(event, 0),
                "counter",
            )
        if item["wakeOnJoin"]:
            for event in ("sleep", "wake"):
                metrics.add(
                    "games_lazymc_events_total",
                    labels | {"event": event},
                    state.get("events", {}).get(event, 0),
                    "counter",
                )
        paths = []
        container_path = None
        if enabled and show.get("ControlGroup"):
            paths.append(show["ControlGroup"])
        if container:
            try:
                pid = int(container["State"]["Pid"])
                if pid <= 0:
                    raise ValueError("container has no workload PID")
                proc = Path(inventory.get("procRoot", "/proc")) / str(pid)
                container_path = next(
                    line[3:]
                    for line in (proc / "cgroup").read_text().splitlines()
                    if line.startswith("0::")
                )
                paths.append(container_path)
                resource_samples(
                    metrics,
                    labels | {"scope": "container", "container": item["container"]},
                    cgroup(inventory["cgroupRoot"], container_path),
                    item["memoryBytes"],
                )
            except (OSError, ValueError, KeyError, StopIteration):
                metrics.add(
                    "games_resource_collection_success",
                    labels | {"scope": "container", "container": item["container"]},
                    0,
                )
            try:
                from datetime import datetime

                metrics.add(
                    "games_server_start_time_seconds",
                    labels,
                    datetime.fromisoformat(
                        container["State"]["StartedAt"].replace("Z", "+00:00")
                    ).timestamp(),
                )
            except (ValueError, KeyError):
                pass
        elif enabled and value == "running":
            try:
                pid = int(show.get("MainPID", "0"))
                if item["wakeOnJoin"]:
                    children = []
                    for path in (
                        Path(inventory.get("procRoot", "/proc")) / str(pid) / "task"
                    ).glob("*/children"):
                        children += path.read_text().split()
                    pid = int(children[0]) if children else 0
                proc_root = Path(inventory.get("procRoot", "/proc"))
                stat_fields = (
                    (proc_root / str(pid) / "stat")
                    .read_text()
                    .rsplit(")", 1)[1]
                    .split()
                )
                boot = next(
                    int(line.split()[1])
                    for line in (proc_root / "stat").read_text().splitlines()
                    if line.startswith("btime ")
                )
                metrics.add(
                    "games_server_start_time_seconds",
                    labels,
                    boot + int(stat_fields[19]) / os.sysconf("SC_CLK_TCK"),
                )
            except (OSError, ValueError, IndexError, StopIteration):
                pass
        try:
            if item.get("container") and value == "running" and container_path is None:
                raise ValueError(
                    "container cgroup unavailable; launcher is not the workload"
                )
            if paths:
                snapshots = [
                    cgroup(inventory["cgroupRoot"], path)
                    for path in distinct_cgroups(paths)
                ]
                totals = {
                    key: sum(value[key] for value in snapshots)
                    for key in snapshots[0]
                    if all(key in value for value in snapshots)
                }
                resource_samples(
                    metrics, labels | {"scope": "server"}, totals, item["memoryBytes"]
                )
            elif not enabled or value in ("stopped", "disabled"):
                resource_samples(
                    metrics,
                    labels | {"scope": "server"},
                    {"memory": 0},
                    item["memoryBytes"],
                )
            else:
                metrics.add(
                    "games_resource_collection_success", labels | {"scope": "server"}, 0
                )
        except (OSError, ValueError, KeyError):
            metrics.add(
                "games_resource_collection_success", labels | {"scope": "server"}, 0
            )
        if identifier != "velocity":
            backup_labels = labels | {
                "unit": "restic-backups-games-" + identifier + ".service"
            }
            configured = (
                enabled
                and item["backupEnabled"]
                and Path(inventory["backupPasswordPath"]).is_file()
            )
            if configured and not state.get("backupConfigured"):
                state["backupEnabledSince"] = now
            state["backupConfigured"] = configured
            metadata = load(
                Path(inventory["backupStateDir"]) / (identifier + "-backup.json"), {}
            )
            in_progress, unit_failed = False, False
            if configured:
                try:
                    backup_show = dict(
                        line.split("=", 1)
                        for line in command(
                            inventory,
                            "systemctl",
                            "show",
                            backup_labels["unit"],
                            "--property=ActiveState,Result",
                        ).splitlines()
                        if "=" in line
                    )
                    in_progress = backup_show.get("ActiveState") in (
                        "active",
                        "activating",
                        "deactivating",
                    )
                    unit_failed = backup_show.get(
                        "ActiveState"
                    ) == "failed" or backup_show.get("Result", "success") not in (
                        "",
                        "success",
                    )
                except (OSError, subprocess.SubprocessError):
                    pass
            for name, number in (
                ("configured", configured),
                ("in_progress", in_progress),
                ("failed", metadata.get("failed", False) or unit_failed),
                ("enabled_timestamp_seconds", state.get("backupEnabledSince", 0)),
                ("last_success_timestamp_seconds", metadata.get("lastSuccess", 0)),
                ("last_duration_seconds", metadata.get("lastDuration", 0)),
                ("last_size_bytes", metadata.get("lastSize", 0)),
            ):
                metrics.add("games_backup_" + name, backup_labels, number)
    try:
        resource_samples(
            metrics,
            {
                "host": host,
                "server_id": "all",
                "game": "all",
                "unit": "games.slice",
                "scope": "slice",
            },
            cgroup(inventory["cgroupRoot"], "/games.slice"),
        )
    except (OSError, ValueError, KeyError):
        metrics.add(
            "games_resource_collection_success",
            {
                "host": host,
                "server_id": "all",
                "game": "all",
                "unit": "games.slice",
                "scope": "slice",
            },
            0,
        )
    metrics.add("games_metrics_last_update_timestamp_seconds", {"host": host}, now)
    return metrics.render()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        inventory = load(args.inventory, {})
        persisted = load(args.state, {})
        result = collect(inventory, persisted)
        # Cursor/counters form one transaction; a failed textfile write is replay-safe.
        atomic(args.state, json.dumps(persisted) + "\n")
        atomic(args.output, result, 0o644)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        # Never emit raw subprocess stderr or configuration/secret values.
        raise SystemExit("game telemetry collection failed; previous snapshot retained")


if __name__ == "__main__":
    main()
