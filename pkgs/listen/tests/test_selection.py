import json
import subprocess
import unittest
from datetime import datetime, timezone
from unittest.mock import patch

from listen_queue.selection import cap_for, next_commute_duration, sample, weight


class AdapterTests(unittest.TestCase):
    def setUp(self):
        # A fixed system clock; neither event start nor payload.now is the clock.
        clock = patch("listen_queue.selection.datetime", wraps=datetime)
        self.clock = clock.start()
        self.addCleanup(clock.stop)
        self.clock.now.return_value = datetime(2026, 10, 3, 13, tzinfo=timezone.utc)

    @staticmethod
    def plan(leave_at="2026-10-03T10:00:00-04:00", minutes=30.5, **extra):
        return {
            "event_id": "event-1",
            "title": "Trip",
            "leave_at": leave_at,
            "travel_minutes": minutes,
            "arrive_at": "2026-10-03T10:30:30-04:00",
            "start": "2026-10-03T11:00:00-04:00",
            "error": None,
            **extra,
        }

    def response(self, payload):
        mock = patch(
            "listen_queue.selection.subprocess.run",
            return_value=subprocess.CompletedProcess([], 0, json.dumps(payload), ""),
        )
        result = mock.start()
        self.addCleanup(mock.stop)
        return result

    def test_persisted_fractional_duration_sets_cap(self):
        run = self.response({"plans": [self.plan()]})
        self.assertEqual(next_commute_duration(), (30.5, None))
        self.assertEqual(
            cap_for(None),
            {"minutes": 30.5, "source": "commutecompass", "reason": None},
        )
        self.assertEqual(run.call_args.args[0][-2:], ["status", "--json"])
        self.assertEqual(run.call_args.kwargs["timeout"], 5)
        self.assertFalse(run.call_args.kwargs["check"])

    def test_arrival_and_plan_error_do_not_override_duration(self):
        for arrival in (None, "2025-01-01T00:00:00Z"):
            with self.subTest(arrive_at=arrival):
                self.response(
                    {
                        "plans": [
                            self.plan(arrive_at=arrival, error="Cached routing error")
                        ]
                    }
                )
                self.assertEqual(next_commute_duration(), (30.5, None))

    def test_duration_null_missing_and_invalid(self):
        missing = self.plan()
        del missing["travel_minutes"]
        cases = [
            (missing, "commute_duration_missing"),
            (self.plan(minutes=None), "commute_duration_unavailable"),
        ]
        cases.extend(
            (self.plan(minutes=value), "commute_duration_invalid")
            for value in (
                "30.5",
                "bad",
                True,
                False,
                0,
                -1,
                float("nan"),
                float("inf"),
                -float("inf"),
                [],
                {},
            )
        )
        # An enormous JSON integer must not raise during float conversion.
        cases.append((self.plan(minutes=10**400), "commute_duration_invalid"))
        for plan, reason in cases:
            with self.subTest(duration=plan.get("travel_minutes"), reason=reason):
                self.response({"plans": [plan]})
                self.assertEqual(next_commute_duration(), (None, reason))
                self.assertEqual(
                    cap_for(None),
                    {"minutes": 45, "source": "default", "reason": reason},
                )

    def test_empty_and_past_only_plans(self):
        for plans, reason in (
            ([], "commute_no_plans"),
            (
                [self.plan(leave_at="2026-10-03T08:00:00-04:00")],
                "commute_no_upcoming_plan",
            ),
            (
                [self.plan(leave_at="2026-10-03T09:00:00-04:00")],
                "commute_no_upcoming_plan",
            ),
        ):
            with self.subTest(plans=plans):
                self.response({"plans": plans})
                self.assertEqual(next_commute_duration(), (None, reason))

    def test_multiple_plans_order_by_departure_instant(self):
        plans = [
            self.plan(leave_at="2026-10-03T09:40:00-04:00", minutes=40),
            self.plan(leave_at="2026-10-03T12:00:00Z", minutes=99),
            self.plan(leave_at="2026-10-03T15:15:00+02:00", minutes=15.25),
        ]
        self.response({"now": "2027-01-01T00:00:00Z", "plans": plans})
        self.assertEqual(next_commute_duration(), (15.25, None))

    def test_equal_departures_retain_payload_order(self):
        self.response({"plans": [self.plan(minutes=15), self.plan(minutes=20)]})
        self.assertEqual(next_commute_duration(), (15, None))

    def test_missing_next_duration_never_uses_later_trip(self):
        self.response(
            {
                "plans": [
                    self.plan(minutes=60),
                    self.plan(leave_at="2026-10-03T09:30:00-04:00", minutes=None),
                ]
            }
        )
        self.assertEqual(
            next_commute_duration(), (None, "commute_duration_unavailable")
        )

    def test_unusable_departures_are_ignored(self):
        for leave_at in (
            None,
            "bad",
            "2026-10-03T10:00:00",
            123,
            "9999-12-31T23:59:59-14:00",
        ):
            with self.subTest(leave_at=leave_at):
                self.response({"plans": [self.plan(leave_at=leave_at)]})
                self.assertEqual(
                    next_commute_duration(), (None, "commute_no_upcoming_plan")
                )
                self.response({"plans": [self.plan(leave_at=leave_at), self.plan()]})
                self.assertEqual(next_commute_duration(), (30.5, None))
        plan = self.plan()
        del plan["leave_at"]
        self.response({"plans": [plan]})
        self.assertEqual(next_commute_duration(), (None, "commute_no_upcoming_plan"))

    def test_invalid_payload_structure(self):
        for payload in (
            None,
            [],
            1,
            {},
            {"plans": None},
            {"plans": {}},
            {"plans": [None]},
            {"plans": [self.plan(), 1]},
        ):
            with self.subTest(payload=payload):
                self.response(payload)
                self.assertEqual(
                    next_commute_duration(), (None, "commute_invalid_payload")
                )

    def test_command_failures_and_bad_json(self):
        for result, reason in (
            (
                subprocess.CompletedProcess([], 1, "", "private diagnostics"),
                "commute_command_failed",
            ),
            (
                subprocess.CompletedProcess([], 0, "invalid", ""),
                "commute_invalid_payload",
            ),
        ):
            with (
                self.subTest(reason=reason),
                patch("listen_queue.selection.subprocess.run", return_value=result),
            ):
                self.assertEqual(next_commute_duration(), (None, reason))
                self.assertEqual(
                    cap_for(None),
                    {"minutes": 45, "source": "default", "reason": reason},
                )

    def test_command_exceptions_are_fallbacks(self):
        for error, reason in (
            (FileNotFoundError("missing executable"), "commute_command_unavailable"),
            (PermissionError("permission denied"), "commute_command_unavailable"),
            (ValueError("embedded null byte"), "commute_command_unavailable"),
            (subprocess.TimeoutExpired("commute", 5), "commute_timeout"),
            (
                UnicodeDecodeError("utf8", b"\xff", 0, 1, "invalid"),
                "commute_invalid_payload",
            ),
        ):
            with (
                self.subTest(reason=reason),
                patch("listen_queue.selection.subprocess.run", side_effect=error),
            ):
                self.assertEqual(next_commute_duration(), (None, reason))

    def test_flag_override_bypasses_command(self):
        with patch(
            "listen_queue.selection.subprocess.run",
            side_effect=AssertionError("Explicit cap must bypass lookup"),
        ) as run:
            self.assertEqual(
                cap_for(30), {"minutes": 30, "source": "flag", "reason": None}
            )
            run.assert_not_called()

    def test_weighting_and_selection_without_replacement(self):
        albums = [
            {
                "id": i,
                "scores": {"happy": {"score": value}, "aggressive": {"score": None}},
            }
            for i, value in enumerate((0, 1, None))
        ]
        filters = {"moods": ["happy"], "avoid_moods": []}
        self.assertEqual([weight(a, filters) for a in albums], [1, 2, 1.5])
        filters["avoid_moods"] = ["aggressive"]
        self.assertEqual(weight(albums[1], filters), 1.75)

        class Highest:
            def choices(self, population, weights):
                return [population[weights.index(max(weights))]]

        chosen = sample(albums, 10, filters, Highest())
        self.assertEqual([a["id"] for a in chosen], [1, 2, 0])
        self.assertEqual(len(albums), 3)
