"""Schema-v1 models, checked against the Nix-generated manifest."""

import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class Endpoint(StrictModel):
    hostname: str
    port: int
    protocol: str
    edition: str | None


class RconConsole(StrictModel):
    method: Literal["rcon"]
    command: list[str]
    host: str
    port: int
    passwordFile: str


class ContainerConsole(StrictModel):
    method: Literal["container-inject"]
    command: list[str]


class Backup(StrictModel):
    enabled: bool
    unit: str
    command: list[str]


class Server(StrictModel):
    id: str
    game: str
    displayName: str
    public: list[Endpoint]
    unit: str
    container: str | None
    dataDir: str
    worldPaths: list[str]
    wakeOnJoin: bool
    available: bool
    console: Annotated[RconConsole | ContainerConsole, Field(discriminator="method")]
    backup: Backup
    statusCommand: list[str]
    logsCommand: list[str]

    @model_validator(mode="after")
    def fixed_commands(self):
        if not re.fullmatch(r"[a-z][a-z0-9_]*", self.id):
            raise ValueError("invalid server ID")
        if not re.fullmatch(r"[a-zA-Z0-9_.@-]+\.service", self.unit):
            raise ValueError("invalid server unit")
        commands = (
            (self.statusCommand, "games-status"),
            (self.logsCommand, "games-logs"),
            (self.backup.command, "games-backup"),
            (self.console.command, "games-console"),
        )
        if any(argv != [helper, self.id] for argv, helper in commands):
            raise ValueError("manifest helper argv does not match server ID")
        return self


class SharedService(StrictModel):
    id: str
    unit: str
    available: bool
    logsCommand: list[str]


class Manifest(StrictModel):
    schemaVersion: Literal[1]
    host: str
    sharedServices: list[SharedService]
    servers: list[Server]

    @model_validator(mode="after")
    def unique_ids(self):
        ids = [server.id for server in self.servers]
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate server IDs")
        return self


class Status(StrictModel):
    id: str
    state: Literal["running", "sleeping", "stopped"]
    unitState: str | None
    ready: bool
    playersOnline: int | None
    available: bool
