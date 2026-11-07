#!/usr/bin/env python3
"""Offline regression lane against generated Nix values and HA 2026.10.2.

See README.md in this directory for the reproducible invocation. No daemon, HA
server, private config, or device is contacted. Only synthetic link TOML is read.
"""

import argparse
import copy
import json
import logging
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
from commute_controls_test import ROOT, add_ha_package


def capture(nixpkgs):
    """Merge the actual contributing modules, not Python copies of their logic."""
    with tempfile.TemporaryDirectory(
        prefix="commute-input-", dir="/tmp/opencode"
    ) as tmp:
        private = Path(tmp) / "commutecompass"
        private.mkdir()
        # No real origin or credentials, even in captured output/error messages.
        (private / "config.toml").write_text("[alarm]\nenabled = false\n")
        expr = (
            r"""
          let
            pkgs = import NIXPKGS { system = builtins.currentSystem; };
            lib = pkgs.lib;
            capture = pkgs // { formats = pkgs.formats // {
              yaml = _: { generate = name: value: { inherit value; __toString = _: name; }; };
              toml = _: { generate = name: value: { inherit value; __toString = _: name; }; };
            }; };
            inputs = { secrets = PRIVATE; commutecompass.nixosModules.default = {}; };
            home = (import (ROOT + "/modules/iot/homeassistant.nix") {
              inherit inputs lib; withSystem = _: _: null;
            }).configurations.nixos.iot.module;
            dashboard = ((import (ROOT + "/modules/iot/dashboard-home.nix")) {}).configurations.nixos.iot.module;
            mergeType = lib.mkOptionType {
              name = "captured-module-values";
              check = _: true;
              merge = loc: defs:
                if builtins.all (d: builtins.isList d.value) defs then lib.concatMap (d: d.value) defs
                else if builtins.all (d: builtins.isAttrs d.value) defs then (lib.types.attrsOf mergeType).merge loc defs
                else lib.types.anything.merge loc defs;
            };
            merged = lib.evalModules {
              specialArgs = { pkgs = capture; roomieorderButtons.dashboardCardsByOwner = {}; };
              modules = [
                { options = builtins.listToAttrs (map (name: {
                    inherit name; value = lib.mkOption { type = mergeType; default = {}; };
                  }) [ "services" "systemd" "environment" "networking" "age" ]);
                }
                home dashboard
                (import (ROOT + "/modules/iot/meds-reminder.nix")).configurations.nixos.iot.module
                (import (ROOT + "/modules/iot/commutecompass-alarm.nix")).configurations.nixos.iot.module
                (if builtins.pathExists (ROOT + "/modules/iot/commutecompass-wake-window.nix") then
                  (import (ROOT + "/modules/iot/commutecompass-wake-window.nix")).configurations.nixos.iot.module
                 else {})
              ];
            };
            link = (import (ROOT + "/modules/link/commutecompass.nix") { inherit inputs; }).configurations.nixos.link.module {
              pkgs = capture; inherit lib; config.age.secrets.commutecompass.path = "/unused-test-token";
            };
            cfg = merged.config;
          in {
            hassVersion = pkgs.home-assistant.version;
            hass = cfg.services.home-assistant.config;
            automations = cfg.iotHass.nixAutomations;
            scripts = builtins.listToAttrs (map (s: { name = s.id; value = builtins.removeAttrs s [ "id" ]; }) cfg.iotHass.nixScripts);
            dashboards = map (x: x.value) (builtins.filter (x: builtins.isAttrs x && x ? value && x.value ? views) cfg.systemd.services.home-assistant.reloadTriggers);
            linkAlarm = link.services.commutecompass.configFile.value.alarm;
            contract = import (ROOT + "/lib/commute-alarm.nix");
            # Other modules' components are null under the withSystem stub.
            customComponentDrvs = map (c: c.drvPath) (builtins.filter
              (c: builtins.isAttrs c && lib.hasPrefix "commute_" (c.domain or ""))
              (cfg.services.home-assistant.customComponents or []));
          }
        """.replace("NIXPKGS", nixpkgs)
            .replace("PRIVATE", json.dumps(tmp))
            .replace("ROOT", str(ROOT))
        )
        result = subprocess.run(  # noqa: PLW1510 - returncode is checked explicitly
            ["nix", "eval", "--offline", "--impure", "--json", "--expr", expr],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode:
            raise RuntimeError("Nix capture failed:\n" + result.stderr)
        generated = json.loads(result.stdout)
        # Realise the actual generated custom components (local runCommand only).
        generated["customComponents"] = []
        for drv in generated.pop("customComponentDrvs"):
            out = subprocess.run(  # noqa: PLW1510 - returncode is checked explicitly
                ["nix-store", "--realise", drv],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=300,
            )
            if out.returncode:
                raise RuntimeError("custom component build failed:\n" + out.stderr)
            generated["customComponents"].append(out.stdout.strip().splitlines()[-1])
        return generated


class Runtime:
    """Real HA helpers/scripts/triggers; only outbound device services are fakes."""

    def __init__(
        self, generated, restored=None, restore_file=None, automations=(), prestart=None
    ):
        self.generated = generated
        # Generated automations armed BEFORE hass.async_start, so the real
        # `homeassistant: start` trigger fires; prestart seeds non-restored
        # (REST/device) states that exist when HA finishes starting.
        self.automations = set(automations)
        self.prestart = prestart
        self.fail_services = set()
        self.automation_errors = []
        self.restored = restored or {}
        # Raw .storage/core.restore_state content (dict) seen by the bootstrap
        # component; None means a genuinely new install with no file.
        self.restore_file = restore_file
        self.calls = []
        self.fail_targets = set()
        self.removers = []
        self.scripts = {}
        self.now = datetime(2026, 11, 4, 12, tzinfo=UTC)
        self.stack = ExitStack()

    async def __aenter__(self):
        import socket

        from homeassistant import loader
        from homeassistant.core import HomeAssistant
        from homeassistant.setup import async_setup_component
        from homeassistant.util import dt

        self.temp = tempfile.TemporaryDirectory(
            prefix="commute-ha-", dir="/tmp/opencode"
        )
        self.hass = HomeAssistant(self.temp.name)
        self.hass.config.time_zone = "America/New_York"
        self.hass.config.skip_pip = True
        import shutil

        components = Path(self.temp.name) / "custom_components"
        components.mkdir()
        (components / "__init__.py").write_text("")
        for package in self.generated.get("customComponents", []):
            for entry in (Path(package) / "custom_components").iterdir():
                shutil.copytree(entry, components / entry.name)
        if self.restore_file is not None:
            (Path(self.temp.name) / ".storage").mkdir()
            from homeassistant.helpers.json import JSONEncoder

            body = (
                self.restore_file
                if isinstance(self.restore_file, str)
                else json.dumps(self.restore_file, cls=JSONEncoder)
            )
            (Path(self.temp.name) / ".storage" / "core.restore_state").write_text(body)
        for name in [
            m
            for m in sys.modules
            if m == "custom_components" or m.startswith("custom_components.")
        ]:
            sys.modules.pop(name)
        loader.async_setup(self.hass)
        from homeassistant.config_entries import ConfigEntries

        self.hass.config_entries = ConfigEntries(self.hass, {})
        await self.hass.config_entries.async_initialize()
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
        from homeassistant.helpers.trigger import async_setup as setup_triggers

        await setup_triggers(self.hass)
        dr.async_setup(self.hass)
        for registry in (fr, lr, ar, dr, er):
            await registry.async_load(self.hass)
        for method in ("connect", "connect_ex", "bind", "sendto", "sendmsg"):
            self.stack.enter_context(
                patch.object(
                    socket.socket,
                    method,
                    side_effect=AssertionError("network forbidden"),
                )
            )
        self.stack.enter_context(
            patch.object(dt, "utcnow", side_effect=lambda: self.now)
        )
        self.stack.enter_context(
            patch.object(
                dt,
                "now",
                side_effect=lambda tz=None: self.now.astimezone(
                    tz or dt.DEFAULT_TIME_ZONE
                ),
            )
        )
        from homeassistant.core import State
        from homeassistant.helpers import restore_state

        # With a restore file, HA and the bootstrap read the same real store.
        await restore_state.async_load(self.hass, load_empty=self.restore_file is None)
        for entity, value in self.restored.items():
            restore_state.async_get(self.hass).last_states[entity] = (
                restore_state.StoredState(State(entity, value), None, self.now)
            )
        # Real helper integrations provide validation, state writes, service calls,
        # input_button timestamps and restore behavior. Do not fake these services.
        for domain in (
            "input_boolean",
            "input_text",
            "input_datetime",
            "input_select",
            "input_number",
            "input_button",
        ):
            helpers = self.generated["hass"].get(domain, {})
            if helpers:
                assert await async_setup_component(
                    self.hass, domain, {domain: helpers}
                ), domain
        await self.hass.async_block_till_done()
        # Actual generated custom components (e.g. the wake ledger bootstrap),
        # set up from their own generated config after helper restore.
        for package in self.generated.get("customComponents", []):
            for entry in (Path(package) / "custom_components").iterdir():
                if entry.name in self.generated["hass"]:
                    assert await async_setup_component(
                        self.hass,
                        entry.name,
                        {entry.name: self.generated["hass"][entry.name]},
                    ), entry.name
        await self.hass.async_block_till_done()
        blocks = [
            block
            for block in self.generated["hass"].get("template", [])
            if "commute_" in json.dumps(block)
        ]
        if blocks:
            assert await async_setup_component(
                self.hass, "template", {"template": blocks}
            ), "template"
            await self.hass.async_block_till_done()
        await self.install_scripts()
        for domain, services in {
            "light": ["turn_on", "turn_off"],
            "switch": ["turn_on", "turn_off"],
            "select": ["select_option"],
            "number": ["set_value"],
            "notify": ["mobile_app_nougat"],
            "scene": ["create", "turn_on"],
        }.items():
            for service in services:
                self.hass.services.async_register(domain, service, self.device)
        # Scheduler clock: HA's time trackers use these module aliases.
        from homeassistant.helpers import event as ha_event

        self.stack.enter_context(
            patch.object(ha_event, "time_tracker_utcnow", side_effect=lambda: self.now)
        )
        self.stack.enter_context(
            patch.object(
                ha_event,
                "time_tracker_timestamp",
                side_effect=lambda: self.now.timestamp() + 0.999,
            )
        )
        if self.prestart:
            await self.prestart(self)
        if self.automations:
            await self.attach(self.automations)
        await self.hass.async_start()
        await self.hass.async_block_till_done()
        return self

    async def __aexit__(self, *exc):
        for remove in self.removers:
            remove()
        for script in self.scripts.values():
            await script.async_stop()
        await self.hass.async_stop(force=True)
        self.stack.close()
        self.temp.cleanup()

    async def device(self, call):
        data = dict(call.data)
        # HA normalizes service targets to one-element lists. Canonicalize only
        # the observation, never the service inputs or actual Script actions.
        if isinstance(data.get("entity_id"), list) and len(data["entity_id"]) == 1:
            data["entity_id"] = data["entity_id"][0]
        self.calls.append((call.domain, call.service, data))
        if call.domain in self.fail_services:
            from homeassistant.exceptions import HomeAssistantError

            raise HomeAssistantError("synthetic service failure")
        targets = call.data.get("entity_id", [])
        if isinstance(targets, str):
            targets = [targets]
        for target in targets:
            previous = self.hass.states.get(target)
            if target in self.fail_targets or (
                previous and previous.state == "unavailable"
            ):
                from homeassistant.exceptions import HomeAssistantError

                raise HomeAssistantError("synthetic device unavailable")
            if call.domain in ("switch", "select", "number"):
                value = call.data.get(
                    "option",
                    call.data.get(
                        "value", "on" if call.service == "turn_on" else "off"
                    ),
                )
                self.hass.states.async_set(
                    target, str(value), previous.attributes if previous else {}
                )

    async def install_scripts(self):
        from homeassistant.components.script.config import SCRIPT_ENTITY_SCHEMA
        from homeassistant.core import Context
        from homeassistant.helpers.script import Script, async_validate_actions_config

        for name, body in self.generated["scripts"].items():
            sequence = await async_validate_actions_config(
                self.hass, SCRIPT_ENTITY_SCHEMA(copy.deepcopy(body))["sequence"]
            )
            script = self.scripts[name] = Script(
                self.hass,
                sequence,
                name,
                "script",
                script_mode=body.get("mode", "single"),
            )

            async def invoke(call, script=script):
                return await script.async_run(
                    dict(call.data), call.context or Context()
                )

            self.hass.services.async_register("script", name, invoke)

    async def run_automation(self, name, **variables):
        from homeassistant.components.automation.config import (
            async_validate_config_item,
        )
        from homeassistant.core import Context
        from homeassistant.helpers import condition
        from homeassistant.helpers.script import Script

        raw = next(a for a in self.generated["automations"] if a.get("id") == name)
        validated = await async_validate_config_item(
            self.hass, "automation", copy.deepcopy(raw)
        )
        assert validated is not None
        checks = [
            await condition.async_from_config(self.hass, item)
            for item in validated.get("conditions", [])
        ]
        if all(check(self.hass, variables) for check in checks):
            script = Script(self.hass, validated["actions"], name, "automation")
            self.scripts["direct:" + name] = script
            await script.async_run(variables, Context())
        await self.hass.async_block_till_done()

    async def run(self, name, **variables):
        from homeassistant.core import Context

        await self.scripts[name].async_run(variables, Context())
        await self.hass.async_block_till_done()

    async def attach(self, ids):
        from homeassistant.components.automation.config import (
            async_validate_config_item,
        )
        from homeassistant.core import Context
        from homeassistant.helpers import condition
        from homeassistant.helpers.script import Script
        from homeassistant.helpers.trigger import async_initialize_triggers

        for raw in self.generated["automations"]:
            if raw.get("id") not in ids:
                continue
            config = await async_validate_config_item(
                self.hass, "automation", copy.deepcopy(raw)
            )
            assert config is not None, raw["id"]
            script = Script(
                self.hass,
                config["actions"],
                raw["id"],
                "automation",
                script_mode=raw.get("mode", "single"),
            )
            self.scripts["automation:" + raw["id"]] = script
            checks = [
                await condition.async_from_config(self.hass, item)
                for item in config.get("conditions", [])
            ]

            async def action(variables, context=None, script=script, checks=checks):
                from homeassistant.exceptions import HomeAssistantError

                if all(check(self.hass, variables) for check in checks):
                    # Like a real automation run: a failed action is logged,
                    # and the automation stays armed for the next trigger.
                    try:
                        await script.async_run(variables, context or Context())
                    except HomeAssistantError as err:
                        self.automation_errors.append(str(err))

            remove = await async_initialize_triggers(
                self.hass,
                config["triggers"],
                action,
                "automation",
                raw["id"],
                lambda *args, **kwargs: None,
            )
            assert remove is not None, raw["id"]
            self.removers.append(remove)
        assert len(self.removers) >= len(ids), f"missing automation IDs: {ids}"

    async def tick(self, seconds):
        """Advance the controlled clock and fire HA's due point-in-time timers
        (time_pattern triggers), as HA's own async_fire_time_changed does."""
        from homeassistant.helpers.event import _TrackPointUTCTime
        from homeassistant.util.async_ import get_scheduled_timer_handles

        self.now += timedelta(seconds=seconds)
        # Trackers carry a sub-second jitter; like HA's async_fire_time_changed,
        # fire timers due within this second.
        horizon = self.now.timestamp() + 0.999
        for handle in get_scheduled_timer_handles(self.hass.loop):
            target = getattr(handle, "_callback", None)
            if (
                not handle.cancelled()
                and isinstance(target, _TrackPointUTCTime)
                and target.expected_fire_timestamp <= horizon
            ):
                handle.cancel()
                target()
        await self.hass.async_block_till_done(wait_background_tasks=True)

    def snapshot_store(self):
        """A real core.restore_state body from the current helper states."""
        from homeassistant.helpers.json import JSONEncoder

        data = [
            {
                "state": json.loads(json.dumps(state.as_dict(), cls=JSONEncoder)),
                "extra_data": None,
                "last_seen": self.now.isoformat(),
            }
            for state in self.hass.states.async_all(("input_text", "input_boolean"))
        ]
        return {
            "version": 1,
            "minor_version": 1,
            "key": "core.restore_state",
            "data": data,
        }

    async def set(self, entity, value, attributes=None):
        self.hass.states.async_set(entity, str(value), attributes or {})
        await self.hass.async_block_till_done()

    def state(self, entity):
        state = self.hass.states.get(entity)
        return state.state if state else None


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def status(
    now,
    phase="window",
    kind="wake",
    session="a" * 32,
    ring="b" * 32,
    state="ringing",
    **extra,
):
    def iso(value):
        return value.isoformat(timespec="seconds").replace("+00:00", "Z")

    deadline = now + timedelta(hours=1)
    attributes = {
        "schema": 1,
        "observed_at": iso(now),
        "session": {
            "id": session,
            "kind": kind,
            "phase": phase,
            "wake_at": iso(now),
            "original_at": iso(now),
            "locked_deadline_at": iso(deadline),
            "deadline_at": iso(deadline),
            "plan_id": "c" * 32,
        },
        "ring": {
            "id": ring,
            "started_at": iso(now),
            "checked_at": iso(now),
            "playback": "running",
        },
        "audio_failed": False,
        "snooze_until": None,
        "ended": {"wake": None, "nap": None},
    }
    attributes.update(extra)
    return state, attributes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ha-package", required=True)
    parser.add_argument("--nixpkgs", required=True)
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument(
        "--test",
        action="append",
        default=[],
        help="Run only a named test (repeatable); default runs the complete focused lane",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Skip a named test (repeatable), e.g. the mechanism-specific bootstrap lane",
    )
    args = parser.parse_args()
    add_ha_package(args.ha_package)
    from homeassistant.const import __version__

    assert __version__ == "2026.10.2", __version__
    generated = capture(args.nixpkgs)
    assert generated["hassVersion"] == __version__
    print(f"HA {__version__}: {args.ha_package}")
    if args.capture_only:
        print(
            "Captured merged HA configuration, scripts, automations, dashboards, synthetic link alarm TOML"
        )
        return
    run_tests(generated, args.test, args.exclude)


def run_tests(generated, selected=(), excluded=()):
    class Cases(unittest.IsolatedAsyncioTestCase):
        async def test_startup_bootstrap_owner_ledger(self):
            """Actual generated bootstrap component against real restore stores.

            Mechanism-specific: runs only the integration source Nix generates.
            Under review; if it is replaced by a native mechanism this skips and
            the behaviour stays covered by the first-install/restart tests."""
            from homeassistant.core import State

            owner = "input_text.commute_alarm_light_owner"
            if "commute_wake_bootstrap" not in generated["hass"]:
                self.skipTest("no generated commute_wake_bootstrap integration")
            self.assertTrue(
                generated["customComponents"],
                "bootstrap configured but its component was not realised",
            )

            def store(*entries):
                return {
                    "version": 1,
                    "minor_version": 1,
                    "key": "core.restore_state",
                    "data": [
                        {
                            "state": State(entity, value).as_dict(),
                            "extra_data": None,
                            "last_seen": "2026-11-04T11:59:00+00:00",
                        }
                        for entity, value in entries
                    ],
                }

            held = (
                'v1:{"p":"held","w":1793790000,"d":1793793600,"s":"'
                + "a" * 32
                + '","o":"Auto","r":"on","c":-1,"a":1793790000}'
            )
            unrelated = ("input_boolean.commute_alarm_enabled", "on")
            cases = [
                # No saved owner entry + native unknown: initialise once.
                ("no restore file (new install)", None, "v1:{}"),
                (
                    "restore file with only unrelated entries",
                    store(unrelated, ("input_text.commute_alarm_phone_claim", "v1:{}")),
                    "v1:{}",
                ),
                # HA moves an unreadable store aside, so no entry was saved.
                ("unreadable restore file", "{not json", "v1:{}"),
                # Any saved owner entry is retained verbatim, whatever its value.
                ("restored empty ledger", store(unrelated, (owner, "v1:{}")), "v1:{}"),
                ("restored held ledger", store(unrelated, (owner, held)), held),
                ("restored unknown ledger", store((owner, "unknown")), "unknown"),
                (
                    "restored unavailable ledger",
                    store((owner, "unavailable")),
                    "unavailable",
                ),
                ("restored blank ledger", store((owner, "")), ""),
                ("restored corrupt ledger", store((owner, 'v1:{"p":')), 'v1:{"p":'),
            ]
            for label, restore_file, expected in cases:
                with self.subTest(label):
                    async with Runtime(generated, restore_file=restore_file) as runtime:
                        self.assertEqual(runtime.state(owner), expected, label)
                        owned = runtime.state(
                            "binary_sensor.commute_alarm_lights_owned"
                        )
                        # Only explicit v1:{} is free; blank/unknown/corrupt fail closed.
                        self.assertEqual(
                            owned, "off" if expected == "v1:{}" else "on", label
                        )
                        self.assertFalse(
                            [
                                c
                                for c in runtime.calls
                                if c[0] in ("light", "select", "switch")
                            ],
                            label,
                        )
                        # Repeat the actual generated setup: never mutates again.
                        import custom_components.commute_wake_bootstrap as bootstrap

                        before = runtime.hass.states.get(owner)
                        await bootstrap.async_setup(runtime.hass, {})
                        await runtime.hass.async_block_till_done()
                        after = runtime.hass.states.get(owner)
                        self.assertEqual(
                            (after.state, after.last_updated),
                            (before.state, before.last_updated),
                            label,
                        )
                        if restore_file is None:
                            # Restart persists the initialised ledger; it is retained.
                            store_body = runtime.snapshot_store()
            with self.subTest("restart after initialisation retains ledger"):
                async with Runtime(generated, restore_file=store_body) as runtime:
                    self.assertEqual(runtime.state(owner), "v1:{}")
            with self.subTest("recovery mode leaves native unknown"):
                async with Runtime(generated) as runtime:
                    import custom_components.commute_wake_bootstrap as bootstrap
                    from homeassistant.helpers import restore_state

                    restore_state.async_get(runtime.hass).last_states.pop(owner, None)
                    runtime.hass.states.async_set(owner, "unknown")
                    runtime.hass.config.recovery_mode = True
                    await bootstrap.async_setup(runtime.hass, {})
                    await runtime.hass.async_block_till_done()
                    self.assertEqual(runtime.state(owner), "unknown")
                    runtime.hass.config.recovery_mode = False

        async def test_helpers_restore_without_initial_override(self):
            restored = {
                "input_text.commute_alarm_phone_claim": 'v1:{"k":"retained-ring","v":true}',
                "input_text.commute_alarm_bedside_claim": "a" * 32,
                "input_text.commute_alarm_window_done_utc": "2026-11-04T11:00:00+00:00",
                "input_boolean.commute_alarm_enabled": "on",
                "input_text.commute_wake_utc": "2026-11-05T13:00:00+00:00",
                "input_text.commute_alarm_skipped_utc": "2026-11-04T13:00:00+00:00",
                "input_text.commute_manual_wake_policy": json.dumps(
                    {
                        "wake_at": "2026-11-05T13:00:00+00:00",
                        "deadline_at": "2026-11-05T13:19:30+00:00",
                        "snoozes": 3,
                    }
                ),
            }
            self.assertEqual(
                generated["hass"]["input_text"]["commute_manual_wake_policy"]["max"],
                255,
            )
            if "commute_alarm_deadline_utc" in generated["hass"].get("input_text", {}):
                restored["input_text.commute_alarm_deadline_utc"] = (
                    "2026-11-05T13:19:30+00:00"
                )
            async with Runtime(generated, restored) as runtime:
                for entity, value in restored.items():
                    self.assertEqual(runtime.state(entity), value, entity)
                    domain, key = entity.split(".")
                    self.assertNotIn("initial", generated["hass"][domain][key])
                for key in (
                    "commute_alarm_light_owner",
                    "commute_alarm_phone_claim",
                    "commute_alarm_bedside_claim",
                    "commute_alarm_window_done_utc",
                ):
                    self.assertNotIn(
                        "initial", generated["hass"]["input_text"][key], key
                    )

        async def test_deadline_optional_offset_clear_and_rollover_pairing(self):
            async with Runtime(generated) as runtime:
                self.assertIn(
                    "commute_alarm_deadline_utc",
                    generated["hass"].get("input_text", {}),
                )

                async def publish(wake, **extra):
                    await runtime.run("commute_publish_alarm", wake_at=wake, **extra)

                wake = "2026-11-04T07:00:00-05:00"
                deadline = "2026-11-04T08:00:00-05:00"
                await publish(wake, deadline_at=deadline)
                self.assertEqual(
                    runtime.state("input_text.commute_alarm_deadline_utc"),
                    "2026-11-04T13:00:00+00:00",
                )
                for extra in (
                    {},
                    {"deadline_at": ""},
                    {"deadline_at": "1970-01-01T00:00:00Z"},
                ):
                    await publish(wake, **extra)
                    self.assertEqual(
                        runtime.state("input_text.commute_alarm_deadline_utc"),
                        "1970-01-01T00:00:00+00:00",
                    )
                await publish(wake, deadline_at=deadline)
                original = runtime.state("input_text.commute_alarm_deadline_utc")
                for invalid in ("not-a-date", "2026-11-04T08:00:00", "unavailable"):
                    await publish("2026-11-05T07:00:00-05:00", deadline_at=invalid)
                    self.assertEqual(
                        runtime.state("input_text.commute_alarm_deadline_utc"), original
                    )
                    self.assertEqual(
                        runtime.state("input_text.commute_wake_utc"),
                        "2026-11-04T12:00:00+00:00",
                    )
                await runtime.set("input_boolean.commute_alarm_enabled", "on")
                # An ordinary tomorrow refresh must preserve BOTH just-due wake
                # and its deadline, rather than attaching tomorrow's L to today.
                await publish(
                    "2026-11-05T07:00:00-05:00", deadline_at="2026-11-05T08:00:00-05:00"
                )
                self.assertEqual(
                    runtime.state("input_text.commute_wake_utc"),
                    "2026-11-04T12:00:00+00:00",
                )
                self.assertEqual(
                    runtime.state("input_text.commute_alarm_deadline_utc"),
                    "2026-11-04T13:00:00+00:00",
                )
                await runtime.set(
                    "input_text.commute_alarm_skipped_utc", "2026-11-04T12:00:00+00:00"
                )
                await publish(
                    "2026-11-05T07:00:00-05:00", deadline_at="2026-11-05T08:00:00-05:00"
                )
                self.assertEqual(
                    runtime.state("input_text.commute_wake_utc"),
                    "2026-11-05T12:00:00+00:00",
                )
                self.assertEqual(
                    runtime.state("input_text.commute_alarm_deadline_utc"),
                    "2026-11-05T13:00:00+00:00",
                )

        async def test_manual_publish_exact_pair_json_and_count_boundaries(self):
            """Catch coercion, lost zero, lead subtraction and native JSON dict writes.

            The older publisher tests only exercise ordinary one-hour windows.
            These literal pairs come from the explicit 390-second snooze contract,
            not from the captured global lead or the publisher's output.
            """
            async with Runtime(generated) as runtime:
                for count, first, final in (
                    (0, "2026-11-05T10:00:00-05:00", "2026-11-05T10:00:00-05:00"),
                    (1, "2026-11-05T09:53:30-05:00", "2026-11-05T10:00:00-05:00"),
                    (3, "2026-11-05T09:40:30-05:00", "2026-11-05T10:00:00-05:00"),
                    (12, "2026-11-05T08:42:00-05:00", "2026-11-05T10:00:00-05:00"),
                    (
                        3,
                        "2026-11-05T09:40:30.123456-05:00",
                        "2026-11-05T10:00:00.123456-05:00",
                    ),
                ):
                    with self.subTest(snoozes=count, first=first):
                        await runtime.run(
                            "commute_publish_alarm",
                            wake_at=first,
                            deadline_at=final,
                            manual_snoozes=count,
                        )
                        expected_first = datetime.fromisoformat(first).astimezone(UTC)
                        expected_final = datetime.fromisoformat(final).astimezone(UTC)
                        self.assertEqual(
                            runtime.state("input_text.commute_wake_utc"),
                            expected_first.isoformat(),
                        )
                        self.assertEqual(
                            runtime.state("input_text.commute_alarm_deadline_utc"),
                            expected_final.isoformat(),
                            "the requested final must not move or lose precision",
                        )
                        raw = runtime.state("input_text.commute_manual_wake_policy")
                        self.assertIsInstance(raw, str)
                        self.assertLessEqual(len(raw), 255)
                        # Real input_text.set_value above must accept a string,
                        # not HA's native-template conversion to a dict. The
                        # daemon consumes bare JSON, with no ledger prefix.
                        policy = json.loads(raw)
                        self.assertEqual(
                            set(policy), {"wake_at", "deadline_at", "snoozes"}
                        )
                        self.assertIs(type(policy["snoozes"]), int)
                        self.assertEqual(policy["snoozes"], count)
                        for key, expected in (
                            ("wake_at", expected_first),
                            ("deadline_at", expected_final),
                        ):
                            instant = datetime.fromisoformat(policy[key])
                            self.assertEqual(instant.utcoffset(), timedelta(0))
                            self.assertEqual(instant, expected)

        async def test_manual_publish_rejects_before_any_helper_mutation(self):
            """Catch int coercion or validation after pair/cap/display/event writes.

            Existing invalid-deadline coverage checks only two UTC helpers.
            """
            async with Runtime(generated) as runtime:
                await runtime.run(
                    "commute_publish_alarm",
                    wake_at="2026-11-05T09:40:30-05:00",
                    deadline_at="2026-11-05T10:00:00-05:00",
                    manual_snoozes=3,
                    next_prep_at="2026-11-05T09:30:00-05:00",
                    next_event="Original event",
                )

                def helpers():
                    return {
                        s.entity_id: (s.state, dict(s.attributes), s.last_updated)
                        for s in runtime.hass.states.async_all()
                        if s.domain.startswith("input_")
                    }

                before = helpers()
                # Give coercible inputs the pair their coerced value would
                # accept, so geometry validation cannot hide a type-check bug.
                for count, first in (
                    (True, "09:53:30"),
                    (False, "10:00:00"),
                    (1.5, "09:53:30"),
                    (3.0, "09:40:30"),
                    (-1, "10:06:30"),
                    (13, "08:35:30"),
                    ("3", "09:40:30"),
                    ("0", "10:00:00"),
                    (None, "09:40:30"),
                ):
                    with self.subTest(invalid_count=count):
                        await runtime.run(
                            "commute_publish_alarm",
                            wake_at=f"2026-11-06T{first}-05:00",
                            deadline_at="2026-11-06T10:00:00-05:00",
                            manual_snoozes=count,
                            next_prep_at="2026-11-06T08:00:00-05:00",
                            next_event="Must not be written",
                        )
                        self.assertEqual(helpers(), before)
                # Count alone is insufficient: no missing, cleared, reversed or
                # global-lead-shaped anchor may masquerade as an explicit pair.
                for extra in (
                    {},
                    {"deadline_at": ""},
                    {"deadline_at": "1970-01-01T00:00:00Z"},
                    {"deadline_at": "2026-11-06T09:40:29-05:00"},
                    {"deadline_at": "2026-11-06T10:40:30-05:00"},
                    {"deadline_at": "2026-11-06T10:00:01-05:00"},
                ):
                    with self.subTest(invalid_pair=extra):
                        await runtime.run(
                            "commute_publish_alarm",
                            wake_at="2026-11-06T09:40:30-05:00",
                            manual_snoozes=3,
                            next_prep_at="2026-11-06T08:00:00-05:00",
                            next_event="Must not be written",
                            **extra,
                        )
                        self.assertEqual(helpers(), before)

        async def test_manual_policy_clear_and_rollover_are_paired(self):
            """Catch stale policy on ordinary publish or mixed-day rollover triples."""
            async with Runtime(generated) as runtime:
                for extra in ({}, {"manual_snoozes": ""}):
                    with self.subTest(clear=extra):
                        await runtime.run(
                            "commute_publish_alarm",
                            wake_at="2026-11-05T09:40:30-05:00",
                            deadline_at="2026-11-05T10:00:00-05:00",
                            manual_snoozes=3,
                        )
                        await runtime.run(
                            "commute_publish_alarm",
                            wake_at="2026-11-05T09:00:00-05:00",
                            deadline_at="2026-11-05T10:00:00-05:00",
                            **extra,
                        )
                        self.assertEqual(
                            runtime.state("input_text.commute_manual_wake_policy"), ""
                        )
                        self.assertEqual(
                            runtime.state("input_text.commute_wake_utc"),
                            "2026-11-05T14:00:00+00:00",
                        )
                await runtime.run(
                    "commute_publish_alarm",
                    wake_at="2026-11-04T07:00:00-05:00",
                    deadline_at="2026-11-04T07:19:30-05:00",
                    manual_snoozes=3,
                )
                entities = (
                    "input_text.commute_wake_utc",
                    "input_text.commute_alarm_deadline_utc",
                    "input_text.commute_manual_wake_policy",
                )
                original = {e: runtime.state(e) for e in entities}
                await runtime.set("input_boolean.commute_alarm_enabled", "on")
                for extra in ({}, {"manual_snoozes": 0}):
                    await runtime.run(
                        "commute_publish_alarm",
                        wake_at="2026-11-05T10:00:00-05:00",
                        deadline_at="2026-11-05T10:00:00-05:00",
                        **extra,
                    )
                    self.assertEqual({e: runtime.state(e) for e in entities}, original)
                # After the existing rollover grace expires an ordinary publish
                # installs tomorrow's pair and clears today's manual policy.
                runtime.now += timedelta(seconds=181)
                await runtime.run(
                    "commute_publish_alarm",
                    wake_at="2026-11-05T09:00:00-05:00",
                    deadline_at="2026-11-05T10:00:00-05:00",
                )
                self.assertEqual(
                    runtime.state(entities[0]), "2026-11-05T14:00:00+00:00"
                )
                self.assertEqual(
                    runtime.state(entities[1]), "2026-11-05T15:00:00+00:00"
                )
                self.assertEqual(runtime.state(entities[2]), "")

        async def test_generated_scripts_validate(self):
            async with Runtime(generated) as runtime:
                self.assertTrue(runtime.scripts)
                from homeassistant.components.automation.config import (
                    async_validate_config_item,
                )

                for automation in generated["automations"]:
                    if automation.get("id", "").startswith("commute_"):
                        self.assertIsNotNone(
                            await async_validate_config_item(
                                runtime.hass, "automation", copy.deepcopy(automation)
                            ),
                            automation["id"],
                        )

        async def test_nap_first_press_actual_trigger(self):
            async with Runtime(generated) as runtime:
                calls = []

                async def nap(call):
                    calls.append(dict(call.data))

                runtime.hass.services.async_register("script", "commute_nap", nap)
                await runtime.attach({"commute_nap_30"})
                await runtime.hass.services.async_call(
                    "input_button",
                    "press",
                    {"entity_id": "input_button.commute_nap_30"},
                    blocking=True,
                )
                await runtime.hass.async_block_till_done()
                self.assertEqual(calls, [{"minutes": 30}])

        async def window(self, runtime, seconds_to_first=600):
            # This fixture represents an ordinary publisher's legacy pair.
            await runtime.set("input_text.commute_manual_wake_policy", "")
            await runtime.set("input_text.commute_alarm_light_owner", "v1:{}")
            await runtime.set("input_text.commute_alarm_phone_claim", "v1:{}")
            await runtime.set("input_text.commute_alarm_bedside_claim", "")
            for helper in (
                "commute_alarm_skipped_utc",
                "commute_alarm_window_done_utc",
            ):
                await runtime.set("input_text." + helper, "1970-01-01T00:00:00+00:00")
            await runtime.set(
                "sensor.commute_alarm_status",
                "idle",
                {
                    "schema": 1,
                    "observed_at": runtime.now.isoformat().replace("+00:00", "Z"),
                    "session": None,
                    "ring": None,
                    "ended": {"wake": None, "nap": None},
                    "audio_failed": False,
                },
            )
            await runtime.set("input_boolean.commute_alarm_enabled", "on")
            await runtime.set("input_boolean.morning_meds_taken", "off")
            await runtime.set(
                "input_text.commute_wake_utc",
                (runtime.now + timedelta(seconds=seconds_to_first)).isoformat(),
            )
            await runtime.set(
                "input_text.commute_alarm_deadline_utc",
                (runtime.now + timedelta(seconds=seconds_to_first + 3600)).isoformat(),
            )
            await runtime.set(
                "select.fairy_lights_live_override", "1", {"options": ["0", "1", "2"]}
            )
            await runtime.set("switch.fairy_lights_sync_receive", "on")
            await runtime.set("light.fairy_lights", "off")

        async def test_effective_link_ha_timing_contract_and_light_boundary(self):
            async with Runtime(generated) as runtime:
                self.assertEqual(generated["linkAlarm"]["schedule_contract"], "legacy")
                self.assertEqual(
                    generated["linkAlarm"]["status_entity"],
                    "sensor.commute_alarm_status",
                )
                self.assertEqual(
                    generated["linkAlarm"]["window"]["first_alarm_lead_minutes"], 60
                )
                await self.window(runtime, 601)
                effective_lead = generated["linkAlarm"]["window"][
                    "first_alarm_lead_minutes"
                ]
                leave = runtime.now + timedelta(minutes=effective_lead, seconds=601)
                await runtime.set(
                    "input_text.commute_alarm_deadline_utc", leave.isoformat()
                )
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(
                    runtime.calls, "L-70 minus one second must not seize lights"
                )
                runtime.now += timedelta(seconds=1)
                await runtime.set(
                    "sensor.commute_alarm_status",
                    "idle",
                    {
                        "schema": 1,
                        "observed_at": runtime.now.isoformat().replace("+00:00", "Z"),
                        "session": None,
                        "ring": None,
                    },
                )
                await runtime.run("commute_alarm_reconcile")
                contract = runtime.hass.states.get(
                    "binary_sensor.commute_alarm_lights_owned"
                )
                self.assertIsNotNone(contract, "generated ownership sensor not set up")
                # This is the effective HA timing contract, not inspection of
                # shared source constants: with link's actual lead, ownership
                # starts precisely at L-(lead+fade), never one second earlier.
                self.assertEqual(contract.state, "on")
                calls = runtime.calls
                self.assertEqual(
                    [(d, s, c.get("option")) for d, s, c in calls[:2]],
                    [("select", "select_option", "2"), ("switch", "turn_off", None)],
                )
                fade = [c for d, s, c in calls if d == "light"]
                self.assertEqual(len(fade), 1)
                self.assertEqual(fade[0]["entity_id"], "light.fairy_lights")
                self.assertEqual(int(fade[0]["color_temp_kelvin"]), 2700)
                self.assertEqual(int(fade[0]["brightness"]), 255)
                self.assertEqual(float(fade[0]["transition"]), 600)
                record = json.loads(
                    runtime.state("input_text.commute_alarm_light_owner")[3:]
                )
                self.assertEqual(record["o"], "1")
                self.assertEqual(record["r"], "on")
                self.assertEqual(
                    runtime.state("select.fairy_lights_live_override"), "2"
                )
                self.assertEqual(
                    runtime.state("switch.fairy_lights_sync_receive"), "off"
                )
                self.assertNotIn("brightness", record)
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(runtime.calls, "idempotent repeat restarted the fade")
                # Already-on devices are not exempt: take over without any
                # zero-brightness pre-step, and never capture the light itself.
            async with Runtime(generated) as runtime:
                await self.window(runtime, 300)
                await runtime.set(
                    "light.fairy_lights", "on", {"brightness": 120, "effect": "Twinkle"}
                )
                await runtime.run("commute_alarm_reconcile")
                lights = [c for d, _, c in runtime.calls if d == "light"]
                self.assertEqual(len(lights), 1)
                self.assertEqual(int(lights[0]["brightness"]), 255)
                self.assertEqual(
                    float(lights[0]["transition"]),
                    300,
                    "late catch-up ends at first ring, not ten minutes late",
                )

        async def test_manual_pending_requires_valid_matching_policy(self):
            """Catch ignoring corrupt/stale policy and falling back to global lead.

            Use both a manual pair and the otherwise valid ordinary 60-minute
            pair: invalid policy must never authorize either pending fade.
            """
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                first = runtime.state("input_text.commute_wake_utc")
                for deadline in (
                    "2026-11-04T12:29:30+00:00",
                    "2026-11-04T13:10:00+00:00",
                ):
                    await runtime.set("input_text.commute_alarm_deadline_utc", deadline)
                    paired = {"wake_at": first, "deadline_at": deadline, "snoozes": 3}
                    for bad in (
                        "unknown",
                        "unavailable",
                        "{broken",
                        "[]",
                        "v1:" + json.dumps(paired),
                        json.dumps({**paired, "wake_at": "2026-11-03T12:10:00+00:00"}),
                        json.dumps(
                            {**paired, "deadline_at": "2026-11-04T12:29:31+00:00"}
                        ),
                        json.dumps({**paired, "snoozes": True}),
                        json.dumps({**paired, "snoozes": "3"}),
                        json.dumps({**paired, "snoozes": 2}),
                        json.dumps({**paired, "extra": 1}),
                        json.dumps({k: v for k, v in paired.items() if k != "snoozes"}),
                        json.dumps({**paired, "wake_at": "2026-11-04T07:10:00-05:00"}),
                    ):
                        with self.subTest(deadline=deadline, policy=bad):
                            await runtime.set(
                                "input_text.commute_manual_wake_policy", bad
                            )
                            runtime.calls.clear()
                            await runtime.run("commute_alarm_reconcile")
                            self.assertFalse(runtime.calls)
                            self.assertEqual(self.owner(runtime), {})
                            self.assertEqual(
                                runtime.state(
                                    "binary_sensor.commute_alarm_lights_owned"
                                ),
                                "off",
                            )
                # A raw, valid pair is eligible; failures above must not be a
                # blanket ban on all pending manual windows.
                paired = {
                    "wake_at": first,
                    "deadline_at": "2026-11-04T12:29:30+00:00",
                    "snoozes": 3,
                }
                await runtime.set(
                    "input_text.commute_alarm_deadline_utc", paired["deadline_at"]
                )
                await runtime.set(
                    "input_text.commute_manual_wake_policy", json.dumps(paired)
                )
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(len(self.lights(runtime, "light.fairy_lights")), 1)

        async def test_manual_three_exact_fade_boundary_and_real_restart(self):
            """Catch lead double-subtraction, minute rounding and lost restored policy.

            Existing boundaries only exercise an ordinary 60-minute pair.
            """
            async with Runtime(generated) as runtime:
                runtime.now = datetime(2026, 11, 5, 14, 30, 29, tzinfo=UTC)
                await self.window(runtime, 601)
                await runtime.run(
                    "commute_publish_alarm",
                    wake_at="2026-11-05T09:40:30-05:00",
                    deadline_at="2026-11-05T10:00:00-05:00",
                    manual_snoozes=3,
                )
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(runtime.calls, "09:30:29 is too early")
                runtime.now += timedelta(seconds=1)
                await runtime.run("commute_alarm_reconcile")
                fade = self.lights(runtime, "light.fairy_lights")
                self.assertEqual(len(fade), 1, "09:30:30 must start the fade")
                self.assertEqual(float(fade[0]["transition"]), 600)
                self.assertEqual(int(fade[0]["brightness"]), 255)
                self.assertEqual(self.owner(runtime)["p"], "held")
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(runtime.calls, "repeat must not restart fade")
                saved = runtime.snapshot_store()
                policy = runtime.state("input_text.commute_manual_wake_policy")
                owner = runtime.state("input_text.commute_alarm_light_owner")

            async def prestart(runtime):
                runtime.now = datetime(2026, 11, 5, 14, 30, 40, tzinfo=UTC)
                await runtime.set(
                    "select.fairy_lights_live_override",
                    "2",
                    {"options": ["0", "1", "2"]},
                )
                await runtime.set("switch.fairy_lights_sync_receive", "off")
                await runtime.set(
                    "sensor.commute_alarm_status",
                    "idle",
                    {
                        "schema": 1,
                        "observed_at": runtime.now.isoformat(),
                        "session": None,
                        "ring": None,
                    },
                )

            async with Runtime(
                generated,
                restore_file=saved,
                prestart=prestart,
                automations={"commute_alarm_wake_reconcile"},
            ) as runtime:
                self.assertEqual(
                    runtime.state("input_text.commute_manual_wake_policy"), policy
                )
                self.assertEqual(
                    runtime.state("input_text.commute_wake_utc"),
                    "2026-11-05T14:40:30+00:00",
                )
                self.assertEqual(
                    runtime.state("input_text.commute_alarm_deadline_utc"),
                    "2026-11-05T15:00:00+00:00",
                )
                self.assertEqual(
                    runtime.state("input_text.commute_alarm_light_owner"), owner
                )
                self.assertEqual(runtime.automation_errors, [])
                self.assertFalse(
                    runtime.calls, "real HA start must not retake or restart fade"
                )

        async def test_manual_zero_final_phone_and_desktop_light_release(self):
            """Catch strict final>first validators dropping zero-snooze final rings.

            Existing final fixtures have original_at an hour before deadline;
            this schema-valid fixture adds no manual count field to status.
            """
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                await runtime.run(
                    "commute_publish_alarm",
                    wake_at="2026-11-04T07:10:00-05:00",
                    deadline_at="2026-11-04T07:10:00-05:00",
                    manual_snoozes=0,
                )
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(len(self.lights(runtime, "light.fairy_lights")), 1)
                self.assertEqual(
                    float(self.lights(runtime, "light.fairy_lights")[0]["transition"]),
                    600,
                )
                runtime.now += timedelta(minutes=10)
                state, attrs = status(runtime.now, phase="final")
                attrs["session"]["locked_deadline_at"] = attrs["session"]["original_at"]
                attrs["session"]["deadline_at"] = attrs["session"]["original_at"]
                # Equality is a final-only case, not permission to accept an
                # impossible window phase at its already-reached deadline.
                attrs["session"]["phase"] = "window"
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(self.pushes(runtime))
                self.assertFalse(self.lights(runtime, "light.smart_led_bulb"))
                self.assertEqual(self.owner(runtime)["s"], "")
                attrs["session"]["phase"] = "final"
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(self.owner(runtime)["s"], "a" * 32)
                pushes = self.pushes(runtime)
                self.assertEqual(len(pushes), 1)
                token = "a" * 32 + ":" + "b" * 32 + ":final"
                self.assertEqual(
                    pushes[0]["data"]["actions"],
                    [{"action": "CC_MEDS:" + token, "title": "Took meds"}],
                )
                self.assertEqual(pushes[0]["data"]["push"]["sound"], "none")
                self.assertEqual(len(self.lights(runtime, "light.smart_led_bulb")), 1)
                self.assertFalse(
                    self.lights(runtime, "light.fairy_lights"),
                    "active ring must not restart fade",
                )
                await runtime.attach({"commute_alarm_phone_action"})
                seen = []
                runtime.removers.append(
                    runtime.hass.bus.async_listen(
                        "state_changed", lambda e: seen.append(e.data["entity_id"])
                    )
                )
                for action in ("CC_SNOOZE:" + token, "CC_MEDS:" + token):
                    runtime.hass.bus.async_fire(
                        "mobile_app_notification_action", {"action": action}
                    )
                    await runtime.hass.async_block_till_done()
                self.assertEqual(
                    runtime.state("input_boolean.morning_meds_taken"), "on"
                )
                self.assertNotIn("input_button.commute_alarm_snooze", seen)
                self.assertNotIn(
                    "input_button.commute_alarm_stop",
                    seen,
                    "meds must not dismiss final audio",
                )
                self.assertEqual(
                    self.owner(runtime)["p"],
                    "held",
                    "only desktop activity completes the window",
                )
                await runtime.set(
                    "light.fairy_lights", "on", {"brightness": 205, "effect": "Solid"}
                )
                runtime.now += timedelta(seconds=1)
                await runtime.set(
                    "input_text.commute_alarm_window_done_utc", runtime.now.isoformat()
                )
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(self.owner(runtime)["p"], "released")
                self.assertEqual(
                    [
                        (d, s, c.get("entity_id"))
                        for d, s, c in runtime.calls
                        if d != "notify"
                    ],
                    [
                        (
                            "select",
                            "select_option",
                            "select.fairy_lights_live_override",
                        ),
                        ("switch", "turn_on", "switch.fairy_lights_sync_receive"),
                    ],
                )
                self.assertEqual(
                    runtime.state("select.fairy_lights_live_override"), "1"
                )
                self.assertEqual(
                    runtime.state("switch.fairy_lights_sync_receive"), "on"
                )
                self.assertEqual(
                    dict(runtime.hass.states.get("light.fairy_lights").attributes),
                    {"brightness": 205, "effect": "Solid"},
                )
                self.assertTrue(
                    any(
                        d == "notify" and c["message"] == "clear_notification"
                        for d, _, c in runtime.calls
                    )
                )
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(
                    runtime.calls, "completed zero-final must not reacquire"
                )

        async def test_light_restoration_only_original_two_controls(self):
            for reason in ("off", "skip", "clear", "done", "terminal"):
                with self.subTest(reason=reason):
                    async with Runtime(generated) as runtime:
                        await self.window(runtime)
                        await runtime.run("commute_alarm_reconcile")
                        await runtime.set(
                            "light.fairy_lights",
                            "on",
                            {
                                "brightness": 205,
                                "color_temp_kelvin": 3000,
                                "effect": "Solid",
                            },
                        )
                        runtime.calls.clear()
                        if reason == "off":
                            await runtime.set(
                                "input_boolean.commute_alarm_enabled", "off"
                            )
                        elif reason == "skip":
                            await runtime.set(
                                "input_text.commute_alarm_skipped_utc",
                                (runtime.now + timedelta(minutes=10)).isoformat(),
                            )
                        elif reason == "clear":
                            await runtime.set(
                                "input_text.commute_alarm_deadline_utc",
                                "1970-01-01T00:00:00+00:00",
                            )
                        else:
                            runtime.now += timedelta(minutes=10)
                            state, attrs = status(runtime.now)
                            await runtime.set(
                                "sensor.commute_alarm_status", state, attrs
                            )
                            await runtime.run("commute_alarm_reconcile")
                            runtime.calls.clear()
                            if reason == "done":
                                runtime.now += timedelta(seconds=1)
                                await runtime.set(
                                    "input_text.commute_alarm_window_done_utc",
                                    runtime.now.isoformat(),
                                )
                            ended = {
                                "wake": {
                                    "kind": "wake",
                                    "phase": "window",
                                    "session_id": "a" * 32,
                                    "original_at": attrs["session"]["original_at"],
                                    "locked_deadline_at": attrs["session"][
                                        "locked_deadline_at"
                                    ],
                                    "ended_at": runtime.now.isoformat(),
                                    "reason": "desktop_activity"
                                    if reason == "done"
                                    else "master_off",
                                },
                                "nap": None,
                            }
                            attrs["observed_at"] = runtime.now.isoformat().replace(
                                "+00:00", "Z"
                            )
                            await runtime.set(
                                "sensor.commute_alarm_status",
                                "idle",
                                {
                                    "schema": 1,
                                    "observed_at": attrs["observed_at"],
                                    "session": None,
                                    "ring": None,
                                    "ended": ended,
                                },
                            )
                        await runtime.run("commute_alarm_reconcile")
                        self.assertEqual(
                            json.loads(
                                runtime.state("input_text.commute_alarm_light_owner")[
                                    3:
                                ]
                            )["p"],
                            "released",
                            runtime.state("input_text.commute_alarm_light_owner")
                            + repr(runtime.calls),
                        )
                        self.assertEqual(
                            [
                                (d, s, c.get("entity_id"))
                                for d, s, c in runtime.calls
                                if d != "notify"
                            ],
                            [
                                (
                                    "select",
                                    "select_option",
                                    "select.fairy_lights_live_override",
                                ),
                                (
                                    "switch",
                                    "turn_on",
                                    "switch.fairy_lights_sync_receive",
                                ),
                            ],
                        )
                        self.assertEqual(
                            str(
                                next(
                                    c["option"]
                                    for d, _, c in runtime.calls
                                    if d == "select"
                                )
                            ),
                            "1",
                        )
                        light = runtime.hass.states.get("light.fairy_lights")
                        self.assertEqual(light.state, "on")
                        self.assertEqual(
                            dict(light.attributes),
                            {
                                "brightness": 205,
                                "color_temp_kelvin": 3000,
                                "effect": "Solid",
                            },
                        )

        async def test_restart_idempotency_partial_restore_and_unavailable_controls(
            self,
        ):
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                await runtime.run("commute_alarm_reconcile")
                saved = runtime.state("input_text.commute_alarm_light_owner")
                wake = runtime.state("input_text.commute_wake_utc")
                deadline = runtime.state("input_text.commute_alarm_deadline_utc")
            async with Runtime(
                generated,
                {
                    "input_text.commute_alarm_light_owner": saved,
                    "input_text.commute_wake_utc": wake,
                    "input_text.commute_alarm_deadline_utc": deadline,
                    "input_boolean.commute_alarm_enabled": "on",
                },
            ) as runtime:
                await runtime.set(
                    "select.fairy_lights_live_override",
                    "2",
                    {"options": ["0", "1", "2"]},
                )
                await runtime.set("switch.fairy_lights_sync_receive", "off")
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(
                    runtime.calls, "restart must not resnapshot or restart fade"
                )
                await runtime.set("input_boolean.commute_alarm_enabled", "off")
                runtime.fail_targets.add("switch.fairy_lights_sync_receive")
                from homeassistant.exceptions import HomeAssistantError

                with self.assertRaises(HomeAssistantError):
                    await runtime.run("commute_alarm_reconcile")
                self.assertEqual(
                    json.loads(
                        runtime.state("input_text.commute_alarm_light_owner")[3:]
                    )["p"],
                    "release",
                    "partial restoration must keep retry ownership",
                )
                runtime.fail_targets.clear()
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(
                    json.loads(
                        runtime.state("input_text.commute_alarm_light_owner")[3:]
                    )["p"],
                    "released",
                    runtime.state("input_text.commute_alarm_light_owner")
                    + repr(runtime.calls),
                )
                self.assertFalse(any(d == "light" for d, _, _ in runtime.calls))
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                await runtime.set("select.fairy_lights_live_override", "unavailable")
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(runtime.calls)
                self.assertEqual(
                    runtime.state("input_text.commute_alarm_light_owner"), "v1:{}"
                )

        async def test_unknown_stale_future_status_and_old_terminal_exclusion(self):
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                await runtime.set(
                    "input_text.commute_wake_utc", runtime.now.isoformat()
                )
                await runtime.set(
                    "input_text.commute_alarm_deadline_utc",
                    (runtime.now + timedelta(hours=1)).isoformat(),
                )
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                owner = json.loads(
                    runtime.state("input_text.commute_alarm_light_owner")[3:]
                )
                self.assertEqual(owner["s"], "a" * 32)
                runtime.calls.clear()
                for offset in (-91, 1):
                    _, bad = status(runtime.now + timedelta(seconds=offset))
                    bad["ended"]["wake"] = {
                        "session_id": "a" * 32,
                        "ended_at": runtime.now.isoformat(),
                    }
                    await runtime.set("sensor.commute_alarm_status", "idle", bad)
                    await runtime.run("commute_alarm_reconcile")
                    self.assertEqual(
                        json.loads(
                            runtime.state("input_text.commute_alarm_light_owner")[3:]
                        )["s"],
                        "a" * 32,
                    )
                for state in ("unknown", "unavailable"):
                    await runtime.set("sensor.commute_alarm_status", state)
                    await runtime.run("commute_alarm_reconcile")
                    self.assertTrue(
                        runtime.state("input_text.commute_alarm_light_owner")
                    )
                # Nap terminals and previous-wake terminals cannot release this
                # newer wake's ownership record.
                for kind, sid in (("nap", "a" * 32), ("wake", "d" * 32)):
                    _, good = status(runtime.now)
                    good["ended"][kind] = {
                        "kind": kind,
                        "phase": "window" if kind == "wake" else "legacy",
                        "session_id": sid,
                        "original_at": good["session"]["original_at"],
                        "locked_deadline_at": good["session"]["locked_deadline_at"],
                        "ended_at": runtime.now.isoformat().replace("+00:00", "Z"),
                        "reason": "desktop_activity",
                    }
                    await runtime.set("sensor.commute_alarm_status", "idle", good)
                    await runtime.run("commute_alarm_reconcile")
                    self.assertTrue(
                        runtime.state("input_text.commute_alarm_light_owner")
                    )
                self.assertFalse([c for c in runtime.calls if c[0] != "notify"])

        async def test_daemon_schedule_terminal_reasons_release_window(self):
            """Wire reasons from pinned daemon adfc665 `_cancellation_reason`:
            schedule_cleared (wake helper unknown) and schedule_replaced (wake
            moved to the next day). Helpers already show the new schedule while
            the session status is still fresh, so only the matching terminal
            can release; unknown status and nap terminals must not."""
            for reason in ("schedule_cleared", "schedule_replaced"):
                with self.subTest(reason=reason):
                    async with Runtime(generated) as runtime:
                        owner_entity = "input_text.commute_alarm_light_owner"
                        await self.window(runtime, 0)
                        state, attrs = status(runtime.now)
                        await runtime.set("sensor.commute_alarm_status", state, attrs)
                        await runtime.run("commute_alarm_reconcile")
                        held = json.loads(runtime.state(owner_entity)[3:])
                        self.assertEqual(
                            (held["p"], held["s"]),
                            ("held", "a" * 32),
                            runtime.state(owner_entity),
                        )
                        if reason == "schedule_cleared":
                            new_wake = new_deadline = "unknown"
                        else:
                            new_wake = (runtime.now + timedelta(days=1)).isoformat()
                            new_deadline = (
                                runtime.now + timedelta(days=1, hours=1)
                            ).isoformat()
                        await runtime.set("input_text.commute_wake_utc", new_wake)
                        await runtime.set(
                            "input_text.commute_alarm_deadline_utc", new_deadline
                        )
                        runtime.now += timedelta(seconds=30)
                        attrs["observed_at"] = runtime.now.isoformat(
                            timespec="seconds"
                        ).replace("+00:00", "Z")
                        await runtime.set("sensor.commute_alarm_status", state, attrs)
                        await runtime.run("commute_alarm_reconcile")
                        self.assertEqual(
                            json.loads(runtime.state(owner_entity)[3:])["p"],
                            "held",
                            "helper change alone must not release a fresh session window",
                        )
                        # Unknown status is not terminal.
                        await runtime.set("sensor.commute_alarm_status", "unknown")
                        await runtime.run("commute_alarm_reconcile")
                        self.assertEqual(
                            json.loads(runtime.state(owner_entity)[3:])["p"], "held"
                        )

                        def terminal(kind, attrs=attrs, reason=reason):
                            return {
                                "kind": kind,
                                "phase": "window" if kind == "wake" else "legacy",
                                "session_id": "a" * 32,
                                "original_at": attrs["session"]["original_at"],
                                "locked_deadline_at": attrs["session"][
                                    "locked_deadline_at"
                                ]
                                if kind == "wake"
                                else None,
                                "ended_at": attrs["observed_at"],
                                "reason": reason,
                            }

                        idle = {
                            "schema": 1,
                            "observed_at": attrs["observed_at"],
                            "session": None,
                            "ring": None,
                            "audio_failed": False,
                            "snooze_until": None,
                        }
                        # A nap terminal carrying the same reason does not end the wake window.
                        await runtime.set(
                            "sensor.commute_alarm_status",
                            "idle",
                            dict(idle, ended={"wake": None, "nap": terminal("nap")}),
                        )
                        await runtime.run("commute_alarm_reconcile")
                        self.assertEqual(
                            json.loads(runtime.state(owner_entity)[3:])["p"], "held"
                        )
                        # A reason the pinned daemon never emits is not terminal.
                        await runtime.set(
                            "sensor.commute_alarm_status",
                            "idle",
                            dict(
                                idle,
                                ended={
                                    "wake": dict(
                                        terminal("wake"), reason="explicit_clear"
                                    ),
                                    "nap": None,
                                },
                            ),
                        )
                        await runtime.run("commute_alarm_reconcile")
                        self.assertEqual(
                            json.loads(runtime.state(owner_entity)[3:])["p"], "held"
                        )
                        runtime.calls.clear()
                        await runtime.set(
                            "sensor.commute_alarm_status",
                            "idle",
                            dict(idle, ended={"wake": terminal("wake"), "nap": None}),
                        )
                        await runtime.run("commute_alarm_reconcile")
                        self.assertEqual(
                            json.loads(runtime.state(owner_entity)[3:])["p"],
                            "released",
                            runtime.state(owner_entity) + repr(runtime.calls),
                        )
                        self.assertEqual(
                            [
                                (d, s, c.get("entity_id"))
                                for d, s, c in runtime.calls
                                if d in ("select", "switch")
                            ],
                            [
                                (
                                    "select",
                                    "select_option",
                                    "select.fairy_lights_live_override",
                                ),
                                (
                                    "switch",
                                    "turn_on",
                                    "switch.fairy_lights_sync_receive",
                                ),
                            ],
                        )

        async def test_per_ring_notification_lamp_phase_and_dismissal(self):
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                pushes = [
                    c
                    for d, _, c in runtime.calls
                    if d == "notify" and c["message"] != "clear_notification"
                ]
                self.assertEqual(len(pushes), 1)
                push = pushes[0]
                self.assertEqual(push["data"]["tag"], "commute-wake-ring")
                self.assertEqual(push["data"]["push"]["sound"], "none")
                self.assertEqual(
                    [a["title"] for a in push["data"]["actions"]],
                    ["Snooze 5 min", "Took meds"],
                )
                bedside = [
                    c
                    for d, _, c in runtime.calls
                    if d == "light" and c["entity_id"] == "light.smart_led_bulb"
                ]
                self.assertEqual(len(bedside), 1)
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(runtime.calls)
                attrs["session"]["phase"] = "final"
                runtime.now += timedelta(hours=1)
                attrs["observed_at"] = runtime.now.isoformat().replace("+00:00", "Z")
                attrs["ring"]["checked_at"] = attrs["observed_at"]
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                pushes = [
                    c
                    for d, _, c in runtime.calls
                    if d == "notify" and c["message"] != "clear_notification"
                ]
                self.assertEqual(
                    len(pushes),
                    1,
                    "same ring phase transition must refresh notification",
                )
                # Final: no Snooze/stop; "Took meds" stays while meds are still off.
                final_token = "a" * 32 + ":" + "b" * 32 + ":final"
                self.assertEqual(
                    pushes[0]["data"]["actions"],
                    [{"action": "CC_MEDS:" + final_token, "title": "Took meds"}],
                )
                self.assertFalse(
                    any(d == "light" for d, _, _ in runtime.calls),
                    "same ring phase transition relit bedside",
                )
                runtime.calls.clear()
                await runtime.set(
                    "sensor.commute_alarm_status",
                    "idle",
                    {
                        "schema": 1,
                        "observed_at": attrs["observed_at"],
                        "session": None,
                        "ring": None,
                    },
                )
                await runtime.run("commute_alarm_reconcile")
                self.assertTrue(
                    any(
                        c["message"] == "clear_notification"
                        for d, _, c in runtime.calls
                        if d == "notify"
                    )
                )
            # Final ring with meds already taken: no actions at all.
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                await runtime.set("input_boolean.morning_meds_taken", "on")
                state, attrs = status(runtime.now - timedelta(hours=1), phase="final")
                attrs["observed_at"] = attrs["ring"]["checked_at"] = (
                    runtime.now.isoformat(timespec="seconds").replace("+00:00", "Z")
                )
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                pushes = [
                    c
                    for d, _, c in runtime.calls
                    if d == "notify" and c["message"] != "clear_notification"
                ]
                self.assertEqual(len(pushes), 1)
                self.assertEqual(pushes[0]["data"]["actions"], [])

        async def test_phone_actions_snooze_button_meds_only_off_stale_rejection(self):
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                push = next(
                    c
                    for d, _, c in runtime.calls
                    if d == "notify" and c["message"] != "clear_notification"
                )
                snooze, off = [a["action"] for a in push["data"]["actions"]]
                await runtime.attach({"commute_alarm_phone_action"})
                await runtime.set("input_boolean.morning_meds_taken", "off")
                seen = []
                runtime.removers.append(
                    runtime.hass.bus.async_listen(
                        "state_changed", lambda e: seen.append(e.data["entity_id"])
                    )
                )

                async def tap(action):
                    runtime.hass.bus.async_fire(
                        "mobile_app_notification_action", {"action": action}
                    )
                    await runtime.hass.async_block_till_done()

                runtime.calls.clear()
                await tap(snooze)
                self.assertIn("input_button.commute_alarm_snooze", seen)
                self.assertEqual(
                    runtime.state("input_boolean.morning_meds_taken"), "off"
                )
                seen.clear()
                await tap(off)
                self.assertNotIn(
                    "input_button.commute_alarm_stop",
                    seen,
                    "meds action must not dismiss audio",
                )
                self.assertEqual(
                    runtime.state("input_boolean.morning_meds_taken"), "on"
                )
                # Identity, phase and observation age are part of tap authority.
                await runtime.set("input_boolean.morning_meds_taken", "off")
                seen.clear()
                runtime.calls.clear()
                for changed in (
                    snooze.replace("a" * 32, "d" * 32),
                    snooze.replace("b" * 32, "e" * 32),
                    snooze.replace(":window", ":legacy"),
                    snooze + ":0",
                ):
                    await tap(changed)
                self.assertFalse(
                    any(
                        e in seen
                        for e in (
                            "input_button.commute_alarm_stop",
                            "input_button.commute_alarm_snooze",
                        )
                    )
                )
                self.assertFalse(runtime.calls)
                for offset in (-91, 1):
                    attrs["observed_at"] = (
                        (runtime.now + timedelta(seconds=offset))
                        .isoformat()
                        .replace("+00:00", "Z")
                    )
                    await runtime.set("sensor.commute_alarm_status", state, attrs)
                    await tap(snooze)
                self.assertNotIn("input_button.commute_alarm_snooze", seen)
                self.assertEqual(
                    runtime.state("input_boolean.morning_meds_taken"), "off"
                )
                self.assertFalse([c for c in runtime.calls if c[0] != "notify"])

        async def native_window_inputs(self, runtime, seconds_to_first=600):
            """Window inputs WITHOUT touching owner/phone/bedside helpers."""
            await runtime.set("input_text.commute_manual_wake_policy", "")
            for helper in (
                "commute_alarm_skipped_utc",
                "commute_alarm_window_done_utc",
            ):
                await runtime.set("input_text." + helper, "1970-01-01T00:00:00+00:00")
            await runtime.set("input_boolean.commute_alarm_enabled", "on")
            await runtime.set("input_boolean.morning_meds_taken", "off")
            await runtime.set(
                "input_text.commute_wake_utc",
                (runtime.now + timedelta(seconds=seconds_to_first)).isoformat(),
            )
            await runtime.set(
                "input_text.commute_alarm_deadline_utc",
                (runtime.now + timedelta(seconds=seconds_to_first + 3600)).isoformat(),
            )
            await runtime.set(
                "select.fairy_lights_live_override", "1", {"options": ["0", "1", "2"]}
            )
            await runtime.set("switch.fairy_lights_sync_receive", "on")
            await runtime.set("light.fairy_lights", "off")

        @staticmethod
        def pushes(runtime):
            return [
                c
                for d, _, c in runtime.calls
                if d == "notify" and c["message"] != "clear_notification"
            ]

        @staticmethod
        def lights(runtime, entity):
            return [
                c
                for d, _, c in runtime.calls
                if d == "light" and c["entity_id"] == entity
            ]

        @staticmethod
        def owner(runtime):
            raw = runtime.state("input_text.commute_alarm_light_owner")
            return json.loads(raw[3:]) if raw and raw.startswith("v1:") else raw

        async def test_actual_start_trigger_first_install_late_catchup(self):
            """New install, HA starts mid-window: only the generated
            `homeassistant: start` trigger runs reconcile (no test script call)."""

            def iso(value):
                return value.isoformat(timespec="seconds").replace("+00:00", "Z")

            async def late(runtime):
                await self.native_window_inputs(runtime, -300)
                state, attrs = status(runtime.now - timedelta(seconds=300))
                attrs["observed_at"] = attrs["ring"]["checked_at"] = iso(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)

            async with Runtime(
                generated, automations={"commute_alarm_wake_reconcile"}, prestart=late
            ) as runtime:
                self.assertEqual(runtime.automation_errors, [])
                self.assertEqual(
                    self.owner(runtime).get("p"), "held", self.owner(runtime)
                )
                fairy = self.lights(runtime, "light.fairy_lights")
                self.assertEqual(len(fairy), 1, runtime.calls)
                self.assertEqual(
                    fairy[0]["transition"], 0, "late catch-up must not start a new fade"
                )
                self.assertEqual(len(self.lights(runtime, "light.smart_led_bulb")), 1)
                self.assertEqual(len(self.pushes(runtime)), 1)
                runtime.calls.clear()
                for _ in range(3):
                    await runtime.tick(10)
                self.assertFalse(
                    runtime.calls, "periodic ticks must not repeat side effects"
                )

        async def test_time_pattern_tick_starts_fade_and_retries_failed_release(self):
            async with Runtime(
                generated, automations={"commute_alarm_wake_reconcile"}
            ) as runtime:
                await self.window(runtime, 601)
                self.assertFalse(
                    runtime.calls, "state triggers before L-70 must not seize lights"
                )
                # No state change: only the real /10 s time_pattern trigger can start the fade.
                await runtime.tick(10)
                fairy = self.lights(runtime, "light.fairy_lights")
                self.assertEqual(len(fairy), 1, runtime.calls)
                self.assertEqual(fairy[0]["transition"], 591)
                self.assertEqual(self.owner(runtime)["p"], "held")
                # Master-off release fails half-way; ledger keeps release intent.
                self.assertEqual(runtime.automation_errors, [])
                runtime.calls.clear()
                runtime.fail_targets.add("switch.fairy_lights_sync_receive")
                await runtime.set("input_boolean.commute_alarm_enabled", "off")
                self.assertTrue(
                    runtime.automation_errors, "switch failure must surface"
                )
                self.assertEqual(self.owner(runtime)["p"], "release")
                runtime.fail_targets.clear()
                runtime.calls.clear()
                await runtime.tick(10)
                self.assertEqual(
                    self.owner(runtime)["p"],
                    "released",
                    (runtime.calls, runtime.automation_errors, runtime.now),
                )
                self.assertEqual(
                    sorted((d, s) for d, s, _ in runtime.calls),
                    [("select", "select_option"), ("switch", "turn_on")],
                )
                self.assertEqual(
                    runtime.state("select.fairy_lights_live_override"), "1"
                )
                runtime.calls.clear()
                await runtime.tick(10)
                self.assertFalse(runtime.calls)

        async def test_restart_with_actual_start_trigger_is_idempotent_then_releases_without_status(
            self,
        ):
            def iso(value):
                return value.isoformat(timespec="seconds").replace("+00:00", "Z")

            async with Runtime(
                generated, automations={"commute_alarm_wake_reconcile"}
            ) as runtime:
                await self.window(runtime, 0)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                held = self.owner(runtime)
                self.assertEqual(held["p"], "held")
                self.assertEqual(held["o"], "1")
                store = runtime.snapshot_store()

            async def devices_after_restart(runtime):
                runtime.now += timedelta(seconds=40)
                # Device/REST states are not restored helpers: WLED as the alarm left it.
                await runtime.set(
                    "select.fairy_lights_live_override",
                    "2",
                    {"options": ["0", "1", "2"]},
                )
                await runtime.set("switch.fairy_lights_sync_receive", "off")
                await runtime.set("light.fairy_lights", "on")
                attrs["observed_at"] = attrs["ring"]["checked_at"] = iso(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)

            async with Runtime(
                generated,
                restore_file=store,
                automations={"commute_alarm_wake_reconcile"},
                prestart=devices_after_restart,
            ) as runtime:
                self.assertEqual(runtime.automation_errors, [])
                self.assertEqual(
                    self.owner(runtime), held, "restart must keep the restored ledger"
                )
                self.assertFalse(
                    runtime.calls, "restart re-ran takeover, bedside or notification"
                )
                # Daemon gone after restart; desktop completion still releases.
                runtime.now += timedelta(minutes=2)
                runtime.hass.states.async_remove("sensor.commute_alarm_status")
                await runtime.hass.async_block_till_done()
                await runtime.set(
                    "input_text.commute_alarm_window_done_utc",
                    (runtime.now - timedelta(seconds=30)).isoformat(),
                )
                self.assertEqual(self.owner(runtime)["p"], "released")
                self.assertEqual(
                    runtime.state("select.fairy_lights_live_override"),
                    "1",
                    "restored snapshot option",
                )
                self.assertEqual(
                    runtime.state("switch.fairy_lights_sync_receive"), "on"
                )
                self.assertFalse(
                    self.lights(runtime, "light.fairy_lights"),
                    "release must never touch the light",
                )

        async def test_second_ring_same_session_old_tap_rejected_new_ring_notified_once(
            self,
        ):
            def iso(value):
                return value.isoformat(timespec="seconds").replace("+00:00", "Z")

            session, ring_b, ring_d = "a" * 32, "b" * 32, "d" * 32
            async with Runtime(
                generated,
                automations={
                    "commute_alarm_wake_reconcile",
                    "commute_alarm_phone_action",
                },
            ) as runtime:
                await self.window(runtime, 0)
                start = runtime.now
                state, attrs = status(start, ring=ring_b)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                first = self.pushes(runtime)
                self.assertEqual(len(first), 1)
                old = {a["title"]: a["action"] for a in first[0]["data"]["actions"]}
                # Daemon snoozes ring B: notification cleared, lights stay held.
                runtime.now += timedelta(minutes=1)
                runtime.calls.clear()
                snoozed = copy.deepcopy(attrs)
                snoozed["ring"] = None
                snoozed["observed_at"] = iso(runtime.now)
                await runtime.set("sensor.commute_alarm_status", "snoozed", snoozed)
                self.assertTrue(
                    [
                        c
                        for d, _, c in runtime.calls
                        if d == "notify" and c["message"] == "clear_notification"
                    ]
                )
                self.assertEqual(self.owner(runtime)["p"], "held")
                # Ring D in the same session.
                runtime.now += timedelta(minutes=4)
                runtime.calls.clear()
                second = copy.deepcopy(attrs)
                second["ring"].update(
                    id=ring_d, started_at=iso(runtime.now), checked_at=iso(runtime.now)
                )
                second["observed_at"] = iso(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, second)
                pushes = self.pushes(runtime)
                self.assertEqual(len(pushes), 1, "new ring must notify exactly once")
                self.assertEqual(
                    [a["action"] for a in pushes[0]["data"]["actions"]],
                    [
                        f"CC_SNOOZE:{session}:{ring_d}:window",
                        f"CC_MEDS:{session}:{ring_d}:window",
                    ],
                )
                self.assertFalse(
                    self.lights(runtime, "light.smart_led_bulb"),
                    "bedside is once per session",
                )
                self.assertFalse(
                    self.lights(runtime, "light.fairy_lights"), "lights already held"
                )
                seen = []
                runtime.removers.append(
                    runtime.hass.bus.async_listen(
                        "state_changed", lambda e: seen.append(e.data["entity_id"])
                    )
                )

                async def tap(action):
                    runtime.hass.bus.async_fire(
                        "mobile_app_notification_action", {"action": action}
                    )
                    await runtime.hass.async_block_till_done()

                runtime.calls.clear()
                await tap(old["Snooze 5 min"])
                await tap(old["Took meds"])
                self.assertNotIn(
                    "input_button.commute_alarm_snooze",
                    seen,
                    "old ring tap snoozed the new ring",
                )
                self.assertEqual(
                    runtime.state("input_boolean.morning_meds_taken"),
                    "off",
                    "old ring meds tap accepted",
                )
                await runtime.tick(10)
                self.assertFalse(
                    self.pushes(runtime),
                    "ticks/taps must not resend the ring D notification",
                )
                await tap(pushes[0]["data"]["actions"][0]["action"])
                self.assertIn("input_button.commute_alarm_snooze", seen)

        async def test_window_done_during_fresh_ring_clears_rejects_and_releases(self):
            """Desktop completion while the export still says ringing: the
            actual triggers clear the phone, refuse its taps and release WLED."""
            session, ring = "a" * 32, "b" * 32
            async with Runtime(
                generated,
                automations={
                    "commute_alarm_wake_reconcile",
                    "commute_alarm_phone_action",
                },
            ) as runtime:
                await self.window(runtime, 0)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                tokens = [
                    a["action"] for a in self.pushes(runtime)[0]["data"]["actions"]
                ]
                self.assertEqual(
                    tokens,
                    [
                        f"CC_SNOOZE:{session}:{ring}:window",
                        f"CC_MEDS:{session}:{ring}:window",
                    ],
                )
                runtime.now += timedelta(seconds=20)
                attrs["observed_at"] = attrs["ring"]["checked_at"] = (
                    runtime.now.isoformat(timespec="seconds").replace("+00:00", "Z")
                )
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                runtime.calls.clear()
                await runtime.set(
                    "input_text.commute_alarm_window_done_utc",
                    (runtime.now - timedelta(seconds=5)).isoformat(),
                )
                self.assertEqual(runtime.automation_errors, [])
                self.assertTrue(
                    [
                        c
                        for d, _, c in runtime.calls
                        if d == "notify" and c["message"] == "clear_notification"
                    ],
                    runtime.calls,
                )
                self.assertFalse(self.pushes(runtime))
                self.assertEqual(self.owner(runtime)["p"], "released")
                self.assertEqual(
                    sorted(
                        (d, s)
                        for d, s, _ in runtime.calls
                        if d in ("select", "switch", "light")
                    ),
                    [("select", "select_option"), ("switch", "turn_on")],
                )
                seen = []
                runtime.removers.append(
                    runtime.hass.bus.async_listen(
                        "state_changed", lambda e: seen.append(e.data["entity_id"])
                    )
                )
                runtime.calls.clear()
                for token in tokens:
                    runtime.hass.bus.async_fire(
                        "mobile_app_notification_action", {"action": token}
                    )
                    await runtime.hass.async_block_till_done()
                self.assertNotIn("input_button.commute_alarm_snooze", seen)
                self.assertEqual(
                    runtime.state("input_boolean.morning_meds_taken"), "off"
                )
                await runtime.tick(10)
                await runtime.tick(10)
                self.assertFalse(
                    runtime.calls, "done ring must not renotify, relight or retake"
                )

        async def test_same_ring_failure_recovery_without_duplicates(self):
            with self.subTest("bedside failure"):
                async with Runtime(
                    generated, automations={"commute_alarm_wake_reconcile"}
                ) as runtime:
                    await self.window(runtime, 0)
                    runtime.fail_targets.add("light.smart_led_bulb")
                    state, attrs = status(runtime.now)
                    await runtime.set("sensor.commute_alarm_status", state, attrs)
                    self.assertTrue(runtime.automation_errors)
                    self.assertEqual(
                        runtime.state("input_text.commute_alarm_bedside_claim"), ""
                    )
                    runtime.fail_targets.clear()
                    await runtime.tick(10)
                    await runtime.tick(10)
                    self.assertEqual(
                        runtime.state("input_text.commute_alarm_bedside_claim"),
                        "a" * 32,
                    )
                    self.assertEqual(
                        len([c for c in self.lights(runtime, "light.smart_led_bulb")]),
                        2,
                        "one failed attempt, one retry",
                    )
                    self.assertEqual(
                        len(self.pushes(runtime)),
                        1,
                        "notification duplicated across retry",
                    )
                    self.assertEqual(
                        len(self.lights(runtime, "light.fairy_lights")),
                        1,
                        "takeover duplicated across retry",
                    )
                    self.assertEqual(self.owner(runtime)["p"], "held")
            with self.subTest("notification failure"):
                async with Runtime(
                    generated, automations={"commute_alarm_wake_reconcile"}
                ) as runtime:
                    await self.window(runtime, 0)
                    runtime.fail_services.add("notify")
                    state, attrs = status(runtime.now)
                    await runtime.set("sensor.commute_alarm_status", state, attrs)
                    # Phone failure must not block the wake lights or bedside lamp.
                    self.assertEqual(self.owner(runtime)["p"], "held")
                    self.assertEqual(
                        len(self.lights(runtime, "light.smart_led_bulb")), 1
                    )
                    runtime.fail_services.clear()
                    runtime.calls.clear()
                    await runtime.tick(10)
                    await runtime.tick(10)
                    # Documented at-most-once per session/ring/phase: no resend
                    # of the same ring, and nothing else repeats.
                    self.assertFalse(runtime.calls, runtime.calls)
                    # The next phase of the same ring still notifies once.
                    runtime.now = datetime.fromisoformat(
                        attrs["session"]["locked_deadline_at"]
                    )
                    attrs["session"]["phase"] = "final"
                    attrs["observed_at"] = attrs["ring"]["checked_at"] = (
                        runtime.now.isoformat(timespec="seconds").replace("+00:00", "Z")
                    )
                    await runtime.set("sensor.commute_alarm_status", state, attrs)
                    await runtime.tick(10)
                    self.assertEqual(len(self.pushes(runtime)), 1)

        async def test_failed_clear_notification_keeps_flag_releases_lights_then_retries_once(
            self,
        ):
            """Operational clear failure is contained at the enclosing choose:
            v stays true, the WLED release still runs, the next reconcile
            clears once (v=false), and later reconciles are idempotent."""
            phone = "input_text.commute_alarm_phone_claim"

            def claim(runtime):
                return json.loads(runtime.state(phone)[3:])

            async with Runtime(generated) as runtime:
                await self.window(runtime, 0)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(len(self.pushes(runtime)), 1)
                self.assertTrue(claim(runtime)["v"], runtime.state(phone))
                self.assertEqual(self.owner(runtime)["p"], "held")
                key = claim(runtime)["k"]
                # Matching daemon terminal: not ringing, ownership ends.
                runtime.now += timedelta(seconds=30)
                observed = runtime.now.isoformat(timespec="seconds").replace(
                    "+00:00", "Z"
                )
                ended = {
                    "wake": {
                        "kind": "wake",
                        "phase": "window",
                        "session_id": "a" * 32,
                        "original_at": attrs["session"]["original_at"],
                        "locked_deadline_at": attrs["session"]["locked_deadline_at"],
                        "ended_at": observed,
                        "reason": "desktop_activity",
                    },
                    "nap": None,
                }
                await runtime.set(
                    "sensor.commute_alarm_status",
                    "idle",
                    {
                        "schema": 1,
                        "observed_at": observed,
                        "session": None,
                        "ring": None,
                        "audio_failed": False,
                        "snooze_until": None,
                        "ended": ended,
                    },
                )
                runtime.fail_services.add("notify")
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                clears = [
                    c
                    for d, _, c in runtime.calls
                    if d == "notify" and c["message"] == "clear_notification"
                ]
                self.assertEqual(len(clears), 1, runtime.calls)
                self.assertEqual(
                    claim(runtime),
                    {"k": key, "v": True},
                    "failed clear must not mark cleared",
                )
                self.assertEqual(self.owner(runtime)["p"], "released", runtime.calls)
                self.assertEqual(
                    [
                        (d, s, c.get("entity_id"))
                        for d, s, c in runtime.calls
                        if d in ("select", "switch")
                    ],
                    [
                        (
                            "select",
                            "select_option",
                            "select.fairy_lights_live_override",
                        ),
                        ("switch", "turn_on", "switch.fairy_lights_sync_receive"),
                    ],
                )
                runtime.fail_services.clear()
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(
                    [(d, c["message"]) for d, _, c in runtime.calls],
                    [("notify", "clear_notification")],
                )
                self.assertEqual(claim(runtime), {"k": key, "v": False})
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(runtime.calls, "clear/release must be idempotent")
                self.assertEqual(claim(runtime), {"k": key, "v": False})

        async def test_first_install_native_helpers_and_restart_without_manual_init(
            self,
        ):
            """Native YAML InputText (no initial) on a new install, then a real restart."""
            from homeassistant.core import State

            helpers = (
                "input_text.commute_alarm_light_owner",
                "input_text.commute_alarm_phone_claim",
                "input_text.commute_alarm_bedside_claim",
            )

            async def exercise(runtime, label):
                await self.native_window_inputs(runtime, 0)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                owner = runtime.state("input_text.commute_alarm_light_owner")
                self.assertTrue(owner.startswith("v1:"), f"{label}: {owner}")
                self.assertIn(
                    json.loads(owner[3:]).get("p"),
                    ("take", "held"),
                    f"{label}: {owner}",
                )
                self.assertTrue(
                    any(
                        d == "light" and c["entity_id"] == "light.fairy_lights"
                        for d, _, c in runtime.calls
                    ),
                    label,
                )
                self.assertTrue(
                    any(
                        d == "light" and c["entity_id"] == "light.smart_led_bulb"
                        for d, _, c in runtime.calls
                    ),
                    f"{label}: bedside",
                )
                self.assertTrue(
                    any(
                        d == "notify" and c["message"] != "clear_notification"
                        for d, _, c in runtime.calls
                    ),
                    f"{label}: notification",
                )

            snapshot = {}
            async with Runtime(generated, restore_file=None) as runtime:
                native = {h: runtime.state(h) for h in helpers}
                for h in helpers:
                    snapshot[h] = runtime.state(h)
                await exercise(runtime, f"first install {native}")
            # Restart before any alarm: persist what the new install actually had.
            store = {
                "version": 1,
                "minor_version": 1,
                "key": "core.restore_state",
                "data": [
                    {
                        "state": State(h, v).as_dict(),
                        "extra_data": None,
                        "last_seen": "2026-11-04T11:59:00+00:00",
                    }
                    for h, v in snapshot.items()
                    if v is not None
                ],
            }
            async with Runtime(generated, restore_file=store) as runtime:
                restarted = {h: runtime.state(h) for h in helpers}
                await exercise(runtime, f"restart {restarted}")

        async def test_window_done_releases_without_fresh_status_bounded_by_ledger(
            self,
        ):
            def ledger(runtime):
                return json.loads(
                    runtime.state("input_text.commute_alarm_light_owner")[3:]
                )

            # Bounds per ledger: done > c, done >= w, done >= a, done <= now.
            # Status freshness is NOT required for this release.
            cases = (
                ("before_acquisition", lambda h: h["a"] - 1, False),
                ("after_acquisition_before_wake", lambda h: h["a"] + 60, False),
                ("after_wake", lambda h: h["w"] + 60, True),
                ("future", lambda h: h["w"] + 3600, False),
            )
            for status_case in ("stale", "unavailable", "missing"):
                for done_case, done_at, releases in cases:
                    with self.subTest(status=status_case, done=done_case):
                        async with Runtime(generated) as runtime:
                            await self.window(runtime)
                            await runtime.run("commute_alarm_reconcile")
                            held = ledger(runtime)
                            self.assertIn(held["p"], ("take", "held"))
                            runtime.now = datetime.fromtimestamp(
                                held["w"], UTC
                            ) + timedelta(minutes=3)
                            if status_case == "stale":
                                stale = (
                                    (
                                        runtime.now
                                        - timedelta(
                                            seconds=generated["contract"][
                                                "statusMaxAgeSeconds"
                                            ]
                                            + 60
                                        )
                                    )
                                    .isoformat()
                                    .replace("+00:00", "Z")
                                )
                                await runtime.set(
                                    "sensor.commute_alarm_status",
                                    "idle",
                                    {
                                        "schema": 1,
                                        "observed_at": stale,
                                        "session": None,
                                        "ring": None,
                                        "ended": {"wake": None, "nap": None},
                                    },
                                )
                            elif status_case == "unavailable":
                                await runtime.set(
                                    "sensor.commute_alarm_status", "unavailable"
                                )
                            else:
                                runtime.hass.states.async_remove(
                                    "sensor.commute_alarm_status"
                                )
                            done = datetime.fromtimestamp(done_at(held), UTC)
                            await runtime.set(
                                "input_text.commute_alarm_window_done_utc",
                                done.isoformat(),
                            )
                            runtime.calls.clear()
                            await runtime.run("commute_alarm_reconcile")
                            after = ledger(runtime)
                            if releases:
                                self.assertEqual(after["p"], "released", repr(after))
                                self.assertEqual(
                                    sorted(
                                        (d, s)
                                        for d, s, _ in runtime.calls
                                        if d in ("select", "switch")
                                    ),
                                    [
                                        ("select", "select_option"),
                                        ("switch", "turn_on"),
                                    ],
                                )
                            else:
                                self.assertEqual(
                                    after["p"],
                                    held["p"],
                                    f"{done_case} completion must not release",
                                )
                                self.assertFalse(
                                    [
                                        c
                                        for c in runtime.calls
                                        if c[0] in ("select", "switch", "light")
                                    ]
                                )

        async def test_deadline_only_clear_pending_releases_active_follows_daemon(self):
            # Pending (not session-bound) fade: deadline-only clear releases.
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(
                    json.loads(
                        runtime.state("input_text.commute_alarm_light_owner")[3:]
                    )["s"],
                    "",
                )
                wake = runtime.state("input_text.commute_wake_utc")
                runtime.calls.clear()
                await runtime.set(
                    "input_text.commute_alarm_deadline_utc", "1970-01-01T00:00:00+00:00"
                )
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(runtime.state("input_text.commute_wake_utc"), wake)
                self.assertEqual(
                    json.loads(
                        runtime.state("input_text.commute_alarm_light_owner")[3:]
                    )["p"],
                    "released",
                )
                self.assertEqual(
                    sorted(
                        (d, s) for d, s, _ in runtime.calls if d in ("select", "switch")
                    ),
                    [("select", "select_option"), ("switch", "turn_on")],
                )
            # Active session-bound window: pinned daemon keeps the window on a
            # deadline-only clear (it cancels on WAKE clear), so HA keeps owning;
            # a subsequent wake clear releases.
            async with Runtime(generated) as runtime:
                await self.window(runtime, 0)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                self.assertIn(
                    json.loads(
                        runtime.state("input_text.commute_alarm_light_owner")[3:]
                    )["p"],
                    ("take", "held"),
                )
                wake = runtime.state("input_text.commute_wake_utc")
                runtime.calls.clear()
                runtime.now += timedelta(seconds=30)
                attrs["observed_at"] = attrs["ring"]["checked_at"] = (
                    runtime.now.isoformat().replace("+00:00", "Z")
                )
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.set(
                    "input_text.commute_alarm_deadline_utc", "1970-01-01T00:00:00+00:00"
                )
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(
                    runtime.state("input_text.commute_wake_utc"),
                    wake,
                    "wake time must stay published",
                )
                self.assertEqual(
                    json.loads(
                        runtime.state("input_text.commute_alarm_light_owner")[3:]
                    )["p"],
                    "held",
                )
                self.assertFalse(
                    [c for c in runtime.calls if c[0] in ("select", "switch")]
                )
                await runtime.set(
                    "input_text.commute_wake_utc", "1970-01-01T00:00:00+00:00"
                )
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(
                    json.loads(
                        runtime.state("input_text.commute_alarm_light_owner")[3:]
                    )["p"],
                    "released",
                )
                self.assertEqual(
                    sorted(
                        (d, s) for d, s, _ in runtime.calls if d in ("select", "switch")
                    ),
                    [("select", "select_option"), ("switch", "turn_on")],
                )

        async def test_cached_snooze_token_bound_to_ring_and_deadline(self):
            """Replays exact dashboard/phone tokens into the actual reconcile script."""
            async with Runtime(generated) as runtime:
                await self.window(runtime, 0)
                session, ring_a, ring_b = "a" * 32, "b" * 32, "d" * 32
                state, attrs = status(runtime.now, ring=ring_a)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")

                def presses():
                    return runtime.state("input_button.commute_alarm_snooze")

                cached = f"CC_SNOOZE:{session}:{ring_a}:window"
                # Later ring in the same session: the cached card must be inert.
                runtime.now += timedelta(seconds=30)
                state, attrs = status(runtime.now, ring=ring_b)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                before = presses()
                await runtime.run("commute_alarm_reconcile", request=cached)
                self.assertEqual(
                    presses(), before, "stale cached card snoozed a later ring"
                )
                for wrong in (
                    f"CC_SNOOZE:{session}:{ring_b}:final",
                    f"CC_SNOOZE:{'e' * 32}:{ring_b}:window",
                    f"CC_SNOOZE:{session}:{ring_b}",
                ):
                    await runtime.run("commute_alarm_reconcile", request=wrong)
                    self.assertEqual(presses(), before, wrong)
                current = f"CC_SNOOZE:{session}:{ring_b}:window"
                await runtime.run("commute_alarm_reconcile", request=current)
                self.assertNotEqual(presses(), before, "current ring token must snooze")
                # At locked_deadline_at, with the last export still 'window', refuse.
                deadline = datetime.fromisoformat(
                    attrs["session"]["locked_deadline_at"]
                )
                runtime.now = deadline
                observed = (
                    (deadline - timedelta(seconds=10))
                    .isoformat()
                    .replace("+00:00", "Z")
                )
                attrs["observed_at"] = attrs["ring"]["checked_at"] = observed
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                pressed = presses()
                await runtime.run("commute_alarm_reconcile", request=current)
                self.assertEqual(
                    presses(), pressed, "window token honoured at locked deadline"
                )

        async def test_snooze_with_unknown_skip_helper(self):
            """Never-written skip helper (native unknown) must not disable snooze.

            Regression: 2026-11-05 dashboard snooze was inert while ringing.
            """
            async with Runtime(generated) as runtime:
                await self.window(runtime, 0)
                await runtime.set("input_text.commute_alarm_skipped_utc", "unknown")
                session, ring = "a" * 32, "b" * 32
                state, attrs = status(runtime.now, session=session, ring=ring)
                await runtime.set("sensor.commute_alarm_status", state, attrs)

                def presses():
                    return runtime.state("input_button.commute_alarm_snooze")

                token = f"CC_SNOOZE:{session}:{ring}:window"
                before = presses()
                await runtime.run("commute_alarm_reconcile", request=token)
                self.assertNotEqual(
                    presses(), before, "unknown skip blocked a ringing snooze"
                )
                # A skip of this exact session still blocks the control.
                runtime.now += timedelta(seconds=5)
                attrs["observed_at"] = attrs["ring"]["checked_at"] = (
                    runtime.now.isoformat(timespec="seconds").replace("+00:00", "Z")
                )
                await runtime.set(
                    "input_text.commute_alarm_skipped_utc",
                    attrs["session"]["original_at"],
                )
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                pressed = presses()
                await runtime.run("commute_alarm_reconcile", request=token)
                self.assertEqual(
                    presses(), pressed, "skipped session token still snoozed"
                )

        async def test_bedside_claim_only_after_successful_action(self):
            from homeassistant.exceptions import HomeAssistantError

            async with Runtime(generated) as runtime:
                await self.window(runtime, 0)
                state, attrs = status(runtime.now)
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                runtime.fail_targets.add("light.smart_led_bulb")
                with self.assertRaises(HomeAssistantError):
                    await runtime.run("commute_alarm_reconcile")
                self.assertNotEqual(
                    runtime.state("input_text.commute_alarm_bedside_claim"),
                    "a" * 32,
                    "bedside claim recorded although the lamp action failed",
                )
                runtime.fail_targets.clear()
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertEqual(
                    len(
                        [
                            c
                            for d, _, c in runtime.calls
                            if d == "light" and c["entity_id"] == "light.smart_led_bulb"
                        ]
                    ),
                    1,
                    "retry must relight bedside",
                )
                self.assertEqual(
                    runtime.state("input_text.commute_alarm_bedside_claim"), "a" * 32
                )
                runtime.calls.clear()
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(
                    [
                        c
                        for d, _, c in runtime.calls
                        if d == "light" and c["entity_id"] == "light.smart_led_bulb"
                    ]
                )

        async def test_failed_playback_suppresses_lamp_notification_and_clears(self):
            async with Runtime(generated) as runtime:
                await self.window(runtime)
                state, attrs = status(runtime.now)
                attrs["ring"]["playback"] = "failed"
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                self.assertFalse(
                    any(
                        d == "notify"
                        or (d == "light" and c["entity_id"] == "light.smart_led_bulb")
                        for d, _, c in runtime.calls
                    )
                )
                attrs["ring"]["playback"] = "running"
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                runtime.calls.clear()
                attrs["audio_failed"] = True
                await runtime.set("sensor.commute_alarm_status", state, attrs)
                await runtime.run("commute_alarm_reconcile")
                self.assertTrue(
                    any(
                        d == "notify" and c["message"] == "clear_notification"
                        for d, _, c in runtime.calls
                    )
                )

        async def test_sunset_and_welcome_guard_at_each_wled_write(self):
            from homeassistant.core import Context
            from homeassistant.helpers import config_validation as cv
            from homeassistant.helpers.script import (
                Script,
                async_validate_actions_config,
            )

            async with Runtime(generated) as runtime:
                await self.window(runtime)
                await runtime.run("commute_alarm_reconcile")
                # Extract actual Nix-generated action blocks ending in a WLED
                # service, including repeat bodies. Do not rewrite conditions.
                guards = []
                for automation in generated["automations"]:
                    if automation.get("id") not in (
                        "sunset_bedroom_fade",
                        "welcome_home_lights",
                    ):
                        continue

                    def sequences(value, automation=automation):
                        if isinstance(value, list):
                            for index, item in enumerate(value):
                                if isinstance(item, dict) and str(
                                    item.get("target", {}).get("entity_id", "")
                                ).startswith(
                                    ("select.fairy_lights", "light.fairy_lights")
                                ):
                                    self.assertGreater(
                                        index,
                                        0,
                                        f"unguarded WLED write in {automation['id']}",
                                    )
                                    self.assertEqual(
                                        value[index - 1].get("condition"),
                                        "template",
                                        f"guard missing immediately at write in {automation['id']}",
                                    )
                                    guards.append(value[index - 1 : index + 1])
                                sequences(item)
                        elif isinstance(value, dict):
                            for child in value.values():
                                sequences(child)

                    sequences(automation["action"])
                self.assertGreaterEqual(
                    len(guards), 5, "sunset and all welcome branches must be guarded"
                )
                for sequence in guards:
                    script = Script(
                        runtime.hass,
                        await async_validate_actions_config(
                            runtime.hass, cv.SCRIPT_SCHEMA(copy.deepcopy(sequence))
                        ),
                        "guard",
                        "automation",
                    )
                    runtime.calls.clear()
                    await script.async_run({}, Context())
                    self.assertFalse(
                        runtime.calls, "owned window allowed a preset write"
                    )
                # A completed restoration releases the guards again; otherwise a
                # mismatched owner schema can silently disable presets forever.
                await runtime.set("input_boolean.commute_alarm_enabled", "off")
                await runtime.run("commute_alarm_reconcile")
                for sequence in guards:
                    script = Script(
                        runtime.hass,
                        await async_validate_actions_config(
                            runtime.hass, cv.SCRIPT_SCHEMA(copy.deepcopy(sequence))
                        ),
                        "guard-release",
                        "automation",
                    )
                    runtime.calls.clear()
                    await script.async_run({}, Context())
                    self.assertTrue(
                        runtime.calls, "released owner still blocks normal preset loop"
                    )

        async def test_dashboard_phase_aware_controls(self):
            from homeassistant.helpers.template import Template

            async with Runtime(generated) as runtime:
                finn = [
                    v
                    for d in generated["dashboards"]
                    for v in d["views"]
                    if v.get("path") == "finn"
                ]
                self.assertTrue(finn, "missing generated Finn view")
                sections = [
                    s
                    for v in finn
                    for s in v.get("sections", [])
                    if any(
                        c.get("type") == "heading"
                        and c.get("heading") == "CommuteCompass"
                        for c in s.get("cards", [])
                    )
                ]
                self.assertTrue(
                    sections, "missing CommuteCompass heading section in Finn view"
                )
                for section in sections:
                    kinds = [c.get("type") for c in section["cards"]]
                    self.assertEqual(
                        kinds, ["heading", "custom:auto-entities", "button"], kinds
                    )
                    self.assertEqual(
                        section["cards"][2]["tap_action"]["target"]["entity_id"],
                        "input_button.commute_nap_30",
                    )
                    # Stop/snooze only exist inside the rendered template, never as literal cards.
                    literal = [
                        c
                        for c in walk(section["cards"])
                        if not isinstance(c.get("template"), str)
                    ]
                    literal_targets = json.dumps([c.get("tap_action") for c in literal])
                    self.assertNotIn("commute_alarm_stop", literal_targets)
                    self.assertNotIn("commute_alarm_snooze", literal_targets)
                    self.assertNotIn("CC_SNOOZE", literal_targets)
                templates = [s["cards"][1]["filter"]["template"] for s in sections]
                max_age = generated["contract"]["statusMaxAgeSeconds"]
                self.assertEqual(max_age, 90)
                for text in templates:
                    template = Template(text, runtime.hass)

                    async def rendered(
                        phase="window",
                        ring_attrs=None,
                        session_attrs=None,
                        template=template,
                        **extra,
                    ):
                        state, attrs = status(runtime.now, phase, **extra)
                        if phase == "legacy":
                            attrs["session"]["locked_deadline_at"] = None
                        attrs["ring"].update(ring_attrs or {})
                        attrs["session"].update(session_attrs or {})
                        await runtime.set("sensor.commute_alarm_status", state, attrs)
                        value = template.async_render()
                        self.assertIsInstance(
                            value, list, "auto-entities template must yield cards"
                        )
                        return value

                    def targets(cards):
                        return [
                            c.get("tap_action", {}).get("target", {}).get("entity_id")
                            for c in walk(cards)
                        ]

                    window = targets(await rendered())
                    self.assertTrue(
                        any(
                            c.get("tap_action", {}).get("perform_action")
                            == "script.commute_alarm_reconcile"
                            and c["tap_action"]
                            .get("data", {})
                            .get("request", "")
                            .startswith("CC_SNOOZE:")
                            for c in walk(await rendered())
                        )
                    )
                    self.assertNotIn("input_button.commute_alarm_stop", window)
                    final_cards = await rendered("final")
                    final = targets(final_cards)
                    self.assertNotIn("CC_SNOOZE:", json.dumps(final_cards))
                    self.assertNotIn("input_button.commute_alarm_snooze", final)
                    self.assertNotIn("input_button.commute_alarm_stop", final)
                    legacy = targets(await rendered("legacy", kind="nap"))
                    self.assertIn("input_button.commute_alarm_stop", legacy)
                    self.assertIn("input_button.commute_alarm_snooze", legacy)
                    snoozed = targets(
                        await rendered("legacy", kind="nap", state="snoozed")
                    )
                    self.assertIn("input_button.commute_alarm_stop", snoozed)
                    self.assertNotIn("input_button.commute_alarm_snooze", snoozed)
                    idle = json.dumps(await rendered(state="idle"))
                    for token in (
                        "CC_SNOOZE:",
                        "commute_alarm_stop",
                        "commute_alarm_snooze",
                    ):
                        self.assertNotIn(token, idle)
                    for playback in ("starting", "stopped", "failed"):
                        self.assertNotIn(
                            "CC_SNOOZE:",
                            json.dumps(
                                await rendered(ring_attrs={"playback": playback})
                            ),
                            playback,
                        )
                    self.assertNotIn(
                        "CC_SNOOZE:", json.dumps(await rendered(audio_failed=True))
                    )
                    # Boundary from the shared contract: exactly max_age is fresh, +1 is stale.
                    for age, fresh in ((max_age, True), (max_age + 1, False)):
                        at = (
                            (runtime.now - timedelta(seconds=age))
                            .isoformat()
                            .replace("+00:00", "Z")
                        )
                        cards = json.dumps(
                            await rendered(
                                observed_at=at,
                                ring_attrs={"started_at": at, "checked_at": at},
                                session_attrs={"original_at": at},
                            )
                        )
                        (self.assertIn if fresh else self.assertNotIn)(
                            "CC_SNOOZE:", cards, age
                        )
                    # Exact window action shape (replay into the script is its own test).
                    actions = [
                        c["tap_action"]
                        for c in walk(await rendered())
                        if c.get("tap_action", {}).get("perform_action")
                        == "script.commute_alarm_reconcile"
                    ]
                    self.assertEqual(
                        actions,
                        [
                            {
                                "action": "perform-action",
                                "perform_action": "script.commute_alarm_reconcile",
                                "data": {
                                    "request": "CC_SNOOZE:"
                                    + "a" * 32
                                    + ":"
                                    + "b" * 32
                                    + ":window"
                                },
                            }
                        ],
                    )
                    # Identity/timestamp validation hides every control.
                    no_controls = (
                        "CC_SNOOZE:",
                        "commute_alarm_stop",
                        "commute_alarm_snooze",
                    )

                    def hidden(cards, label, no_controls=no_controls):
                        text = json.dumps(cards)
                        for token in no_controls:
                            self.assertNotIn(token, text, label)

                    later = (
                        (runtime.now + timedelta(seconds=5))
                        .isoformat()
                        .replace("+00:00", "Z")
                    )
                    earlier = (
                        (runtime.now - timedelta(seconds=5))
                        .isoformat()
                        .replace("+00:00", "Z")
                    )
                    stale_check = (
                        (runtime.now - timedelta(seconds=max_age + 1))
                        .isoformat()
                        .replace("+00:00", "Z")
                    )
                    invalid = {
                        "session id malformed": {"session_attrs": {"id": "A" * 32}},
                        "ring id malformed": {"ring_attrs": {"id": "short"}},
                        "ring id missing": {"ring_attrs": {"id": None}},
                        "schema 2": {"schema": 2},
                        "naive observed_at": {
                            "observed_at": runtime.now.replace(tzinfo=None).isoformat()
                        },
                        "original after observed": {
                            "session_attrs": {"original_at": later}
                        },
                        "started before original": {
                            "session_attrs": {
                                "original_at": runtime.now.isoformat().replace(
                                    "+00:00", "Z"
                                )
                            },
                            "ring_attrs": {"started_at": earlier},
                        },
                        "checked after observed": {"ring_attrs": {"checked_at": later}},
                        "checked_at stale": {
                            "ring_attrs": {
                                "started_at": stale_check,
                                "checked_at": stale_check,
                            },
                            "session_attrs": {"original_at": stale_check},
                        },
                        "window without deadline": {
                            "session_attrs": {"locked_deadline_at": None}
                        },
                        "deadline not after original": {
                            "session_attrs": {
                                "locked_deadline_at": runtime.now.isoformat().replace(
                                    "+00:00", "Z"
                                )
                            }
                        },
                        "ended for this session": {
                            "ended": {"wake": {"session_id": "a" * 32}, "nap": None}
                        },
                    }
                    for label, kwargs in invalid.items():
                        hidden(await rendered(**kwargs), label)
                    nap_window = await rendered(kind="nap")
                    hidden(nap_window, "nap outside legacy")
                    legacy_with_deadline_state, legacy_with_deadline = status(
                        runtime.now, "legacy", kind="nap"
                    )
                    await runtime.set(
                        "sensor.commute_alarm_status",
                        legacy_with_deadline_state,
                        legacy_with_deadline,
                    )
                    hidden(template.async_render(), "legacy with deadline")
                    # The legacy input_select mirror is display-only: never unlocks controls.
                    for mirror in ("ringing", "snoozed"):
                        await runtime.set("input_select.commute_alarm_state", mirror)
                        for status_value in ("unavailable", "idle"):
                            await runtime.set(
                                "sensor.commute_alarm_status", status_value
                            )
                            cards = template.async_render()
                            hidden(cards, f"mirror {mirror}, status {status_value}")
                            self.assertIn(
                                "Status unknown",
                                json.dumps(cards),
                                f"mirror {mirror}, status {status_value}",
                            )
                        runtime.hass.states.async_remove("sensor.commute_alarm_status")
                        cards = template.async_render()
                        hidden(cards, f"mirror {mirror}, status missing")
                    await runtime.set("input_select.commute_alarm_state", "idle")
                    # At locked_deadline_at a still-'window' export hides controls before the next export.
                    deadline_state, at_deadline = status(runtime.now)
                    saved_now = runtime.now
                    runtime.now = datetime.fromisoformat(
                        at_deadline["session"]["locked_deadline_at"]
                    )
                    observed = (
                        (runtime.now - timedelta(seconds=10))
                        .isoformat()
                        .replace("+00:00", "Z")
                    )
                    at_deadline["observed_at"] = at_deadline["ring"]["checked_at"] = (
                        observed
                    )
                    await runtime.set(
                        "sensor.commute_alarm_status", deadline_state, at_deadline
                    )
                    cards = template.async_render()
                    self.assertNotIn(
                        "CC_SNOOZE:",
                        json.dumps(cards),
                        "window snooze visible at locked deadline",
                    )
                    self.assertIn("Dismiss at desktop", json.dumps(cards))
                    runtime.now = saved_now
                    for offset in (-(max_age + 1), 1):
                        observed = (
                            (runtime.now + timedelta(seconds=offset))
                            .isoformat()
                            .replace("+00:00", "Z")
                        )
                        invalid_cards = await rendered(observed_at=observed)
                        self.assertNotIn("CC_SNOOZE:", json.dumps(invalid_cards))
                        invalid = targets(invalid_cards)
                        self.assertNotIn("input_button.commute_alarm_snooze", invalid)
                        self.assertNotIn("input_button.commute_alarm_stop", invalid)
                self.assertIn(
                    "commute_alarm_enabled",
                    generated["hass"]["input_boolean"],
                    "master switch must remain available",
                )
                self.assertTrue(
                    any(
                        c.get("tap_action", {}).get("target", {}).get("entity_id")
                        == "input_button.commute_nap_30"
                        for c in walk(generated["dashboards"])
                    )
                )

        async def test_offline_fallback_claim_and_playback_ack(self):
            async with Runtime(generated) as runtime:
                await runtime.set("input_boolean.commute_alarm_enabled", "on")
                await runtime.set(
                    "input_text.commute_wake_utc", runtime.now.isoformat()
                )
                await runtime.set(
                    "input_text.commute_nap_utc", "1970-01-01T00:00:00+00:00"
                )
                await runtime.set(
                    "input_text.commute_alarm_heartbeat_utc",
                    (runtime.now - timedelta(seconds=181)).isoformat(),
                )
                runtime.now += timedelta(seconds=60)
                await runtime.run("commute_alarm_fallback_check")
                pushes = [
                    data
                    for domain, service, data in runtime.calls
                    if domain == "notify"
                ]
                self.assertEqual(len(pushes), 1)
                self.assertEqual(pushes[0]["data"]["push"]["sound"]["critical"], 1)
                await runtime.run("commute_alarm_fallback_check")
                self.assertEqual(
                    len([c for c in runtime.calls if c[0] == "notify"]),
                    1,
                    "fallback must claim once per instant",
                )
                # A successful per-wake audio acknowledgement suppresses fallback;
                # heartbeat alone must not acknowledge a wake.
                runtime.now += timedelta(minutes=10)
                await runtime.set(
                    "input_text.commute_wake_utc", runtime.now.isoformat()
                )
                await runtime.set(
                    "input_text.commute_alarm_handled_at", runtime.now.isoformat()
                )
                await runtime.set(
                    "input_text.commute_alarm_heartbeat_utc", runtime.now.isoformat()
                )
                runtime.now += timedelta(seconds=60)
                await runtime.run("commute_alarm_fallback_check")
                self.assertEqual(len([c for c in runtime.calls if c[0] == "notify"]), 1)

        async def test_legacy_wake_utc_and_clear(self):
            async with Runtime(generated) as runtime:
                await runtime.run(
                    "commute_publish_alarm",
                    wake_at="2026-11-05T08:00:00-05:00",
                    next_prep_at="2026-11-05T08:00:00-05:00",
                )
                self.assertEqual(
                    runtime.state("input_text.commute_wake_utc"),
                    "2026-11-05T13:00:00+00:00",
                )
                await runtime.run(
                    "commute_publish_alarm", wake_at="1970-01-01T00:00:00Z"
                )
                self.assertEqual(
                    runtime.state("input_text.commute_wake_utc"),
                    "1970-01-01T00:00:00+00:00",
                )

    names = list(selected) or unittest.defaultTestLoader.getTestCaseNames(Cases)
    suite = unittest.TestSuite(Cases(name) for name in names if name not in excluded)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    main()
