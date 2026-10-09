"""Text token normalization must stay private and avoid privileged plugin writes."""

import importlib.util
from pathlib import Path
import os
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("discord_token", sys.argv.pop(1))
token = importlib.util.module_from_spec(spec)
spec.loader.exec_module(token)


class TokenPreparationTest(unittest.TestCase):
    def test_surrounding_whitespace_and_source_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "agenix-token"
            destination = root / "plugin/.token"
            for value in ("first.second.third", "first.second.third\n", "\t first.second.third\r\n ", "\u2003first.second.third\u2003"):
                with self.subTest(value=value):
                    source.write_text(value)
                    token.prepare(source, destination)
                    self.assertEqual(destination.read_bytes(), b"first.second.third")
                    self.assertEqual(source.read_bytes(), value.encode("utf-8"))
                    self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
                    self.assertEqual(destination.stat().st_uid, os.getuid())
                    self.assertEqual(list(destination.parent.glob(".discord-token-*")), [])

    def test_internal_content_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / "source", Path(directory) / ".token"
            source.write_text("\nfirst.second\r\nthird.part\n")
            token.prepare(source, destination)
            self.assertEqual(destination.read_bytes(), b"first.second\r\nthird.part")

    def test_empty_token_leaves_existing_target_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / "source", Path(directory) / ".token"
            source.write_text("\n \t\r\n")
            destination.write_bytes(b"existing-token")
            with self.assertRaisesRegex(ValueError, "empty after trimming"):
                token.prepare(source, destination)
            self.assertEqual(destination.read_bytes(), b"existing-token")

    def test_existing_symlink_is_replaced_without_writing_its_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination, outside = root / "source", root / ".token", root / "outside"
            source.write_text("first.second.third\n")
            outside.write_bytes(b"untouched")
            destination.symlink_to(outside)
            token.prepare(source, destination)
            self.assertFalse(destination.is_symlink())
            self.assertEqual(outside.read_bytes(), b"untouched")
            self.assertEqual(destination.read_bytes(), b"first.second.third")

    def test_main_drops_privileges_before_secret_preparation(self):
        calls = []
        with patch.object(token.sys, "argv", ["prepare", "/source", "/destination"]), \
             patch.object(token.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=123, pw_gid=456)), \
             patch.object(token.os, "setgroups", side_effect=lambda groups: calls.append(("groups", groups))), \
             patch.object(token.os, "setgid", side_effect=lambda gid: calls.append(("gid", gid))), \
             patch.object(token.os, "setuid", side_effect=lambda uid: calls.append(("uid", uid))), \
             patch.object(token, "prepare", side_effect=lambda source, destination: calls.append(("prepare", source, destination))):
            token.main()
        self.assertEqual(calls, [("groups", []), ("gid", 456), ("uid", 123), ("prepare", Path("/source"), Path("/destination"))])


unittest.main()
