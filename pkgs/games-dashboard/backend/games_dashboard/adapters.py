"""Mock state and a thin, fixed-argv adapter to the installed game helpers."""

import asyncio
import contextlib
import json
import os
import signal
from collections import deque
from datetime import datetime, timezone

from .models import Manifest, Status

ACTIONS = frozenset({"start", "stop", "restart", "backup"})


class UnknownServer(Exception):
    pass


class Unavailable(Exception):
    pass


class HelperFailure(Exception):
    pass


def log_entry(identifier, line):
    return {
        "id": identifier,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "line": line,
    }


async def terminate(process):
    """Stop the helper and its descendants, then reap it."""
    if process.returncode is None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            await asyncio.wait_for(process.wait(), 3)
        except TimeoutError:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            await process.wait()


class Runner:
    async def spawn(self, argv):
        try:
            return await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as error:
            raise HelperFailure("game helper could not start") from error

    async def run(self, argv, timeout):
        process = await self.spawn(argv)
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(), timeout)
            if process.returncode:
                raise HelperFailure("game helper failed")
            return stdout
        except TimeoutError as error:
            raise HelperFailure("game helper timed out") from error
        finally:
            await terminate(process)

    async def lines(self, argv):
        process = await self.spawn(argv)
        try:
            while line := await process.stdout.readline():
                yield line.decode(errors="replace").rstrip("\r\n")
            if await process.wait():
                raise HelperFailure("log helper failed")
        except ValueError as error:
            raise HelperFailure("log line exceeds stream limit") from error
        finally:
            await terminate(process)


class Adapter:
    def __init__(self, manifest: Manifest):
        self.manifest = manifest
        self.servers = {server.id: server for server in manifest.servers}
        self.locks = {identifier: asyncio.Lock() for identifier in self.servers}

    def server(self, identifier):
        try:
            return self.servers[identifier]
        except KeyError as error:
            raise UnknownServer("unknown game server") from error

    def require_action(self, identifier, action):
        server = self.server(identifier)
        if action not in ACTIONS:
            raise ValueError("unknown action")
        if not server.available:
            raise Unavailable("server prerequisites are unavailable")
        if action == "backup" and not server.backup.enabled:
            raise Unavailable("backups are disabled for this server")
        return server


class MockAdapter(Adapter):
    def __init__(self, manifest):
        super().__init__(manifest)
        self.state = {
            server.id: self.make_status(
                server, "running" if server.wakeOnJoin else "stopped"
            )
            for server in manifest.servers
        }
        self.backups = {identifier: 0 for identifier in self.servers}
        self.logs = deque(maxlen=200)
        self.sequence = 0

    @staticmethod
    def make_status(server, state):
        return Status(
            id=server.id,
            state=state,
            unitState="inactive" if state == "stopped" else "active",
            ready=state == "running",
            playersOnline=(
                0
                if state == "sleeping"
                else 2
                if state == "running" and server.console.method == "rcon"
                else None
            ),
            available=server.available,
        )

    def append_log(self, identifier, line):
        self.sequence += 1
        self.logs.append((self.sequence, log_entry(identifier, line)))

    async def statuses(self):
        return list(self.state.values())

    async def action(self, identifier, action):
        server = self.require_action(identifier, action)
        async with self.locks[identifier]:
            if action == "backup":
                self.backups[identifier] += 1
                self.append_log(
                    identifier, f"Mock backup #{self.backups[identifier]} completed"
                )
            else:
                state = (
                    "stopped"
                    if action == "stop"
                    else "sleeping"
                    if server.wakeOnJoin
                    else "running"
                )
                self.state[identifier] = self.make_status(server, state)
                self.append_log(identifier, f"Mock {action}: {state}")
            return self.state[identifier]

    async def events(self, identifier):
        self.server(identifier)
        cursor = 0
        yield log_entry(identifier, "Mock console connected")
        while True:
            for sequence, entry in list(self.logs):
                if sequence > cursor and entry["id"] == identifier:
                    yield entry
                cursor = max(cursor, sequence)
            await asyncio.sleep(1)
            yield log_entry(identifier, f"Mock console: {self.state[identifier].state}")


class RealAdapter(Adapter):
    def __init__(self, manifest, runner=None):
        super().__init__(manifest)
        self.runner = runner or Runner()

    async def statuses(self):
        try:
            data = json.loads(await self.runner.run(["games-status"], timeout=60))
            statuses = [Status.model_validate(item) for item in data]
            if {item.id for item in statuses} != set(self.servers) or len(
                statuses
            ) != len(self.servers):
                raise ValueError("status inventory mismatch")
            return statuses
        except (ValueError, TypeError) as error:
            raise HelperFailure("invalid status helper response") from error

    async def action(self, identifier, action):
        server = self.require_action(identifier, action)
        async with self.locks[identifier]:
            argv = (
                ["games-backup", identifier]
                if action == "backup"
                else ["systemctl", action, "--", server.unit]
            )
            # Terraria startup and backups may take 40 minutes in the real units.
            await self.runner.run(argv, timeout=2460)
            statuses = await self.statuses()
            return next(item for item in statuses if item.id == identifier)

    async def events(self, identifier):
        self.server(identifier)
        async with contextlib.aclosing(
            self.runner.lines(["games-logs", identifier, "--follow"])
        ) as lines:
            async for line in lines:
                yield log_entry(identifier, line)
