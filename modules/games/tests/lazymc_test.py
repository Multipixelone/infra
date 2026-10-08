"""Exercise real lazymc byte forwarding and child-exit proofs."""

import hashlib
import hmac
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def varint(value):
    result = bytearray()
    while True:
        byte = value & 127
        value >>= 7
        result.append(byte | (128 if value else 0))
        if not value:
            return bytes(result)


def exact(connection, count):
    result = b""
    while len(result) < count:
        data = connection.recv(count - len(result))
        if not data:
            raise EOFError()
        result += data
    return result


def number(connection):
    result = 0
    for shift in range(0, 35, 7):
        value = exact(connection, 1)[0]
        result |= (value & 127) << shift
        if not value & 128:
            return result
    raise ValueError("oversized protocol varint")


def packet(connection):
    return exact(connection, number(connection))


def frame(body):
    return varint(len(body)) + body


def string(value):
    data = value.encode()
    return varint(len(data)) + data


def handshake(port, next_state):
    # Floodgate's forwarding metadata must survive lazymc's handshake parse.
    host = "survival.mc.finnrut.is\0Floodgate-fixture\0bedrock-profile"
    return (
        b"\0"
        + varint(777)
        + string(host)
        + struct.pack(">H", port)
        + varint(next_state)
    )


UUID = bytes.fromhex("00112233445566778899aabbccddeeff")
LOGIN = b"\0" + string(".Fixture") + UUID
FORWARDING = varint(4) + string("198.51.100.10") + UUID + string(".Fixture") + varint(0)
FORWARDING = (
    hmac.new(b"fixture-forwarding-secret", FORWARDING, hashlib.sha256).digest()
    + FORWARDING
)
REQUEST = b"\x04" + varint(7) + string("velocity:player_info") + b"\x04"
RESPONSE = b"\x02" + varint(7) + b"\x01" + FORWARDING


def backend(port, directory):
    directory = Path(directory)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen()
    listener.settimeout(0.2)
    stopped = threading.Event()
    players = set()
    ignore_sigterm = (directory / "ignore-sigterm").exists()
    signal.signal(signal.SIGTERM, lambda *_: None if ignore_sigterm else stopped.set())
    signal.signal(signal.SIGINT, lambda *_: stopped.set())

    def client(connection):
        joined = False
        try:
            with connection:
                connection.settimeout(12)
                initial = packet(connection)
                if initial[-1] == 1:
                    packet(connection)
                    payload = json.dumps(
                        {
                            "version": {"name": "26.3", "protocol": 777},
                            "players": {"max": 20, "online": len(players)},
                            "description": "fixture",
                        }
                    )
                    connection.sendall(frame(b"\0" + string(payload)))
                    try:
                        ping = packet(connection)
                        connection.sendall(frame(ping))
                    except EOFError:
                        pass
                    return
                login = packet(connection)
                players.add(connection)
                joined = True
                connection.sendall(frame(REQUEST))
                response = packet(connection)
                # Record bytes for the parent to compare with what it sent.
                with (directory / "joins.jsonl").open("a") as stream:
                    stream.write(
                        json.dumps([initial.hex(), login.hex(), response.hex()]) + "\n"
                    )
                connection.sendall(frame(b"\x03fixture-accepted"))
                while not stopped.is_set():
                    if not connection.recv(1024):
                        break
        except (EOFError, OSError):
            pass
        finally:
            if joined:
                players.discard(connection)

    (directory / "started").touch()
    while not stopped.is_set():
        try:
            connection, _ = listener.accept()
            threading.Thread(target=client, args=(connection,), daemon=True).start()
        except TimeoutError:
            pass
    listener.close()
    (directory / "saved").write_text("graceful fixture shutdown")


def unused_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_for(predicate, message, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(message)


def ping_status(port, host="survival.mc.finnrut.is"):
    with socket.create_connection(("127.0.0.1", port), timeout=1) as connection:
        initial = b"\0" + varint(777) + string(host) + struct.pack(">H", port) + b"\x01"
        connection.sendall(frame(initial) + frame(b"\0"))
        response = packet(connection)
        offset = 1
        while response[offset] & 128:
            offset += 1
        result = json.loads(response[offset + 1 :])
        ping = b"\x01" + struct.pack(">q", 123456789)
        connection.sendall(frame(ping))
        assert packet(connection) == ping, "status ping was not echoed"
        return result


def velocity_status(velocity, directory, backend_port):
    """Default proxy pings, including forced hosts, never login to lazymc."""
    directory = directory / "velocity"
    directory.mkdir()
    port = unused_port()
    (directory / "forwarding.secret").write_text("fixture-forwarding-secret")
    (directory / "velocity.toml").write_text(f"""
config-version = "2.7"
bind = "127.0.0.1:{port}"
motd = "fixture proxy"
online-mode = false
player-info-forwarding-mode = "modern"
forwarding-secret-file = "forwarding.secret"
[servers]
survival = "127.0.0.1:{backend_port}"
try = ["survival"]
[forced-hosts]
"survival.mc.finnrut.is" = ["survival"]
""")
    with (directory / "velocity.log").open("w+") as output:
        process = subprocess.Popen(
            [velocity, "-Xms64M", "-Xmx256M"],
            cwd=directory,
            stdout=output,
            stderr=output,
            start_new_session=True,
        )
        try:

            def ready():
                try:
                    return ping_status(port)
                except (OSError, EOFError):
                    assert process.poll() is None, (
                        "Velocity exited before opening its listener"
                    )
                    return False

            wait_for(ready, "Velocity did not open its status listener")
            for host in ("127.0.0.1", "survival.mc.finnrut.is"):
                for _ in range(3):
                    response = ping_status(port, host)
                    assert "Velocity" in response["version"]["name"]
                    assert "fixture proxy" in json.dumps(response["description"])
        except BaseException:
            output.flush()
            print((directory / "velocity.log").read_text(), file=sys.stderr)
            raise
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)


