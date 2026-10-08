{
  export = ''
    if [[ ! -f "$BEETS_GRAPH_STORE" ]]; then
      echo "Album graph export skipped: embeddings store is missing: $BEETS_GRAPH_STORE"
      exit 0
    fi

    # Snapshot both inputs without the import lock, then run only the embed
    # plugin against private copies. Real imports retain their locked launcher.
    staging=$(mktemp -d "$BEETS_GRAPH_STATE/.export-XXXXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    "$BEETS_GRAPH_SNAPSHOT" "$BEETS_GRAPH_LIBRARY" "$BEETS_GRAPH_STORE" "$staging"
    "$BEETS_GRAPH_LAUNCHER" -c "$BEETS_GRAPH_CONFIG" -l "$staging/library.db" -p embed \
      embed-graph-export --store "$staging/embeddings.sqlite3" --model style \
      --covers-dir "$BEETS_GRAPH_COVERS" --cache-dir "$BEETS_GRAPH_CACHE" \
      -o "$staging/albums.json"

    # Covers and their ownership manifest stay in the persistent cache. Only
    # JSON is staged; upstream owns thumbnail writes, reuse, and pruning.
    # Prepare reader permissions before replacing JSON on the same filesystem.
    chmod 0640 "$staging/albums.json"
    mv -T -- "$staging/albums.json" "$BEETS_GRAPH_STATE/albums.json"
  '';

  viewer = ''
    args=(--port 8765 --covers "$BEETS_GRAPH_COVERS" --cache-dir "$BEETS_GRAPH_CACHE")
    if [[ -f "$BEETS_GRAPH_STATE/albums.json" ]]; then
      args+=(--data "$BEETS_GRAPH_STATE/albums.json")
    fi
    # Upstream rejects --data when the file is absent; the file picker still
    # works without it. Tmpfiles creates the empty covers directory at boot.
    exec "$BEETS_GRAPH_VIEWER" "''${args[@]}"
  '';
}
