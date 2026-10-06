"""Shared structural contract for actual Alertmanager and shell renderers."""

import re


def check_message(text, alertname, target, status, since=None, ended=None):
    lines = text.strip().splitlines()
    header = "✅ RESOLVED" if status == "resolved" else "🔴 FIRING"
    assert lines[0] == f"{header}: {alertname}", lines
    pattern = r"\d{4}-\d{2}-\d{2} \d{2}:\d{2} E[DS]T"
    assert re.fullmatch(re.escape(target + " — since ") + pattern, lines[1]), lines
    if since:
        assert lines[1] == f"{target} — since {since}", lines
    offset = 2
    if status == "resolved":
        assert re.fullmatch("Ended: " + pattern, lines[2]), lines
        if ended:
            assert lines[2] == f"Ended: {ended}", lines
        # Recovery contains only identity, target, and incident timestamps:
        # no original summary or Hint/Runbook/Logs/Journal diagnostics.
        assert len(lines) == 3, lines
    else:
        assert not any(line.startswith("Ended:") for line in lines), lines
        assert lines[offset] and not lines[offset].startswith("Hint:"), lines
        assert lines[offset + 1].startswith("Hint: "), lines
    assert "🚨" not in lines[0]