def exercise(lazymc, velocity):
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        public, internal = unused_port(), unused_port()
        while internal == public:
            internal = unused_port()
        configuration = directory / "lazymc.toml"
        configuration.write_text(f'''
[config]
version = "0.2.11"
[public]
address = "127.0.0.1:{public}"
version = "26.3"
protocol = 777
[server]
address = "127.0.0.1:{internal}"
directory = "{directory}"
command = "{sys.executable} {Path(__file__).resolve()} --backend {internal} {directory}"
freeze_process = false
wake_on_start = false
probe_on_start = false
wake_whitelist = false
block_banned_ips = false
start_timeout = 10
stop_timeout = 5
[time]
sleep_after = 2
minimum_online_time = 1
[join]
methods = ["hold"]
[join.hold]
timeout = 8
[motd]
sleeping = "fixture sleeping"
[rcon]
enabled = false
[advanced]
rewrite_server_properties = false
''')
        (directory / "server.properties").write_text("online-mode=false\n")
        exit_marker = directory / "paper-exit.json"
        exit_marker.write_text("true\n")
        output = (directory / "lazymc.log").open("w+")
        process = subprocess.Popen(
            [lazymc, "--config", str(configuration)],
            stdout=output,
            stderr=output,
            start_new_session=True,
            env={**os.environ, "GAMES_PAPER_EXIT_FILE": str(exit_marker)},
        )
        try:

            def status():
                try:
                    with socket.create_connection(
                        ("127.0.0.1", public), timeout=1
                    ) as connection:
                        connection.sendall(frame(handshake(public, 1)) + frame(b"\0"))
                        response = packet(connection)
                        offset = 1
                        while response[offset] & 128:
                            offset += 1
                        return json.loads(response[offset + 1 :])
                except (OSError, EOFError):
                    return False

            wait_for(status, "lazymc did not open its sleeping listener")
            for _ in range(5):
                assert ping_status(public)["description"] == "fixture sleeping"
            velocity_status(velocity, directory, public)
            assert not (directory / "started").exists(), (
                "direct or Velocity status polling woke the backend"
            )
            assert json.loads(exit_marker.read_text()) is True, (
                "sleeping status polling changed the prior clean-exit proof"
            )

            def join():
                connection = socket.create_connection(("127.0.0.1", public), timeout=2)
                connection.settimeout(12)
                connection.sendall(frame(handshake(public, 2)) + frame(LOGIN))
                assert packet(connection) == REQUEST, (
                    "modern forwarding request changed"
                )
                connection.sendall(frame(RESPONSE))
                assert packet(connection) == b"\x03fixture-accepted", (
                    "forwarding response was lost"
                )
                return connection

            # First join takes the cold hold path; second takes direct warm proxy.
            cold = join()
            assert json.loads(exit_marker.read_text()) is False, (
                "spawn did not clear the prior clean-exit proof"
            )
            assert exit_marker.stat().st_mode & 0o777 == 0o600
            warm = join()
            cold.close()
            warm.close()
            joins = [
                json.loads(line)
                for line in (directory / "joins.jsonl").read_text().splitlines()
            ]
            assert (
                joins == [[handshake(public, 2).hex(), LOGIN.hex(), RESPONSE.hex()]] * 2
            )
            wait_for(
                lambda: (directory / "saved").exists(),
                "empty backend did not stop gracefully",
            )
            assert process.poll() is None and status(), (
                "sleep stopped the lazymc listener"
            )
            # A completed save precedes child exit and lazymc's stop cooldown.
            # Wait for its state transition before submitting a fresh login.
            wait_for(
                lambda: (status() or {}).get("description") == "fixture sleeping",
                "lazymc did not return to its sleeping state",
            )
            assert json.loads(exit_marker.read_text()) is True, (
                "graceful idle exit did not record a clean-exit proof"
            )
            (directory / "started").unlink()
            (directory / "saved").unlink()
            # The next child ignores the graceful stop signal. lazymc eventually
            # kills it and sleeps; that sleeping state must retain a false proof.
            (directory / "ignore-sigterm").touch()
            revived = join()
            assert (directory / "started").exists(), (
                "join did not wake the sleeping backend again"
            )
            assert json.loads(exit_marker.read_text()) is False, (
                "re-wake did not clear the previous clean-exit proof"
            )
            revived.close()
            wait_for(
                lambda: (status() or {}).get("description") == "fixture sleeping",
                "forced idle stop did not return to its sleeping state",
            )
            assert process.poll() is None and not (directory / "saved").exists(), (
                "forced idle stop unexpectedly saved or stopped the listener"
            )
            assert json.loads(exit_marker.read_text()) is False, (
                "forced idle SIGKILL incorrectly recorded a clean-exit proof"
            )
            print(
                "Velocity forced-host and direct lazymc status pings never wake Paper; cold/warm forwarding, clean idle proof, re-wake reset, and forced-idle failure proof passed"
            )
        except BaseException:
            output.flush()
            print((directory / "lazymc.log").read_text(), file=sys.stderr)
            raise
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
            output.close()


if __name__ == "__main__":
    if sys.argv[1] == "--backend":
        backend(int(sys.argv[2]), sys.argv[3])
    else:
        exercise(sys.argv[1], sys.argv[2])
