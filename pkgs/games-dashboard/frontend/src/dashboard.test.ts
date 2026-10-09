import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer } from "vite";
import {
  parseManifest,
  parseStatus,
  sharedStateLabel,
  sharedStateTone,
  displayPlugins,
  wakeLabel,
} from "./dashboard.ts";
import type { Server, SharedService } from "./dashboard.ts";

function server(overrides: Partial<Server> = {}): Server {
  return {
    id: "survival",
    game: "minecraft-paper",
    displayName: "Survival",
    public: [
      {
        hostname: "survival.mc.finnrut.is",
        port: 25565,
        protocol: "tcp",
        edition: "Java",
      },
    ],
    unit: "minecraft-server-survival.service",
    container: null,
    dataDir: "/srv/games/survival",
    worldPaths: [],
    wakeOnJoin: true,
    available: true,
    backup: { enabled: false, unit: "backup.service", command: [] },
    status: {
      id: "survival",
      state: "sleeping",
      unitState: "inactive",
      ready: false,
      playersOnline: 0,
      available: true,
    },
    ...overrides,
  };
}

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

test("proxy plugin inventory survives shared runtime status parsing", () => {
  const plugins = [
    { name: "MiniMOTD", version: "2.2.5", installed: true },
    { name: "LuckPerms", version: "5.5.71", installed: false },
  ];
  for (const state of ["running", "stopped", "failed"]) {
    const proxy = { ...service({ state }), plugins };
    const parsed = parseManifest({
      schemaVersion: 1,
      host: "link",
      servers: [],
      sharedServices: [proxy],
    }).sharedServices[0];
    assert.deepEqual(parsed.plugins, plugins);
    assert.deepEqual(parsed.status, proxy.status);
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

test("plugins group across platforms, preserving versions and the worst status", () => {
  const paper = server({
    plugins: [
      { name: "LuckPerms", version: "5.5.71", installed: true },
      { name: "SkinsRestorer", version: "15.12.6", installed: true },
      { name: "BlueMap", version: "5.28", installed: true },
    ],
  });
  const proxy = {
    ...service(),
    plugins: [
      { name: "LuckPerms", version: "5.5.70", installed: false },
      { name: "SkinsRestorer", version: "15.12.6", installed: true },
    ],
  };
  const grouped = displayPlugins(paper, [proxy]);
  assert.deepEqual(
    grouped.map((plugin) => plugin.name),
    ["LuckPerms", "BlueMap", "SkinsRestorer"],
  );
  assert.equal(grouped[0].installed, false);
  assert.deepEqual(grouped[0].installations, [
    { ...proxy.plugins[0], platform: "Velocity" },
    { ...paper.plugins![0], platform: "Paper" },
  ]);
  assert.equal(grouped[2].installed, true);
  assert.deepEqual(
    grouped[2].installations.map((entry) => entry.platform),
    ["Velocity", "Paper"],
  );
  assert.equal(paper.plugins!.length, 3);
  assert.equal(proxy.plugins.length, 2);
});

test("duplicate inventory entries produce one plugin and platform entry", () => {
  const plugin = { name: "LuckPerms", version: "5.5.71", installed: false };
  assert.deepEqual(displayPlugins(server({ plugins: [plugin, plugin] }), []), [
    {
      name: "LuckPerms",
      installed: false,
      installations: [{ ...plugin, platform: "Paper" }],
    },
  ]);
});

test("empty backend still displays proxy plugins without leaking into other games", () => {
  const proxy = {
    ...service(),
    plugins: [{ name: "MiniMOTD", version: "2.2.5", installed: true }],
  };
  assert.equal(displayPlugins(server(), [proxy])[0].name, "MiniMOTD");
  assert.deepEqual(displayPlugins(server(), []), []);
  assert.deepEqual(displayPlugins(server(), [service()]), []);
  assert.deepEqual(
    displayPlugins(server({ game: "terraria-tmodloader" }), [proxy]),
    [],
  );
});

test("setup on either platform is actionable and actionable plugins sort alphabetically", () => {
  const plugin = { name: "LuckPerms", version: "5.5.71", installed: false };
  const grouped = displayPlugins(
    server({ plugins: [plugin, { ...plugin, name: "DiscordSRV" }] }),
    [{ ...service(), plugins: [{ ...plugin, installed: true }] }],
  );
  assert.deepEqual(
    grouped.map((entry) => [entry.name, entry.installed]),
    [
      ["DiscordSRV", false],
      ["LuckPerms", false],
    ],
  );
});

test("wake stat reflects current behavior and configuration", () => {
  assert.equal(wakeLabel(server()), "Wakes on join");
  assert.equal(wakeLabel(server({ wakeOnJoin: false })), "Off");
  for (const [status, expected] of [
    [{ state: "stopped" }, "Disabled"],
    [{ state: "running", ready: true }, "Enabled"],
    [{ state: "running", ready: false }, "Enabled"],
    [{ unitState: "failed" }, "Failed"],
    [{ available: false }, "Unavailable"],
  ] as const) {
    assert.equal(
      wakeLabel(server({ status: { ...server().status, ...status } })),
      expected,
    );
  }
  assert.equal(wakeLabel(server({ available: false })), "Unavailable");
});

test("server details render accessible, grouped inventory", async (t) => {
  const vite = await createServer({
    server: { middlewareMode: true },
    appType: "custom",
  });
  try {
    const { default: ServerDetails } = await vite.ssrLoadModule(
      "/src/ServerDetails.svelte",
    );
    const { render } = await vite.ssrLoadModule("svelte/server");
    const html = (
      overrides: Partial<Server> = {},
      plugins = [
        { name: "LuckPerms", version: "5.5.71", installed: false },
        { name: "SkinsRestorer", version: "15.12.6", installed: true },
      ],
    ) =>
      render(ServerDetails, {
        props: {
          server: server({
            plugins: [
              { name: "LuckPerms", version: "5.5.71", installed: true },
              { name: "SkinsRestorer", version: "15.12.6", installed: true },
            ],
            mapUrl: "https://map.finnrut.is",
            ...overrides,
          }),
          sharedServices: [{ ...service(), plugins }],
          copyAddress: () => {},
        },
      }).body;

    await t.test(
      "one semantic row per plugin with actionable status and platform details",
      () => {
        const markup = html();
        assert.equal((markup.match(/class="plugin-name"/g) ?? []).length, 2);
        assert.equal((markup.match(/>LuckPerms</g) ?? []).length, 1);
        assert.equal((markup.match(/>SkinsRestorer</g) ?? []).length, 1);
        assert.match(markup, /<ul class="plugin-list">/);
        assert.match(markup, /Velocity · Paper/);
        assert.match(
          markup,
          /Velocity: 5\.5\.71 · Awaiting setup; Paper: 5\.5\.71 · Enabled/,
        );
        assert.match(markup, /plugin-status needs-setup/);
        assert.ok(
          markup.indexOf(">LuckPerms<") < markup.indexOf(">SkinsRestorer<"),
        );
      },
    );
    await t.test("differing versions are visible per platform", () => {
      assert.match(
        html({}, [{ name: "LuckPerms", version: "5.5.70", installed: true }]),
        /Velocity: 5\.5\.70 · Enabled; Paper: 5\.5\.71 · Enabled/,
      );
    });
    await t.test(
      "map is a connection table row with meaningful new-tab text",
      () => {
        const markup = html();
        assert.match(markup, /<th scope="row" class="edition">Java<\/th>/);
        assert.match(
          markup,
          /aria-label="Copy Java address survival\.mc\.finnrut\.is:25565"/,
        );
        assert.match(markup, /<tr class="map-row">/);
        assert.match(
          markup,
          /href="https:\/\/map\.finnrut\.is" target="_blank" rel="noopener noreferrer"/,
        );
        assert.match(markup, /Survival world map \(opens in a new tab\)/);
        assert.match(
          markup,
          /class="detail-note">Available while Survival sleeps/,
        );
        assert.ok(markup.indexOf("map-link") < markup.indexOf("</table>"));
        assert.match(html({ public: [] }), /<tr class="map-row">/);
      },
    );
    await t.test(
      "missing sections disappear, proxy-only inventory remains visible",
      () => {
        const empty = html({ public: [], mapUrl: null, plugins: [] }, []);
        assert.doesNotMatch(empty, /<table|<ul|Connect|Plugins/);
        assert.match(html({ plugins: [] }), />LuckPerms</);
        assert.doesNotMatch(
          html({ game: "terraria-tmodloader", plugins: [] }),
          /plugin-name/,
        );
      },
    );
  } finally {
    await vite.close();
  }
});
