import json
import subprocess
import unittest
from unittest.mock import patch

from listen_queue.selection import cap_for, next_commute_duration, sample, weight


class AdapterTests(unittest.TestCase):
    def test_pinned_commute_payload_cannot_be_duration(self):
        payload = {
            "plans": [
                {
                    "leave_at": "2026-10-03T10:00:00-04:00",
                    "start": "2026-10-03T11:00:00-04:00",
                    "error": None,
                }
            ]
        }
        with patch(
            "listen_queue.selection.subprocess.run",
            return_value=subprocess.CompletedProcess([], 0, json.dumps(payload), ""),
        ) as run:
            self.assertEqual(
                next_commute_duration(), (None, "commute_duration_unavailable")
            )
            self.assertEqual(run.call_args.args[0][-2:], ["status", "--json"])
            self.assertEqual(cap_for(None)["minutes"], 45)

    def test_commute_errors_and_flag_override(self):
        for result in (
            subprocess.CompletedProcess([], 1, "", "private diagnostics"),
            subprocess.CompletedProcess([], 0, "invalid", ""),
        ):
            with patch("listen_queue.selection.subprocess.run", return_value=result):
                self.assertEqual(
                    cap_for(None)["reason"], "commute_duration_unavailable"
                )
        with patch(
            "listen_queue.selection.subprocess.run",
            side_effect=subprocess.TimeoutExpired("commute", 5),
        ):
            self.assertEqual(cap_for(None)["minutes"], 45)
        with patch("listen_queue.selection.next_commute_duration") as lookup:
            self.assertEqual(
                cap_for(30), {"minutes": 30, "source": "flag", "reason": None}
            )
            lookup.assert_not_called()
        with patch(
            "listen_queue.selection.next_commute_duration", return_value=(22.5, None)
        ):
            self.assertEqual(
                cap_for(None),
                {"minutes": 22.5, "source": "commutecompass", "reason": None},
            )

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
