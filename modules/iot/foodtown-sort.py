#!/usr/bin/env python3
"""Sort the Home Assistant Foodtown todo list in Bedstuy walking order.

Reads items from the configured ``todo.*`` entity via HA's REST API,
asks OpenAI to sort them using the bundled foodtown-bedstuy-sort skill,
then renames each item with a zero-padded numeric prefix so the list
displays in walking order (HA's Bring integration always returns items
sorted alphabetically by name, so the prefix is the only stable way to
control display order).

Environment:
    HA_URL                 default http://localhost:8123
    HA_TOKEN_FILE          path to file containing a long-lived HA token
    FOODTOWN_ENTITY        default todo.foodtown
    FOODTOWN_SKILL_DIR     directory containing SKILL.md + 'store layout.md'
    FOODTOWN_MODEL         OpenAI model, default gpt-5-nano
    OPENAI_API_KEY         used by the openai client
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

from openai import OpenAI

HA_URL = os.environ.get("HA_URL", "http://localhost:8123").rstrip("/")
ENTITY_ID = os.environ.get("FOODTOWN_ENTITY", "todo.foodtown")
SKILL_DIR = Path(os.environ["FOODTOWN_SKILL_DIR"])
MODEL = os.environ.get("FOODTOWN_MODEL", "gpt-5-nano")
HA_TOKEN = Path(os.environ["HA_TOKEN_FILE"]).read_text().strip()

PREFIX_RE = re.compile(r"^\d{1,3}[.)]\s+")
BULLET_RE = re.compile(r"^[-*\u2022]\s*")


def ha_request(method: str, path: str, payload: dict | None = None) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{HA_URL}{path}",
        method=method,
        data=data,
        headers={
            "Authorization": f"Bearer {HA_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        sys.exit(f"foodtown-sort: HA {method} {path} -> {e.code}: {body}")


def strip_prefix(s: str) -> str:
    return PREFIX_RE.sub("", s).strip()


def clean_line(s: str) -> str:
    return strip_prefix(BULLET_RE.sub("", s.strip()))


def get_items() -> list[dict]:
    resp = ha_request(
        "POST",
        "/api/services/todo/get_items?return_response",
        {"entity_id": ENTITY_ID},
    )
    return resp["service_response"][ENTITY_ID]["items"]


def sort_with_llm(items: list[str]) -> list[str]:
    skill = (SKILL_DIR / "SKILL.md").read_text()
    layout = (SKILL_DIR / "store layout.md").read_text()
    system = f"{skill}\n\n---\n\n## references/store_layout.md\n\n{layout}"
    user = "Sort this grocery list:\n" + "\n".join(items)
    client = OpenAI()
    resp = client.chat.completions.create(
        model=MODEL,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    )
    text = resp.choices[0].message.content or ""
    return [clean_line(ln) for ln in text.splitlines() if ln.strip()]


def main() -> int:
    active = [i for i in get_items() if i.get("status") == "needs_action"]
    if not active:
        print("foodtown-sort: no active items", file=sys.stderr)
        return 0

    summaries = [strip_prefix(i["summary"]) for i in active]
    sorted_summaries = sort_with_llm(summaries)

    remaining = {strip_prefix(i["summary"]).lower(): i for i in active}
    ordered: list[dict] = []
    for line in sorted_summaries:
        key = line.lower()
        item = remaining.pop(key, None)
        if item is None:
            for k in list(remaining):
                if k in key or key in k:
                    item = remaining.pop(k)
                    break
        if item is None:
            print(
                f"foodtown-sort: WARN unmatched line from model: {line!r}",
                file=sys.stderr,
            )
            continue
        ordered.append(item)

    for leftover in remaining.values():
        print(
            f"foodtown-sort: WARN model dropped item {leftover['summary']!r}",
            file=sys.stderr,
        )
        ordered.append(leftover)

    width = max(2, len(str(len(ordered))))
    renamed = 0
    for idx, item in enumerate(ordered, 1):
        bare = strip_prefix(item["summary"])
        new_name = f"{idx:0{width}d}. {bare}"
        if new_name == item["summary"]:
            continue
        ha_request(
            "POST",
            "/api/services/todo/update_item",
            {
                "entity_id": ENTITY_ID,
                "item": item["uid"],
                "rename": new_name,
            },
        )
        renamed += 1

    print(
        f"foodtown-sort: ordered {len(ordered)} item(s), renamed {renamed}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
