# shellcheck shell=bash
if [[ ! -f "$BEETS_GRAPH_STORE" ]]; then
	echo "Album graph export skipped: embeddings store is missing: $BEETS_GRAPH_STORE"
	exit 0
fi

# The existing beet launcher owns the import lock. Do not invoke the raw
# beets package or take that lock a second time here.
staging=$(mktemp -d "$BEETS_GRAPH_STATE/.export-XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT
"$BEETS_GRAPH_LAUNCHER" -c "$BEETS_GRAPH_CONFIG" -p embed \
	embed-graph-export --store "$BEETS_GRAPH_STORE" --model style \
	-o "$staging/albums.json"

# Upstream exports atomically, but its temporary files are mode 0600. Prepare
# reader permissions before replacing the published file on the same filesystem.
chmod 0640 "$staging/albums.json"
mv -T -- "$staging/albums.json" "$BEETS_GRAPH_STATE/albums.json"
