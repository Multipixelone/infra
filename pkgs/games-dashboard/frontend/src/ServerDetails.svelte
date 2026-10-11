<script lang="ts">
  import Icon from "./Icon.svelte";
  import { displayPlugins } from "./dashboard";
  import type { Server, SharedService } from "./dashboard";

  let {
    server,
    sharedServices = [],
    copied = "",
    copyAddress,
  }: {
    server: Server;
    sharedServices?: SharedService[];
    copied?: string;
    copyAddress: (address: string) => void;
  } = $props();

  const plugins = $derived(displayPlugins(server, sharedServices));
  const datapacks = $derived(
    [...(server.datapacks ?? [])].sort((a, b) =>
      Number(a.installed) - Number(b.installed) || a.name.localeCompare(b.name),
    ),
  );

  function mapAddress(url: string): string {
    try {
      return new URL(url).host || url;
    } catch {
      return url;
    }
  }
</script>

<div class="server-details">
  {#if server.public.length || server.mapUrl || server.discordInviteUrl}
    <section class="addresses" aria-labelledby="connect-heading">
      <h3 id="connect-heading" class="eyebrow address-label">Connect</h3>
      <table class="connection-table">
        <caption class="sr-only">Connection addresses for {server.displayName}</caption>
        <tbody>
          {#each server.public as endpoint}
            <tr>
              <th scope="row" class="edition">{endpoint.edition ?? endpoint.protocol.toUpperCase()}</th>
              <td><code>{endpoint.hostname}:{endpoint.port}</code></td>
              <td class="connection-action">
                <button
                  class="copy-button"
                  aria-label={`Copy ${endpoint.edition ?? endpoint.protocol} address ${endpoint.hostname}:${endpoint.port}`}
                  onclick={() => copyAddress(`${endpoint.hostname}:${endpoint.port}`)}
                ><Icon name={copied === `${endpoint.hostname}:${endpoint.port}` ? "check" : "copy"} /></button>
              </td>
            </tr>
          {/each}
          {#if server.mapUrl}
            <tr class="map-row">
              <th scope="row" class="edition">Map</th>
              <td colspan="2">
                <a class="map-link" href={server.mapUrl} target="_blank" rel="noopener noreferrer">
                  {mapAddress(server.mapUrl)}<span aria-hidden="true"> ↗</span>
                  <span class="sr-only"> — {server.displayName} world map (opens in a new tab)</span>
                </a>
                <span class="detail-note">Available while {server.displayName} sleeps</span>
              </td>
            </tr>
          {/if}
          {#if server.discordInviteUrl}
            <tr class="discord-row">
              <th scope="row" class="edition">Discord</th>
              <td colspan="2">
                <a class="map-link" href={server.discordInviteUrl} target="_blank" rel="noopener noreferrer">
                  {server.discordInviteUrl.replace(/^https:\/\//, "")}<span aria-hidden="true"> ↗</span>
                  <span class="sr-only"> — {server.displayName} Discord community (opens in a new tab)</span>
                </a>
              </td>
            </tr>
          {/if}
        </tbody>
      </table>
    </section>
  {/if}
  {#if plugins.length}
    <section class="addresses" aria-labelledby="plugins-heading">
      <h3 id="plugins-heading" class="eyebrow address-label">Plugins</h3>
      <ul class="plugin-list">
        {#each plugins as plugin (plugin.name)}
          {@const versions = [...new Set(plugin.installations.map((entry) => entry.version))]}
          {@const differs = versions.length > 1 || new Set(plugin.installations.map((entry) => entry.installed)).size > 1}
          <li class="plugin-row">
            <div class="plugin-summary">
              <span class="plugin-name">{plugin.name}</span>
              {#if versions.length === 1}<code class="plugin-version">{versions[0]}</code>{/if}
              <span class="plugin-status" class:needs-setup={!plugin.installed}>{plugin.installed ? "Enabled" : "Awaiting setup"}</span>
            </div>
            <span class="plugin-platforms">{[...new Set(plugin.installations.map((entry) => entry.platform))].join(" · ")}</span>
            {#if differs}
              <span class="detail-note plugin-detail">{plugin.installations.map((entry) => `${entry.platform}: ${entry.version} · ${entry.installed ? "Enabled" : "Awaiting setup"}`).join("; ")}</span>
            {/if}
          </li>
        {/each}
      </ul>
    </section>
  {/if}
  {#if datapacks.length}
    <section class="addresses" aria-labelledby="datapacks-heading">
      <h3 id="datapacks-heading" class="eyebrow address-label">Datapacks</h3>
      <ul class="plugin-list">
        {#each datapacks as pack (pack.name)}
          <li class="plugin-row">
            <div class="plugin-summary">
              <span class="plugin-name">{pack.name}</span>
              <code class="plugin-version">{pack.version}</code>
              <span class="plugin-status" class:needs-setup={!pack.installed}>{pack.installed ? "Installed" : "Deferred"}</span>
            </div>
            <span class="plugin-platforms">World datapack</span>
          </li>
        {/each}
      </ul>
    </section>
  {/if}
</div>
