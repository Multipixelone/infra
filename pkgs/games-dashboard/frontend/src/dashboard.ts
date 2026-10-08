export type Action = "start" | "stop" | "restart" | "backup";

export type ServerStatus = {
  id: string;
  state: "running" | "sleeping" | "stopped";
  unitState: string | null;
  ready: boolean;
  playersOnline: number | null;
  available: boolean;
};

export type Endpoint = {
  hostname: string;
  port: number;
  protocol: string;
  edition: string | null;
};

export type Server = {
  id: string;
  game: string;
  displayName: string;
  public: Endpoint[];
  unit: string;
  container: string | null;
  dataDir: string;
  worldPaths: string[];
  wakeOnJoin: boolean;
  available: boolean;
  backup: { enabled: boolean; unit: string; command: string[] };
  status: ServerStatus;
};

export type Manifest = {
  schemaVersion: 1;
  host: string;
  sharedServices: {
    id: string;
    unit: string;
    available: boolean;
    logsCommand: string[];
  }[];
  servers: Server[];
};

export type LogEntry = { id: string; timestamp: string; line: string };

export function gameLabel(server: Server): string {
  if (server.game === "minecraft-paper") return "Minecraft · Paper";
  if (server.game === "terraria-tmodloader") return "Terraria · tModLoader";
  return server.game;
}

export function stateLabel(server: Server): string {
  if (!server.available || !server.status.available) return "Unavailable";
  if (server.status.unitState === "failed") return "Failed";
  if (server.status.state === "running") {
    return server.status.ready ? "Running" : "Starting";
  }
  return server.status.state === "sleeping" ? "Sleeping" : "Stopped";
}

export function stateTone(
  server: Server,
): "good" | "warm" | "muted" | "danger" {
  const label = stateLabel(server);
  if (label === "Unavailable" || label === "Failed") return "danger";
  if (label === "Running") return "good";
  if (label === "Sleeping" || label === "Starting") return "warm";
  return "muted";
}

export function stateDescription(server: Server): string {
  switch (stateLabel(server)) {
    case "Unavailable":
      return "Missing required configuration.";
    case "Failed":
      return "Service failed. Check logs.";
    case "Starting":
      return "Waiting for the game port.";
    case "Running":
      return "The game is running and its connection port is ready.";
    case "Sleeping":
      return "Wake-on-join is enabled. A player joining starts the game.";
    default:
      return server.wakeOnJoin
        ? "The server is stopped and wake-on-join is disabled."
        : "The server is stopped. Start it to accept connections.";
  }
}

export function actionLabel(action: Action, server?: Server): string {
  switch (action) {
    case "start":
      return server?.wakeOnJoin ? "Enable wake-on-join" : "Start server";
    case "stop":
      return "Stop server";
    case "restart":
      return "Restart";
    case "backup":
      return "Back up now";
  }
}

function invalid(field: string): never {
  throw new Error(`Invalid server manifest: ${field}.`);
}

function record(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return invalid(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, field: string): string {
  if (typeof value !== "string") return invalid(`${field} must be a string`);
  return value;
}

function nullableString(value: unknown, field: string): string | null {
  return value === null ? null : string(value, field);
}

function boolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") return invalid(`${field} must be a boolean`);
  return value;
}

function array(value: unknown, field: string): unknown[] {
  if (!Array.isArray(value)) return invalid(`${field} must be an array`);
  return value;
}

function strings(value: unknown, field: string): string[] {
  return array(value, field).map((entry, index) =>
    string(entry, `${field}[${index}]`),
  );
}

export function parseStatus(value: unknown, serverId: string): ServerStatus {
  const status = record(value, "status");
  const id = string(status.id, "status.id");
  if (id !== serverId) return invalid("status ID does not match its server");
  const state = status.state;
  if (state !== "running" && state !== "sleeping" && state !== "stopped") {
    return invalid("status.state is not supported");
  }
  const playersOnline = status.playersOnline;
  if (
    playersOnline !== null &&
    (typeof playersOnline !== "number" ||
      !Number.isInteger(playersOnline) ||
      playersOnline < 0)
  ) {
    return invalid(
      "status.playersOnline must be a nonnegative integer or null",
    );
  }
  return {
    id,
    state,
    unitState: nullableString(status.unitState, "status.unitState"),
    ready: boolean(status.ready, "status.ready"),
    playersOnline,
    available: boolean(status.available, "status.available"),
  };
}

function parseServer(value: unknown): Server {
  const server = record(value, "server");
  const id = string(server.id, "server.id");
  if (!/^[a-z][a-z0-9_]*$/.test(id)) return invalid("server.id is not valid");
  const backup = record(server.backup, "server.backup");
  return {
    id,
    game: string(server.game, "server.game"),
    displayName: string(server.displayName, "server.displayName"),
    public: array(server.public, "server.public").map((value) => {
      const endpoint = record(value, "endpoint");
      const port = endpoint.port;
      if (
        typeof port !== "number" ||
        !Number.isInteger(port) ||
        port < 1 ||
        port > 65535
      ) {
        return invalid("endpoint.port must be a valid port number");
      }
      return {
        hostname: string(endpoint.hostname, "endpoint.hostname"),
        port,
        protocol: string(endpoint.protocol, "endpoint.protocol"),
        edition: nullableString(endpoint.edition, "endpoint.edition"),
      };
    }),
    unit: string(server.unit, "server.unit"),
    container: nullableString(server.container, "server.container"),
    dataDir: string(server.dataDir, "server.dataDir"),
    worldPaths: strings(server.worldPaths, "server.worldPaths"),
    wakeOnJoin: boolean(server.wakeOnJoin, "server.wakeOnJoin"),
    available: boolean(server.available, "server.available"),
    backup: {
      enabled: boolean(backup.enabled, "backup.enabled"),
      unit: string(backup.unit, "backup.unit"),
      command: strings(backup.command, "backup.command"),
    },
    status: parseStatus(server.status, id),
  };
}

export function parseManifest(data: unknown): Manifest {
  const manifest = record(data, "manifest");
  if (manifest.schemaVersion !== 1) {
    throw new Error(
      "Unsupported server manifest schema. This dashboard requires schema version 1.",
    );
  }
  const servers = array(manifest.servers, "servers").map(parseServer);
  if (new Set(servers.map((server) => server.id)).size !== servers.length) {
    return invalid("server IDs must be unique");
  }
  return {
    schemaVersion: 1,
    host: string(manifest.host, "host"),
    sharedServices: array(manifest.sharedServices, "sharedServices").map(
      (value) => {
        const service = record(value, "shared service");
        return {
          id: string(service.id, "shared service.id"),
          unit: string(service.unit, "shared service.unit"),
          available: boolean(service.available, "shared service.available"),
          logsCommand: strings(
            service.logsCommand,
            "shared service.logsCommand",
          ),
        };
      },
    ),
    servers,
  };
}
