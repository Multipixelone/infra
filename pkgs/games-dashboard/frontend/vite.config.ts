import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

const rawPort = process.env.PORT ?? "5173";
const port = Number(rawPort);
if (
  !/^\d+$/.test(rawPort) ||
  !Number.isInteger(port) ||
  port < 1024 ||
  port > 65534
) {
  throw new Error("PORT must be an integer from 1024 through 65534");
}

export default defineConfig({
  plugins: [svelte()],
  server: {
    host: "127.0.0.1",
    port,
    strictPort: true,
    proxy: {
      "/api": { target: `http://127.0.0.1:${port + 1}` },
    },
  },
});
