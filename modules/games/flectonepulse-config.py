"""Generate event-only configuration from the pinned plugin's complete schema."""
import io
import json
import re
import sys
import zipfile
from pathlib import Path

import yaml

plugin, client, output = map(Path, sys.argv[1:4])
invite = sys.argv[4] if len(sys.argv) > 4 else ""
with zipfile.ZipFile(plugin) as outer:
    inner = zipfile.ZipFile(io.BytesIO(outer.read("flectonepulse-bukkit.jarinjar")))
    defaults = {
        name: yaml.safe_load(inner.read(f"config/minecraft/{name}.yml"))
        for name in ("config", "command", "message", "permission", "integration")
    }
    english = yaml.safe_load(inner.read("config/minecraft/localizations/en_us.yml"))
with zipfile.ZipFile(client) as archive:
    language_bytes = archive.read("assets/minecraft/lang/en_us.json")
    language = json.loads(language_bytes)


def disable(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "enable":
                value[key] = False
            else:
                disable(child)
    elif isinstance(value, list):
        for child in value:
            disable(child)


# Start from a complete pinned schema, disabling newly overlooked subfeatures.
for name in ("command", "message", "integration"):
    disable(defaults[name])
config = defaults["config"]
config["language"] = {"type": "en_us", "by_player": False}
config["database"]["use_playtime_tracking"] = False
config["database"]["pool_settings"].update(max_size=2, min_idle=1)
config["executor"].update(min_pool_size=1, max_pool_size=2)
config["internal"]["vanilla_commands_to_remove"] = []
config["metrics"]["enable"] = False

message = defaults["message"]
message["enable"] = True
message["format"]["enable"] = True
message["format"]["convert_legacy_color"] = False
# These tags resolve raw player/entity names; no nickname, prefix or name ticker.
message["format"]["names"]["enable"] = True
for event in ("join", "quit"):
    message[event].update(enable=True, range="SERVER")
message["join"]["first"] = True
message["vanilla"].update(enable=True, cancel_default_death_screen=False)

deaths = {}
for key, text in sorted(language.items()):
    if not key.startswith("death.") or not re.search(r"%(?:1\$)?s", text):
        continue

    def argument(match):
        # Explicit Java format indexes do not consume the sequential counter.
        index = int(match[1]) - 1 if match[1] else argument.position
        if not match[1]:
            argument.position += 1
        color = "#cba6f7" if index == 0 else "#fab387"
        return f"<{color}><argument:{index}></{color}>"

    argument.position = 0
    text = re.sub(r"%(?:(\d+)\$)?s", argument, text).replace("%%", "%")
    deaths[key] = f"<#fab387>×</#fab387> <#a6adc8>{text}</#a6adc8>"

message["vanilla"]["types"] = [{
    "name": "DEATH",
    "multi_message": True,
    "range": "SERVER",
    "destination": {"type": "CHAT"},
    "translation_keys": list(deaths),
}]
local = english["message"]
local["join"] = {
    "format": "<#cba6f7>+</#cba6f7> <#cba6f7><player></#cba6f7> <#a6adc8>joined Survival</#a6adc8>",
    "format_first_time": "<#cba6f7>+</#cba6f7> <#cba6f7><player></#cba6f7> <#a6adc8>joined Survival for the first time</#a6adc8>",
}
if invite:
    local["join"]["format_first_time"] += (
        f"\n<#a6adc8>Discord: <#cba6f7>{invite}</#cba6f7></#a6adc8>"
    )
local["quit"] = {"format": "<#f5c2e7>−</#f5c2e7> <#cba6f7><player></#cba6f7> <#a6adc8>left Survival</#a6adc8>"}
local["format"]["names"].update(
    constant=[], display=["<player>"], entity="<name>", unknown="<name>", console="<name>"
)
local["vanilla"] = {
    "format_player": "<display_name>",
    "format_entity": "<display_name>",
    "types": deaths,
}

# FlectonePulse otherwise fetches vanilla translations independently at startup.
vanilla_file = output / "minecraft/26.3/lang/en_us.json"
vanilla_file.parent.mkdir(parents=True, exist_ok=True)
vanilla_file.write_bytes(language_bytes)

for name, value in {**defaults, "localizations/en_us": english}.items():
    destination = output / f"{name}.yml"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(yaml.safe_dump(value, sort_keys=False, allow_unicode=True))
