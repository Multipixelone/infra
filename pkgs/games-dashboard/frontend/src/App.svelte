<script lang="ts">
  import { onMount } from "svelte";

  type Server = {
    id: string;
    displayName: string;
    status: {
      state: "running" | "sleeping" | "stopped";
      playersOnline: number | null;
    };
  };

  let servers = $state<Server[]>([]);
  let error = $state("");
  let latestLine = $state("Waiting for a console event…");
  let connection = $state("connecting");

  onMount(() => {
    const controller = new AbortController();
    let events: EventSource | undefined;

    async function load() {
      try {
        const response = await fetch("/api/servers", { signal: controller.signal });
        if (!response.ok) throw new Error(`API returned ${response.status}`);
        const data = await response.json();
        servers = data.servers;
        if (servers.length === 0) {
          connection = "no servers";
          return;
        }
        events = new EventSource(`/api/servers/${encodeURIComponent(servers[0].id)}/events`);
        events.onopen = () => { connection = "connected"; };
        events.onerror = () => { connection = "reconnecting"; };
        events.addEventListener("log", (event) => {
          const entry = JSON.parse(event.data);
          latestLine = `${entry.timestamp} ${entry.line}`;
        });
      } catch (cause) {
        if (!controller.signal.aborted) error = String(cause);
      }
    }

    void load();
    return () => {
      controller.abort();
      events?.close();
    };
  });
</script>

<main>
  <h1>Games dashboard skeleton</h1>
  {#if error}<p role="alert">{error}</p>{/if}
  <ul>
    {#each servers as server (server.id)}
      <li>
        {server.displayName}: {server.status.state} — players:
        {server.status.playersOnline ?? "unknown"}
      </li>
    {/each}
  </ul>
  <p>Live console ({connection})</p>
  <pre aria-live="polite">{latestLine}</pre>
</main>
