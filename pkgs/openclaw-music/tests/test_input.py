import unittest

from openclaw_music.errors import InvalidInput
from openclaw_music.input import load_json, parse
from openclaw_music.slskd import safe_remote_filename


class InputTests(unittest.TestCase):
    def test_duplicate_keys_size_nesting_and_unicode_are_rejected(self):
        for value in (
            '{"schema":1,"schema":1}',
            b"x" * 65_537,
            '{"schema":' + "[" * 13 + "]" * 13 + "}",
        ):
            with (
                self.subTest(value=type(value).__name__),
                self.assertRaises(InvalidInput),
            ):
                load_json(value)
        with self.assertRaises(InvalidInput):
            load_json('{"schema":1,"text":"\\ud800"}')

    def test_submit_and_choose_are_strict(self):
        base = {
            "schema": 1,
            "idempotency_key": "a",
            "artist": "Artist",
            "release": "Album",
        }
        self.assertNotIn("quality_profile", parse("submit", base))
        for update in ({"quality_profile": 1}, {"extra": 1}, {"include_live": "yes"}):
            value = dict(base)
            value.update(update)
            with self.assertRaises(InvalidInput):
                parse("submit", value)
        with self.assertRaises(InvalidInput):
            parse(
                "choose",
                {
                    "schema": 1,
                    "job_id": "00000000-0000-0000-0000-000000000000",
                    "candidate_id": "x",
                    "revision": 1,
                },
            )

    def test_remote_paths_reject_windows_escape_forms(self):
        self.assertEqual(
            safe_remote_filename("Album\\01 - One.wav"), "Album/01 - One.wav"
        )
        for path in ("../x", "/x", "C:\\x", "a/../../b", "a/\x00b", "\\\\host\\x"):
            with self.subTest(path=path), self.assertRaises(InvalidInput):
                safe_remote_filename(path)
