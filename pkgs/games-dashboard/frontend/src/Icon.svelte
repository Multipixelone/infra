<script lang="ts">
  let { name }: { name: string } = $props();
  const paths: Record<string, string> = {
    server: "M4 3h16v7H4zM4 14h16v7H4zM7 6.5h.01M7 17.5h.01M11 6.5h6M11 17.5h6",
    moon: "M20.8 13A9 9 0 0 1 11 3.2 9 9 0 1 0 20.8 13Z",
    sun: "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8ZM12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5",
    users:
      "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8ZM17 4a4 4 0 0 1 0 7m5 10v-2a4 4 0 0 0-3-3.87",
    cube: "m12 2 9 5v10l-9 5-9-5V7Zm0 10L3 7m9 5 9-5m-9 5v10M7.5 4.5l9 5",
    tree: "M12 2 6 9h3l-5 6h6v7h4v-7h6l-5-6h3L12 2Z",
    network: "M9 2h6v6H9zM2 16h6v6H2zM16 16h6v6h-6zM12 8v4M5 16v-4h14v4",
    play: "m8 4 12 8-12 8V4Z",
    stop: "M5 5h14v14H5z",
    restart: "M20 7v5h-5M20 12a8 8 0 1 0-2 6",
    archive: "M3 3h18v5H3zM5 8v13h14V8M10 12h4",
    copy: "M9 9h12v12H9zM5 15H3V3h12v2",
    check: "m5 12 4 4L19 6",
    "chevron-right": "m9 5 7 7-7 7",
    terminal: "m4 5 6 6-6 6m9 0h7",
    search: "M10.5 3a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15Zm5.5 13 5 5",
    pause: "M7 4v16M17 4v16",
  };
</script>

<svg
  class="icon"
  width="20"
  height="20"
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="1.5"
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"><path d={paths[name] ?? paths.server} /></svg
>
