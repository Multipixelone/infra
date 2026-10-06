# shellcheck shell=bash
args=(--port 8765)
if [[ -f "$BEETS_GRAPH_STATE/albums.json" ]]; then
	args+=(--data "$BEETS_GRAPH_STATE/albums.json")
fi
# Upstream rejects --data when the file is absent; the file picker still works
# without it. A successful export restarts this service to enable /data.json.
exec "$BEETS_GRAPH_VIEWER" "${args[@]}"
