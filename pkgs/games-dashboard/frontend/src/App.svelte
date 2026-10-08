<script lang="ts">
  import { onMount, tick } from "svelte";
  import Icon from "./Icon.svelte";
  import {
    actionLabel,
    gameLabel,
    parseManifest,
    parseStatus,
    stateDescription,
    stateLabel,
    stateTone,
  } from "./dashboard";
  import type { Action, LogEntry, Manifest, Server } from "./dashboard";
  import "./dashboard.css";

  let manifest = $state<Manifest | null>(null);
  let selectedId = $state("");
  let error = $state("");
  let loaded = $state(false);
  let lastUpdated = $state<Date | null>(null);
  let busy = $state<Record<string, Action | undefined>>({});
  let uncertain = $state<Record<string, boolean>>({});
  let notices = $state<
    Record<string, { text: string; failed: boolean } | undefined>
  >({});
  let selected = $derived(
    manifest?.servers.find((server) => server.id === selectedId),
  );
  let controlsDisabled = $derived(
    !selected ||
      !!error ||
      !!busy[selected.id] ||
      !selected.available ||
      !selected.status.available,
  );
  let activeView = $state<"console" | "details">("console");
  let dark = $state(false);
  let copied = $state("");
  let copyTimer: ReturnType<typeof setTimeout>;
  let confirmation = $state<{ server: Server; action: Action } | null>(null);
  let confirmDialog: HTMLDialogElement;
  let revision = 0;
  let disposed = false;
  let entries = $state<LogEntry[]>([]);
  let frozenEntries = $state<LogEntry[] | null>(null);
  let filter = $state("");
  let connection = $state("Connecting");
  let logError = $state("");
  let follow = $state(true);
  let viewport = $state<HTMLDivElement>();
  let visibleEntries = $derived(
    (frozenEntries ?? entries).filter((entry) =>
      entry.line.toLowerCase().includes(filter.toLowerCase()),
    ),
  );

  const time = (value: string | Date) => {
    const date = new Date(value);
    return Number.isNaN(date.getTime())
      ? "—"
      : date.toLocaleTimeString([], { hour12: false });
  };
  function toggleTheme() {
    dark = !dark;
    document.documentElement.classList.toggle("dark", dark);
    try {
      localStorage.setItem("games-theme", dark ? "dark" : "light");
    } catch {
      /* Storage is optional. */
    }
  }
  onMount(() => {
    try {
      dark = localStorage.getItem("games-theme") === "dark";
    } catch {
      /* Use paper by default. */
    }
    document.documentElement.classList.toggle("dark", dark);
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    async function refresh() {
      const startedAtRevision = revision;
      try {
        const response = await fetch("/api/servers", {
          signal: AbortSignal.any([
            controller.signal,
            AbortSignal.timeout(15000),
          ]),
        });
        if (!response.ok)
          throw new Error(
            `Server status is unavailable (HTTP ${response.status}).`,
          );
        const data = parseManifest(await response.json());
        if (startedAtRevision !== revision || disposed) return;
        // An action owns its displayed status until recovery completes.
        data.servers = data.servers.map((server) => {
          const previous = manifest?.servers.find(
            (item) => item.id === server.id,
          );
          return busy[server.id] && previous
            ? { ...server, status: previous.status }
            : server;
        });
        manifest = data;
        if (!data.servers.some((server) => server.id === selectedId))
          selectedId = data.servers[0]?.id ?? "";
        lastUpdated = new Date();
        error = "";
      } catch (cause) {
        if (!controller.signal.aborted && startedAtRevision === revision)
          error =
            cause instanceof Error
              ? cause.message
              : "Unable to reach the dashboard API.";
      } finally {
        if (!disposed) {
          loaded = true;
          timer = setTimeout(refresh, 5000);
        }
      }
    }
    void refresh();
    return () => {
      disposed = true;
      controller.abort();
      clearTimeout(timer);
      clearTimeout(copyTimer);
    };
  });
  $effect(() => {
    const id = selectedId;
    entries = [];
    frozenEntries = null;
    logError = "";
    filter = "";
    connection = "Connecting";
    if (!id) return;
    const events = new EventSource(
      `/api/servers/${encodeURIComponent(id)}/events`,
    );
    events.onopen = () => {
      connection = "Live";
      logError = "";
    };
    events.onerror = () => {
      connection = "Reconnecting";
    };
    events.addEventListener("error", (event) => {
      if (event instanceof MessageEvent)
        logError = "The log reader stopped. Reconnecting…";
    });
    events.addEventListener("log", (event) => {
      try {
        const entry = JSON.parse(event.data);
        if (
          entry.id !== id ||
          typeof entry.timestamp !== "string" ||
          typeof entry.line !== "string"
        )
          throw new Error("Invalid event");
        entries = [
          ...entries.slice(-499),
          { ...entry, line: entry.line.slice(0, 16000) },
        ];
        logError = "";
      } catch {
        logError = "An unreadable console event was skipped.";
      }
    });
    return () => events.close();
  });
  $effect(() => {
    visibleEntries.length;
    activeView;
    if (follow && !frozenEntries)
      void tick().then(() => {
        if (viewport) viewport.scrollTop = viewport.scrollHeight;
      });
  });
  async function copyAddress(value: string) {
    try {
      await navigator.clipboard.writeText(value);
      copied = value;
      clearTimeout(copyTimer);
      copyTimer = setTimeout(() => {
        copied = "";
      }, 2000);
    } catch {
      if (selected)
        notices[selected.id] = {
          text: "Clipboard unavailable. Select the address to copy it.",
          failed: true,
        };
    }
  }
  async function requestAction(server: Server, action: Action) {
    if (controlsDisabled) return;
    if (action === "start") {
      void performAction(server, action);
      return;
    }
    confirmation = { server, action };
    await tick();
    confirmDialog.showModal();
  }
  async function performAction(server: Server, action: Action) {
    const currentServer = manifest?.servers.find(
      (item) => item.id === server.id,
    );
    if (
      !currentServer ||
      busy[server.id] ||
      error ||
      !currentServer.available ||
      !currentServer.status.available ||
      (action === "backup" && !currentServer.backup.enabled)
    )
      return;
    busy[server.id] = action;
    uncertain[server.id] = false;
    notices[server.id] = undefined;
    revision += 1;
    let responseReceived = false;
    try {
      // Backups include shutdown and recovery and may legitimately take 40+ minutes.
      const response = await fetch(
        `/api/servers/${encodeURIComponent(server.id)}/${action}`,
        { method: "POST" },
      );
      responseReceived = true;
      const result = await response.json();
      if (!response.ok)
        throw new Error(
          typeof result.detail === "string"
            ? result.detail
            : `Action failed (HTTP ${response.status}).`,
        );
      if (disposed) return;
      if (result.id !== server.id || result.action !== action || !result.status)
        throw new Error(
          "Unexpected action response. Check the server status before trying again.",
        );
      const current = manifest?.servers.find((item) => item.id === server.id);
      const status = parseStatus(result.status, server.id);
      if (current) current.status = status;
      notices[server.id] = {
        failed: false,
        text: `${{ start: "Start", stop: "Stop", restart: "Restart", backup: "Backup" }[action]} completed.`,
      };
    } catch (cause) {
      uncertain[server.id] = !responseReceived;
      notices[server.id] = {
        failed: true,
        text: responseReceived
          ? `${cause instanceof Error ? cause.message : "The action could not be completed."} Check the live console for details.`
          : "Connection lost before the result arrived. The operation may still be running. Controls remain locked for this session; verify completion in the server logs before reloading.",
      };
    } finally {
      if (responseReceived) busy[server.id] = undefined;
      revision += 1;
    }
  }
  function confirmAction() {
    const pending = confirmation;
    confirmDialog.close();
    confirmation = null;
    if (pending) void performAction(pending.server, pending.action);
  }
