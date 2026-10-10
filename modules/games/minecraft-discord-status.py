"""One Discord status card, driven only by existing passive game telemetry."""

import argparse
import json
import math
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from prometheus_client.parser import text_string_to_metric_families

METRICS = Path("/var/lib/prometheus-node-exporter-text-files/games.prom")
DEBOUNCE = 90
MAX_AGE = 120
MAX_GAP = 90
API = "https://discord.com/api/v10"


def atomic_json(path, value):
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=".discord-")
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def observation(text, server_id, now):
    """Reject incomplete or stale snapshots instead of inventing an outage."""
    values = {}
    wanted = {
        "games_metrics_last_update_timestamp_seconds",
        "games_metrics_collection_success",
        "games_server_state",
        "games_server_ready",
        "games_server_failed",
    }
    for family in text_string_to_metric_families(text):
        for sample in family.samples:
            if sample.name not in wanted:
                continue
            if sample.name == "games_metrics_last_update_timestamp_seconds":
                key = (sample.name, None)
            elif sample.labels.get("server_id") == server_id:
                key = (sample.name, sample.labels.get("state"))
            else:
                continue
            if key in values or not math.isfinite(sample.value):
                raise ValueError("invalid telemetry sample")
            values[key] = sample.value
    timestamp = values[("games_metrics_last_update_timestamp_seconds", None)]
    if not 0 <= now - timestamp <= MAX_AGE:
        raise ValueError("stale telemetry")
    if values[("games_metrics_collection_success", None)] != 1:
        raise ValueError("unsuccessful collection")
    states = {
        name: values[("games_server_state", name)]
        for name in ("running", "sleeping", "stopped", "disabled")
    }
    ready = values[("games_server_ready", None)]
    failed = values[("games_server_failed", None)]
    if (
        any(value not in (0, 1) for value in (*states.values(), ready, failed))
        or sum(states.values()) != 1
    ):
        raise ValueError("invalid lifecycle state")
    state = next(name for name, value in states.items() if value)
    if failed:
        state = "failed"
    elif state == "running":
        state = "awake" if ready else "starting"
    elif state == "sleeping":
        state = "resting"
    return state, timestamp


def payload(config, state):
    label = {
        "awake": "is awake",
        "starting": "is starting",
        "resting": "is resting; join Minecraft to wake it",
        "stopped": "is stopped",
        "failed": "failed",
        "disabled": "is disabled",
    }[state]
    return {
        "content": "",
        "embeds": [
            {
                "description": f"{config['displayName']} {label}.",
                "color": int(config["colors"][state].lstrip("#"), 16),
            }
        ],
        "allowed_mentions": {"parse": []},
    }


class DeliveryError(Exception):
    def __init__(self, status=0, code=None, retry_after=30):
        super().__init__("Discord status delivery failed")
        self.status = status
        self.code = code
        self.retry_after = retry_after


def message_id(value):
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("id"), str)
        or not value["id"].isdecimal()
    ):
        raise DeliveryError()
    return value["id"]


def reconcile(messages, record):
    """Find a lost creation response or prove the attempted card is absent."""
    if not isinstance(messages, list) or any(not isinstance(m, dict) for m in messages):
        raise DeliveryError()
    for message in messages:
        if str(message.get("nonce")) == record["nonce"]:
            record["messageId"] = message_id(message)
            record.pop("creationUncertain", None)
            return
    # Fewer than 100 messages covers the whole channel. Otherwise require the
    # oldest retrieved snowflake to predate the request (with clock headroom).
    oldest = min((int(message_id(m)) for m in messages), default=0)
    oldest_time = ((oldest >> 22) + 1420070400000) / 1000
    if len(messages) == 100 and oldest_time >= record["creationAfter"] - 60:
        raise DeliveryError()
    record.pop("creationUncertain", None)


