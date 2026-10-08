"""Validate host integration, discovery, secret gates and journal privacy."""

import json
import re
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
for mode in ("missing", "disabled", "enabled"):
    servers = data[mode]["servers"]
    assert {"survival", "terraria"} <= servers.keys()
    if mode == "missing":
        assert not any(server["available"] for server in servers.values())
    if mode == "disabled":
        assert not any(server["enabled"] for server in servers.values())
    if mode == "enabled":
        assert all(server["available"] for server in servers.values())
        assert (
            servers["survival"]["backupEnabled"]
            and servers["terraria"]["backupEnabled"]
        )
        assert not servers["velocity"]["backupEnabled"]
    assert servers["survival"]["serverPort"] == 25567  # never lazymc or RCON
    assert servers["survival"]["memoryBytes"] == 6 * 1024**3
    assert servers["terraria"]["capacity"] == 16
assert "creative" in data["discovered"]["servers"]
assert data["manifest"]["schemaVersion"] == 1
assert not any("metrics" in server for server in data["manifest"]["servers"])
assert data["backupOnFailure"] == []
assert re.search(
    r'ping-passthrough\s*=\s*"DISABLED"', Path(data["proxyConfig"]).read_text()
)
assert (
    "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files"
    in data["exporterFlags"]
)
assert "games-metrics" in data["exporter"]["ExecStart"]
assert data["exporter"]["ProtectSystem"] == "strict"
assert data["alloy"].count('loki.source.journal "system"') == 1
assert '"__journal_container_name"' in data["alloy"]
assert 'target_label = "server_id"' in data["alloy"]
assert 'target_label = "game"' in data["alloy"]
assert 'service_name=\\"games\\"' in data["alloy"]
assert "[REDACTED]" in data["alloy"]
assert not re.search(
    r'target_label\s*=\s*"(?:player|username|ip|uuid|message)"', data["alloy"]
)
print(
    "Game telemetry discovery, disabled entries, secret gates, manifest compatibility and Alloy privacy passed"
)