</script>

<svelte:head
  ><title>Games · Finn’s homelab</title><meta
    name="description"
    content="Game server status, controls, backups, and logs."
  /></svelte:head
>

<div class="page-shell">
  <header class="masthead">
    <div class="brand">
      <span class="fleuron" aria-hidden="true">❦</span>
      <h1>Games</h1>
    </div>
    <div class="masthead-tools">
      <span class="checked-at" class:danger={!!error}>
        {error
          ? "Status unavailable"
          : lastUpdated
            ? `Updated ${time(lastUpdated)}`
            : "Connecting…"}
      </span>
      {#if manifest}<span class="host-label"
          ><Icon name="server" /> {manifest.host}</span
        >{/if}<button
        class="theme-button"
        onclick={toggleTheme}
        aria-label={dark ? "Switch to light theme" : "Switch to dark theme"}
        title={dark ? "Light theme" : "Dark theme"}
        ><Icon name={dark ? "sun" : "moon"} /></button
      >
    </div>
  </header>
  <main>
    {#if error}<div class="page-alert" role="alert">
        {error} Controls disabled; retrying.
      </div>{/if}
    {#if !loaded}
      <div class="empty-state">
        <h2>Loading servers…</h2>
      </div>
    {:else if manifest && manifest.servers.length === 0}
      <div class="empty-state">
        <h2>No servers configured.</h2>
      </div>
    {:else if selected && manifest}
      <div class="workspace">
        <aside class="server-sidebar" aria-label="Game servers">
          <div class="section-caption">
            <h2>Servers</h2>
            <span>{manifest.servers.length}</span>
          </div>
          <nav class="server-list" aria-label="Select a server">
            {#each manifest.servers as server (server.id)}
              <button
                class="server-card"
                class:selected={server.id === selectedId}
                aria-pressed={server.id === selectedId}
                onclick={() => {
                  selectedId = server.id;
                }}
              >
                <span class="server-card-top"
                  ><span
                    class="game-mark"
                    class:terraria={server.game === "terraria-tmodloader"}
                    ><Icon
                      name={server.game === "minecraft-paper"
                        ? "cube"
                        : server.game === "terraria-tmodloader"
                          ? "tree"
                          : "server"}
                    /></span
                  ><span class="card-arrow" aria-hidden="true"
                    ><Icon name="chevron-right" /></span
                  ></span
                >
                <span class="server-name">{server.displayName}</span><span
                  class="game-name">{gameLabel(server)}</span
                >
                <span class="server-card-bottom"
                  ><span class="status-text {stateTone(server)}"
                    ><span class="dot"></span>{busy[server.id]
                      ? "Working…"
                      : stateLabel(server)}</span
                  ><span class="player-count"
                    ><Icon name="users" />{server.status.playersOnline ??
                      "—"}<span class="sr-only"
                      >{server.status.playersOnline === null
                        ? " players unknown"
                        : " players online"}</span
                    ></span
                  ></span
                >
              </button>
            {/each}
          </nav>
          {#if manifest.sharedServices.length}<div class="shared-services">
              <h3 class="eyebrow">Shared services</h3>
              {#each manifest.sharedServices as service (service.id)}<div
                  class="shared-service"
                >
                  <Icon name="network" />
                  <div>
                    <span
                      >{service.id === "velocity"
                        ? "Velocity"
                        : service.id}</span
                    >
                    <p>
                      {service.available
                        ? "Configured"
                        : "Missing prerequisites"} · runtime not reported
                    </p>
                  </div>
                </div>{/each}
            </div>{/if}
        </aside>
        <div class="server-workspace">
          <section class="server-overview" aria-labelledby="server-title">
            <div class="overview-heading">
              <div>
                <p class="eyebrow">{gameLabel(selected)}</p>
                <h2 id="server-title">{selected.displayName}</h2>
              </div>
              <span class="state-badge {stateTone(selected)}"
                ><span class="dot"></span>{busy[selected.id]
                  ? "Working…"
                  : stateLabel(selected)}</span
              >
            </div>
            {#if !busy[selected.id] && ["Starting", "Unavailable", "Failed"].includes(stateLabel(selected))}
              <p class="state-description">{stateDescription(selected)}</p>
            {/if}
            <div class="server-facts">
              <div>
                <span class="eyebrow">Players online</span>
                <div class="fact-number">
                  {busy[selected.id]
                    ? "—"
                    : (selected.status.playersOnline ?? "—")}<Icon
                    name="users"
                  />
                </div>
                {#if busy[selected.id] || selected.status.playersOnline === null}
                  <span class="fact-note"
                    >{busy[selected.id] ? "Updating…" : "Not reported"}</span
                  >
                {/if}
              </div>
              <div>
                <span class="eyebrow">Wake on join</span>
                <div class="fact-value">
                  {selected.wakeOnJoin ? "Configured" : "Off"}
                </div>
                {#if selected.wakeOnJoin && selected.status.state === "stopped"}
                  <span class="fact-note">Listener stopped</span>
                {/if}
              </div>
              <div>
                <span class="eyebrow">Backups</span>
                <div class="fact-value">
                  {selected.backup.enabled ? "Configured" : "Not enabled"}
                </div>
                <span class="fact-note"
                  >{selected.backup.enabled
                    ? "Stops server for snapshot"
                    : "Manual backups disabled"}</span
                >
              </div>
            </div>
            {#if selected.public.length}<div class="addresses">
                <span class="eyebrow address-label">Connect</span>
                <div>
                  {#each selected.public as endpoint}<div class="address-row">
                      <span class="edition"
                        >{endpoint.edition ??
                          endpoint.protocol.toUpperCase()}</span
                      ><code>{endpoint.hostname}:{endpoint.port}</code><button
                        class="copy-button"
                        aria-label={`Copy ${endpoint.edition ?? endpoint.protocol} address ${endpoint.hostname}:${endpoint.port}`}
                        onclick={() =>
                          copyAddress(`${endpoint.hostname}:${endpoint.port}`)}
                        ><Icon
                          name={copied ===
                          `${endpoint.hostname}:${endpoint.port}`
                            ? "check"
                            : "copy"}
                        /></button
                      >
                    </div>{/each}
                </div>
              </div>{/if}
            <div class="action-bar">
              <div class="lifecycle-actions">
                {#if selected.status.state === "stopped"}<button
                    class="button primary"
                    disabled={controlsDisabled}
                    onclick={() => requestAction(selected!, "start")}
                    ><Icon name="play" />{actionLabel(
                      "start",
                      selected,
                    )}</button
                  >{:else}<button
                    class="button"
                    disabled={controlsDisabled}
                    onclick={() => requestAction(selected!, "stop")}
                    ><Icon name="stop" />Stop server</button
                  >{/if}<button
                  class="button quiet"
                  disabled={controlsDisabled ||
                    selected.status.state === "stopped"}
                  onclick={() => requestAction(selected!, "restart")}
                  ><Icon name="restart" />Restart</button
                >
              </div>
              <button
                class="button backup"
                disabled={controlsDisabled || !selected.backup.enabled}
                onclick={() => requestAction(selected!, "backup")}
                ><Icon name="archive" />Back up now</button
              >
            </div>
            {#if busy[selected.id] && !uncertain[selected.id]}<p
                class="action-notice"
                role="status"
              >
                {busy[selected.id] === "backup"
                  ? "Backing up; controls locked until recovery completes."
                  : "Operation in progress…"}
              </p>{/if}
            {#if notices[selected.id]}<p
                class="action-notice"
                class:failed={notices[selected.id]?.failed}
                role="status"
              >
                {notices[selected.id]?.text}
              </p>{/if}
          </section>
          <section
            class="console-section"
            aria-label="Server activity and details"
          >
            <div class="console-heading">
              <div class="view-switch" aria-label="Server view">
                <button
                  class:active={activeView === "console"}
                  aria-pressed={activeView === "console"}
                  onclick={() => {
                    activeView = "console";
                  }}><Icon name="terminal" />Live console</button
                ><button
                  class:active={activeView === "details"}
                  aria-pressed={activeView === "details"}
                  onclick={() => {
                    activeView = "details";
                  }}>Server details</button
                >
              </div>
              {#if activeView === "console"}<span
                  class="stream-state"
                  class:good={connection === "Live" && !frozenEntries}
                  ><span class="dot"></span>{frozenEntries
                    ? "Paused"
                    : connection}</span
                >{/if}
            </div>
            {#if activeView === "console"}
              <div class="console-panel">
                <div class="console-tools">
                  <label class="log-filter"
                    ><Icon name="search" /><input
                      aria-label="Filter console output"
                      placeholder="Filter output…"
                      bind:value={filter}
                    /></label
                  ><button
                    class="console-tool"
                    aria-label={frozenEntries
                      ? "Resume console display"
                      : "Pause console display"}
                    onclick={() => {
                      frozenEntries = frozenEntries ? null : [...entries];
                    }}
                    ><Icon
                      name={frozenEntries ? "play" : "pause"}
                    />{frozenEntries ? "Resume" : "Pause"}</button
                  ><button
                    class="console-tool"
                    onclick={() => {
                      entries = [];
                      if (frozenEntries) frozenEntries = [];
                    }}>Clear</button
                  >
                </div>
                {#if logError}<p class="log-error" role="status">
                    {logError}
                  </p>{/if}
                <!-- svelte-ignore a11y_no_noninteractive_tabindex (Scrollable output needs keyboard access.) -->
                <div
                  class="console-output"
                  bind:this={viewport}
                  tabindex="0"
                  role="region"
                  aria-label={`${selected.displayName} console output`}
                >
                  {#each visibleEntries as entry}<div
                      class="log-line"
                      class:log-warning={/\b(warn|warning|error|failed|failure)\b/i.test(
                        entry.line,
                      )}
                    >
                      <time title={entry.timestamp}
                        >{time(entry.timestamp)}</time
                      ><span>{entry.line}</span>
                    </div>{:else}<div class="console-empty">
                      <Icon name="terminal" />
                      <p>
                        {filter ? "No matching lines." : "No output yet."}
                      </p>
                    </div>{/each}
                </div>
                <div class="console-footer">
                  <span
                    >{visibleEntries.length}
                    {visibleEntries.length === 1 ? "line" : "lines"} · latest 500
                    kept</span
                  ><label
                    ><input type="checkbox" bind:checked={follow} />Follow
                    output</label
                  >
                </div>
              </div>
            {:else}
              <div class="details-panel">
                <dl>
                  <div>
                    <dt>Server ID</dt>
                    <dd>{selected.id}</dd>
                  </div>
                  <div>
                    <dt>Host</dt>
                    <dd>{manifest.host}</dd>
                  </div>
                  <div>
                    <dt>Service</dt>
                    <dd>{selected.unit}</dd>
                  </div>
                  <div>
                    <dt>Unit state</dt>
                    <dd>{selected.status.unitState ?? "Unknown"}</dd>
                  </div>
                  <div>
                    <dt>Ready for players</dt>
                    <dd>{selected.status.ready ? "Yes" : "No"}</dd>
                  </div>
                  <div>
                    <dt>Data directory</dt>
                    <dd>{selected.dataDir}</dd>
                  </div>
                  <div>
                    <dt>World paths</dt>
                    <dd>
                      {#each selected.worldPaths as path}<span
                          class="world-path">{path}</span
                        >{/each}
                    </dd>
                  </div>
                  <div>
                    <dt>Backup configuration</dt>
                    <dd>
                      {selected.backup.enabled
                        ? "Enabled; storage is checked when a backup runs"
                        : "Disabled"}
                    </dd>
                  </div>
                </dl>
              </div>
            {/if}
          </section>
        </div>
      </div>
    {/if}
  </main>
</div>

<dialog
  bind:this={confirmDialog}
  onclose={() => {
    confirmation = null;
  }}
  aria-labelledby="confirm-title"
  aria-describedby="confirm-description"
>
  {#if confirmation}<p class="eyebrow">{confirmation.server.displayName}</p>
    <h2 id="confirm-title">
      {confirmation.action === "backup"
        ? "Back up server?"
        : confirmation.action === "stop"
          ? "Stop this server?"
          : "Restart this server?"}
    </h2>
    <p id="confirm-description">
      {confirmation.action === "backup"
        ? "Disconnects players, stops the server, takes a snapshot, then restores its previous state."
        : confirmation.action === "stop"
          ? `Disconnects players.${confirmation.server.wakeOnJoin ? " Disables wake-on-join until the server is started again." : ""}`
          : `Disconnects players and restarts the server.${confirmation.server.wakeOnJoin ? " The server may sleep until a player joins." : ""}`}
    </p>
    <div class="dialog-actions">
      <button class="button" onclick={() => confirmDialog.close()}
        >Cancel</button
      ><button
        class="button primary"
        disabled={!!error || !!busy[confirmation.server.id]}
        onclick={confirmAction}
        >{actionLabel(confirmation.action, confirmation.server)}</button
      >
    </div>{/if}
</dialog>