def transport(token):
    def request(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            API + path,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bot {token}",
                "Content-Type": "application/json",
                "User-Agent": "FinnMC lifecycle notifier (infra, 1)",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                detail = json.loads(error.read(65536))
                code = detail.get("code")
                delay = max(1, float(detail.get("retry_after", 30)))
                if not math.isfinite(delay):
                    delay = 30
            except (ValueError, TypeError, AttributeError):
                code, delay = None, 30
            raise DeliveryError(error.code, code, delay) from None
        except (OSError, ValueError):
            # Never log exception bodies, headers, credentials, or response content.
            raise DeliveryError() from None

    return request


def update(config, record, text, now, boot_id, request, checkpoint):
    """Advance a persisted debounce and publish only confirmed stable changes."""
    if record.get("channelId") != config["channelId"]:
        record.clear()
        record.update(channelId=config["channelId"], nonce=uuid.uuid4().hex[:25])
    if record.get("bootId") != boot_id:
        record.pop("pending", None)
        record["bootId"] = boot_id
    try:
        state, timestamp = observation(text, config["serverId"], now)
    except (ValueError, KeyError, TypeError):
        record.pop("pending", None)
        return "unavailable"
    pending = record.get("pending")
    if (
        not pending
        or pending["state"] != state
        or timestamp < pending["last"]
        or timestamp - pending["last"] > MAX_GAP
    ):
        pending = {"state": state, "since": timestamp, "last": timestamp}
        record["pending"] = pending
    else:
        pending["last"] = timestamp
    if timestamp - pending["since"] < DEBOUNCE:
        return "pending"
    if record.get("messageId") and record.get("published") == state:
        return "unchanged"
    if now < record.get("retryAt", 0):
        return "deferred"
    path = f"/channels/{config['channelId']}/messages"
    try:
        # A lost POST response (or killed process) must not create a second card.
        # Reconcile the nonce; if history cannot prove absence, fail closed.
        if record.get("creationUncertain"):
            messages = request("GET", path + "?limit=100")
            reconcile(messages, record)
        body = payload(config, state)
        if record.get("messageId"):
            try:
                request("PATCH", path + "/" + record["messageId"], body)
            except DeliveryError as error:
                if error.status != 404 or error.code != 10008:
                    raise
                record.pop("messageId")
                record.pop("published", None)
                record["nonce"] = uuid.uuid4().hex[:25]
                record.pop("creationAfter", None)
        if not record.get("messageId"):
            record["creationUncertain"] = True
            record.setdefault("creationAfter", now)
            checkpoint(record)
            try:
                result = request(
                    "POST",
                    path,
                    body | {"nonce": record["nonce"], "enforce_nonce": True},
                )
            except DeliveryError as error:
                if 400 <= error.status < 500:
                    record.pop("creationUncertain", None)
                raise
            record["messageId"] = message_id(result)
            record.pop("creationUncertain", None)
        record.pop("creationAfter", None)
        record["published"] = state
        record.pop("retryAt", None)
        record.pop("failures", None)
        return "updated"
    except DeliveryError as error:
        failures = min(record.get("failures", 0) + 1, 5)
        record["failures"] = failures
        record["retryAt"] = now + (
            error.retry_after
            if error.status == 429
            else min(30 * 2 ** (failures - 1), 300)
        )
        return "delivery-failed"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    path = Path(os.environ["STATE_DIRECTORY"]) / "status.json"
    try:
        record = json.loads(path.read_text())
    except FileNotFoundError:
        record = {}
    # A damaged state file must not silently discard the existing message ID.
    checkpoint = lambda value: atomic_json(path, value)
    try:
        text = METRICS.read_text()
    except OSError:
        text = ""
    token = (
        (Path(os.environ["CREDENTIALS_DIRECTORY"]) / "discord-token")
        .read_text()
        .strip()
    )
    if not token:
        raise ValueError("empty Discord credential")
    outcome = update(
        config,
        record,
        text,
        time.time(),
        Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        transport(token),
        checkpoint,
    )
    checkpoint(record)
    if outcome == "delivery-failed":
        print(
            "Discord lifecycle delivery failed; retaining card state and retrying later",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
