import assert from "node:assert/strict";
import { test } from "node:test";
import {
  parseManifest,
  parseStatus,
  sharedStateLabel,
  sharedStateTone,
} from "./dashboard.ts";
import type { SharedService } from "./dashboard.ts";

function service(overrides = {}): SharedService {
  return {
    id: "velocity",
    unit: "minecraft-server-velocity.service",
    available: true,
    logsCommand: ["games-logs", "velocity"],
    status: {
      id: "velocity",
      state: "running",
      unitState: "active",
      ready: true,
      playersOnline: null,
      available: true,
      ...overrides,
    },
  };
}

for (const [overrides, label, tone] of [
  [{}, "Running", "good"],
  [{ ready: false }, "Running", "good"],
  [{ unitState: "activating", ready: false }, "Starting", "warm"],
  [
    { state: "stopped", unitState: "inactive", ready: false },
    "Stopped",
    "muted",
  ],
  [{ state: "failed", unitState: "failed", ready: false }, "Failed", "danger"],
  [
    { state: "failed", unitState: "inactive", ready: false },
    "Failed",
    "danger",
  ],
  [{ available: false }, "Unavailable", "danger"],
] as const) {
  test(`shared service renders ${label} (${JSON.stringify(overrides)})`, () => {
    const parsed = parseManifest({
      schemaVersion: 1,
      host: "link",
      servers: [],
      sharedServices: [service(overrides)],
    });
    assert.equal(sharedStateLabel(parsed.sharedServices[0]), label);
    assert.equal(sharedStateTone(parsed.sharedServices[0]), tone);
  });
}

test("shared manifest requires a matching, valid runtime status", () => {
  for (const status of [
    undefined,
    { ...service().status, id: "sshd" },
    { ...service().status, state: "sleeping" },
    { ...service().status, ready: "yes" },
  ]) {
    assert.throws(() =>
      parseManifest({
        schemaVersion: 1,
        host: "link",
        servers: [],
        sharedServices: [{ ...service(), status }],
      }),
    );
  }
});

test("server status still rejects the shared failed state", () => {
  assert.throws(() =>
    parseStatus(service({ state: "failed" }).status, "velocity"),
  );
  assert.equal(parseStatus(service().status, "velocity").state, "running");
});

test("empty shared inventory is supported", () => {
  assert.deepEqual(
    parseManifest({
      schemaVersion: 1,
      host: "link",
      servers: [],
      sharedServices: [],
    }).sharedServices,
    [],
  );
});
