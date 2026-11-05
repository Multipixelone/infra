#!/usr/bin/env python3
"""Focused, offline checks using the locked nixpkgs and HA 2026.10.2.

Run with the pinned HA package's Python interpreter (Python 3.14):
  agent-run-long --label finn-controls --timeout 5m -- \
    python modules/iot/tests/commute_controls_test.py --baseline 678a54d6b \
      --ha-package /nix/store/<hash>-homeassistant-2026.10.2

--ha-package loads the dependency paths from Nix's installed hass entry point;
without it, use a Python environment already containing HA 2026.10.2.

No HA server is started, credentials loaded, or external services called. Nix
only evaluates these two modules, not the host. Runtime tests use a temporary
HomeAssistant instance and record the nap service instead of scheduling a nap.
"""

import argparse
import ast
import asyncio
import copy
import logging
import re
import site
import socket
import subprocess
import tempfile
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
ENTITY = "input_button.commute_nap_30"


def generated(source, nixpkgs):
    # Capture exactly the values passed to the module's YAML generator, keeping
    # filenames coercible without building a host or accessing private inputs.
    expr = r"""
      let
        pkgs = import NIXPKGS { system = builtins.currentSystem; };
        capture = pkgs // { formats.yaml = _: {
          generate = name: value: { inherit value; __toString = _: name; };
        }; };
        dashboard = ((import (SOURCE + "/dashboard-home.nix")) {}).configurations.nixos.iot.module {
          pkgs = capture; lib = pkgs.lib;
          roomieorderButtons.dashboardCardsByOwner = REORDER;
        };
        alarm = (import (SOURCE + "/commutecompass-alarm.nix")).configurations.nixos.iot.module;
      in {
        hassVersion = pkgs.home-assistant.version;
        finn = (builtins.elemAt dashboard.systemd.services.home-assistant.reloadTriggers 1).value;
        home = (builtins.elemAt dashboard.systemd.services.home-assistant.reloadTriggers 0).value;
        inherit alarm;
      }
    """.replace("NIXPKGS", nixpkgs).replace("SOURCE", str(source))
    results = []
    for reorder in ("{}", '{ Finn = { type = "grid"; cards = []; }; }'):
        result = subprocess.run(  # noqa: PLW1510 - returncode is checked explicitly
            [
                "nix",
                "eval",
                "--offline",
                "--impure",
                "--json",
                "--expr",
                expr.replace("REORDER", reorder),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode:
            raise RuntimeError(
                f"Nix generation failed ({result.returncode}):\n{result.stderr}"
            )
        # Exercise the real pinned Nix YAML generator as well as evaluating the
        # module values. Parse its artifact before making structural assertions.
        with tempfile.TemporaryDirectory(
            prefix="finn-yaml-", dir="/tmp/opencode"
        ) as tmp:
            data = Path(tmp) / "module.json"
            data.write_text(result.stdout)
            yaml_expr = f"""let pkgs = import {nixpkgs} {{ system = builtins.currentSystem; }};
              in (pkgs.formats.yaml {{}}).generate "finn-controls.yaml"
                (builtins.fromJSON (builtins.readFile {data}))"""
            build = subprocess.run(  # noqa: PLW1510 - returncode is checked explicitly
                [
                    "nix",
                    "build",
                    "--offline",
                    "--impure",
                    "--no-link",
                    "--print-out-paths",
                    "--expr",
                    yaml_expr,
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=60,
            )
            if build.returncode:
                raise RuntimeError(
                    f"Nix YAML build failed ({build.returncode}):\n{build.stderr}"
                )
            import yaml

            results.append(yaml.safe_load(Path(build.stdout.strip()).read_text()))
    return results


def structural_checks(old, new):
    for baseline, current in zip(old, new, strict=True):
        preserved = copy.deepcopy(current)
        section = preserved["finn"]["views"][0]["sections"].pop(0)
        assert preserved["finn"] == baseline["finn"], "existing Finn content changed"
        assert current["home"] == baseline["home"], "shared dashboard changed"
        assert section["cards"][0]["heading"] == "CommuteCompass"

        # Controls may be nested in phase-aware conditionals; do not freeze the
        # obsolete blanket ringing/snoozed layout.
        def cards(value):
            if isinstance(value, dict):
                yield value
                for child in value.values():
                    yield from cards(child)
            elif isinstance(value, list):
                for child in value:
                    yield from cards(child)

        all_cards = list(cards(section))
        for target in ("commute_alarm_stop", "commute_alarm_snooze", "commute_nap_30"):
            assert any(
                card.get("tap_action")
                == {
                    "action": "perform-action",
                    "perform_action": "input_button.press",
                    "target": {"entity_id": "input_button." + target},
                }
                for card in all_cards
            ) or any(
                "input_button." + target in card.get("filter", {}).get("template", "")
                for card in all_cards
            ), target  # Dynamic dashboard templates are executed in the runtime lane.
        old_alarm = copy.deepcopy(baseline["alarm"])
        new_alarm = copy.deepcopy(current["alarm"])
        before = next(
            a
            for a in old_alarm["iotHass"]["nixAutomations"]
            if a["id"] == "commute_nap_30"
        )
        after = next(
            a
            for a in new_alarm["iotHass"]["nixAutomations"]
            if a["id"] == "commute_nap_30"
        )
        assert after["action"] == [
            {"service": "script.commute_nap", "data": {"minutes": 30}}
        ]
        before["trigger"] = after["trigger"]
        assert before == after, "nap first-press automation changed beyond its trigger"
        # Preserve the unrelated safety/Clock lanes exactly; publication and
        # wake-window helpers/scripts intentionally evolve in the new contract.
        for key in (
            "commute_alarm_fallback_check",
            "commute_set_tomorrow_alarm",
            "commute_nap",
        ):
            old_script = next(
                s for s in old_alarm["iotHass"]["nixScripts"] if s["id"] == key
            )
            new_script = next(
                s for s in new_alarm["iotHass"]["nixScripts"] if s["id"] == key
            )
            assert old_script == new_script, f"legacy safety script changed: {key}"
        for key in (
            "commute_alarm_confirmation_warning",
            "commute_alarm_offline_fallback",
        ):
            old_items = [
                a for a in old_alarm["iotHass"]["nixAutomations"] if a["id"] == key
            ]
            new_items = [
                a for a in new_alarm["iotHass"]["nixAutomations"] if a["id"] == key
            ]
            assert old_items and old_items == new_items, (
                f"legacy automation changed: {key}"
            )
    print(
        "PASS generated structure: existing dashboards and legacy fallback/confirmation/Clock/nap safety preserved"
    )


async def runtime_checks(old, new, config_dir):
    from homeassistant import loader
    from homeassistant.components.automation.config import async_validate_config_item
    from homeassistant.const import __version__
    from homeassistant.core import HomeAssistant
    from homeassistant.helpers import (
        area_registry as ar,
    )
    from homeassistant.helpers import (
        device_registry as dr,
    )
    from homeassistant.helpers import (
        entity_registry as er,
    )
    from homeassistant.helpers import floor_registry as fr
    from homeassistant.helpers import label_registry as lr
    from homeassistant.helpers.trigger import (
        async_initialize_triggers,
    )
    from homeassistant.helpers.trigger import (
        async_setup as setup_triggers,
    )

    assert __version__ == new[0]["hassVersion"] == "2026.10.2", __version__
    hass = HomeAssistant(str(config_dir))
    hass.config.skip_pip = True
    loader.async_setup(hass)
    await setup_triggers(hass)
    dr.async_setup(hass)
    for registry in (fr, lr, ar, dr, er):
        await registry.async_load(hass)
    calls = []

    async def record(call):
        calls.append(dict(call.data))

    hass.services.async_register("script", "commute_nap", record)
    try:
        for dataset, expected in ((old, 0), (new, 1)):
            automation = next(
                a
                for a in dataset[0]["alarm"]["iotHass"]["nixAutomations"]
                if a["id"] == "commute_nap_30"
            )
            validated = await async_validate_config_item(
                hass, "automation", copy.deepcopy(automation)
            )
            assert validated is not None
            print("PASS pinned HA automation validator:", automation["trigger"])
            calls.clear()

            async def action(variables, context=None, automation=automation):
                for step in automation["action"]:
                    domain, service = step["service"].split(".")
                    await hass.services.async_call(
                        domain, service, step["data"], blocking=True
                    )

            if not expected:
                hass.states.async_set(ENTITY, "unknown")
                await hass.async_block_till_done()
            remove = await async_initialize_triggers(
                hass,
                validated["triggers"],
                action,
                "test",
                "nap",
                logging.getLogger(__name__).log,
            )
            assert remove is not None
            hass.states.async_set(ENTITY, "unknown")
            await hass.async_block_till_done()
            assert calls == [], "startup unknown scheduled nap"
            hass.states.async_set(ENTITY, "2026-11-03T12:00:00+00:00")
            await hass.async_block_till_done()
            assert len(calls) == expected, ("first press", calls, expected)
            print(
                "PASS first press:",
                "old guard reproduces dropped press (red)"
                if expected == 0
                else "new trigger invokes minutes=30 once (green)",
            )
            if expected:
                assert calls == [{"minutes": 30}]
                for state, attrs in (
                    ("2026-11-03T12:00:00+00:00", {"friendly_name": "changed"}),
                    ("unavailable", {}),
                    ("2026-11-03T12:01:00+00:00", {}),
                ):
                    hass.states.async_set(ENTITY, state, attrs)
                    await hass.async_block_till_done()
                    assert len(calls) == 1, "attribute/recovery caused nap"
                hass.states.async_remove(ENTITY)
                await hass.async_block_till_done()
                hass.states.async_set(ENTITY, "2026-11-03T12:02:00+00:00")
                await hass.async_block_till_done()
                assert len(calls) == 1, "restored initial publication caused nap"
                hass.states.async_set(ENTITY, "2026-11-03T12:03:00+00:00")
                await hass.async_block_till_done()
                assert calls == [{"minutes": 30}, {"minutes": 30}]
                print(
                    "PASS no nap on unchanged attributes, unavailable recovery, removal/restored publication; subsequent press once"
                )

                # Exercise the actual helper's first-press and restore paths,
                # not just synthetic state-change events.
                from homeassistant.components.input_button import InputButton
                from homeassistant.helpers import restore_state

                await restore_state.async_load(hass, load_empty=True)
                for restored in (None, "2026-11-03T10:00:00+00:00"):
                    from homeassistant.core import State
                    from homeassistant.util import dt as dt_util

                    hass.states.async_remove(ENTITY)
                    await hass.async_block_till_done()
                    data = restore_state.async_get(hass)
                    data.last_states.clear()
                    if restored:
                        data.last_states[ENTITY] = restore_state.StoredState(
                            State(ENTITY, restored), None, dt_util.utcnow()
                        )
                    button = InputButton.from_yaml({"id": "commute_nap_30"})
                    button.hass = hass
                    from types import SimpleNamespace

                    button.platform = SimpleNamespace(
                        platform_name="input_button", config_entry=None
                    )
                    count = len(calls)
                    await button.async_internal_added_to_hass()
                    from homeassistant.helpers.entity import EntityPlatformState

                    button._platform_state = EntityPlatformState.ADDED
                    button.async_write_ha_state()
                    await hass.async_block_till_done()
                    assert len(calls) == count, "helper restoration caused nap"
                    assert hass.states.get(ENTITY).state == (restored or "unknown")
                    await button._async_press_action()
                    await hass.async_block_till_done()
                    assert len(calls) == count + 1 and calls[-1] == {"minutes": 30}
                    await button._async_press_action()
                    await hass.async_block_till_done()
                    assert len(calls) == count + 2
                    await button.async_internal_will_remove_from_hass()
                print(
                    "PASS real InputButton: unpressed/restored initialization silent; first and subsequent presses exactly once"
                )
            remove()
            hass.states.async_remove(ENTITY)
            await hass.async_block_till_done()
    finally:
        await hass.async_stop(force=True)


def add_ha_package(package):
    """Load precisely the dependency closure used by the installed HA wrapper."""
    wrapper = (Path(package) / "bin/.hass-wrapped").read_text()
    match = re.search(
        r"functools.reduce\(lambda k, p: site.addsitedir\(p, k\), (\[.*?\]),", wrapper
    )
    if not match:
        raise RuntimeError("Unrecognized Nix hass dependency wrapper")
    for path in ast.literal_eval(match.group(1)):
        site.addsitedir(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="pre-change Git revision")
    parser.add_argument(
        "--ha-package", type=Path, help="installed pinned HA Nix package"
    )
    args = parser.parse_args()
    if args.ha_package:
        add_ha_package(args.ha_package)
    nixpkgs = subprocess.run(
        [
            "nix",
            "eval",
            "--offline",
            "--impure",
            "--raw",
            "--expr",
            "(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    ).stdout
    with tempfile.TemporaryDirectory(
        prefix="finn-controls-", dir="/tmp/opencode"
    ) as tmp:
        tmp = Path(tmp)
        # Preserve relative module imports when evaluating historical sources.
        source = tmp / "modules" / "iot"
        source.mkdir(parents=True)
        (tmp / "lib").mkdir()
        (tmp / "lib" / "commute-alarm.nix").write_bytes(
            (ROOT / "lib" / "commute-alarm.nix").read_bytes()
        )
        for name in ("dashboard-home.nix", "commutecompass-alarm.nix"):
            (source / name).write_bytes(
                subprocess.check_output(
                    ["git", "show", f"{args.baseline}:modules/iot/{name}"], cwd=ROOT
                )
            )
        old = generated(source, nixpkgs)
        new = generated(ROOT / "modules/iot", nixpkgs)
        structural_checks(old, new)
        (tmp / "ha").mkdir()

        # Fail closed if an integration unexpectedly attempts external I/O.
        def deny_network(*args, **kwargs):
            raise AssertionError("network access forbidden in isolated HA test")

        with ExitStack() as network_guard:
            for method in ("connect", "connect_ex", "bind", "sendto", "sendmsg"):
                network_guard.enter_context(
                    patch.object(socket.socket, method, deny_network)
                )
            asyncio.run(runtime_checks(old, new, tmp / "ha"))


if __name__ == "__main__":
    main()
