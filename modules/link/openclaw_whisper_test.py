"""Offline, stdlib-only fixtures; never touch live OpenClaw state or audio."""

import copy
import io
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

# This test is intentionally executed as a standalone script beside its sources.
import openclaw_audio_config_patch as config_patch  # pyright: ignore[reportImplicitRelativeImport]
import openclaw_whisper as whisper  # pyright: ignore[reportImplicitRelativeImport]

COMMAND = "/nix/store/fixture-openclaw-whisper/bin/openclaw-whisper"
BROWSER_COMMAND = "/nix/store/fixture-openclaw-chromium/bin/openclaw-chromium"


def fixture() -> dict[str, Any]:
    return {
        "auth": {"profiles": {"codex": {"provider": "openai-codex", "mode": "oauth"}}},
        "agents": {"defaults": {"model": "anthropic/claude", "prompt": "unchanged"}},
        "models": {"providers": {"openai": {"replySettings": {"reasoning": "high"}}}},
        "tools": {
            "media": {
                "audio": {
                    "enabled": True,
                    "maxBytes": 26214400,
                    "echoTranscript": True,
                },
                "models": [
                    {
                        "provider": "openai",
                        "model": "gpt-transcribe",
                        "profile": "codex",
                        "capabilities": ["audio"],
                    },
                    {
                        "provider": "google",
                        "model": "gemini-3-flash-preview",
                        "capabilities": ["audio"],
                        "timeoutSeconds": 42,
                        "providerOptions": {"google": {"nested": [1, {"keep": True}]}},
                        "prompt": "keep Gemini settings",
                    },
                    {
                        "provider": "openai",
                        "model": "gpt-transcribe",
                        "capabilities": ["image"],
                    },
                    {
                        "provider": "openai",
                        "model": "other-audio",
                        "capabilities": ["audio"],
                    },
                ],
            }
        },
    }


class ConfigTests(unittest.TestCase):
    def test_browser_fields_preservation_and_idempotency(self):
        original = fixture()
        original["browser"] = {
            "enabled": False,
            "headless": False,
            "executablePath": "/desktop/chromium",
            "noSandbox": False,
            "defaultProfile": "custom",
            "extraArgs": ["--keep-this"],
            "profiles": {
                "custom": {"executablePath": "/private/override", "cdpPort": 19000},
                "remote": {"cdpUrl": "http://127.0.0.1:19001", "color": "#123456"},
            },
        }
        untouched = copy.deepcopy(original)
        with patch("sys.stderr", io.StringIO()) as diagnostics:
            result = config_patch.patch_config(original, COMMAND, BROWSER_COMMAND)
            self.assertEqual(
                config_patch.patch_config(result, COMMAND, BROWSER_COMMAND), result
            )
        self.assertIn("may shadow", diagnostics.getvalue())
        self.assertNotIn("/private/override", diagnostics.getvalue())
        self.assertEqual(original, untouched)
        expected = config_patch.patch_config(original, COMMAND)
        expected["browser"].update(
            enabled=True, headless=True, executablePath=BROWSER_COMMAND
        )
        self.assertEqual(result, expected)

    def test_browser_creation_and_old_audio_only_interface(self):
        original = fixture()
        audio_only = config_patch.patch_config(original, COMMAND)
        self.assertNotIn("browser", audio_only)
        result = config_patch.patch_config(original, COMMAND, BROWSER_COMMAND)
        self.assertEqual(
            result["browser"],
            {"enabled": True, "headless": True, "executablePath": BROWSER_COMMAND},
        )
        # Audio-only callers must not inspect or mutate even an invalid browser.
        original["browser"] = None
        self.assertIsNone(config_patch.patch_config(original, COMMAND)["browser"])

    def test_browser_malformed_fails_without_writes(self):
        invalids = [
            None,
            [],
            "secret",
            1,
            {"profiles": None},
            {"profiles": []},
            {"profiles": {"custom": None}},
            {"profiles": {"custom": {"executablePath": 1}}},
            {"enabled": "true"},
            {"headless": 1},
            {"executablePath": []},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "openclaw.json"
            for browser in invalids:
                with self.subTest(browser=browser):
                    config = fixture()
                    config["browser"] = browser
                    original = json.dumps(config).encode()
                    path.write_bytes(original)
                    path.chmod(0o600)
                    with self.assertRaises((ValueError, TypeError)):
                        config_patch.patch_file(path, COMMAND, BROWSER_COMMAND)
                    self.assertEqual(path.read_bytes(), original)
                    self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_browser_file_backup_and_cli_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "openclaw.json"
            original = json.dumps(fixture()).encode()
            path.write_bytes(original)
            path.chmod(0o600)
            with (
                patch("sys.argv", ["patch", str(path), COMMAND]),
                patch("sys.stderr", io.StringIO()),
            ):
                self.assertEqual(config_patch.main(), 0)
            self.assertNotIn("browser", json.loads(path.read_bytes()))
            before_browser = path.read_bytes()
            with (
                patch("sys.argv", ["patch", str(path), COMMAND, BROWSER_COMMAND]),
                patch("sys.stderr", io.StringIO()),
            ):
                self.assertEqual(config_patch.main(), 0)
                inode = path.stat().st_ino
                self.assertEqual(config_patch.main(), 0)
            self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual(
                json.loads(path.read_bytes())["browser"]["executablePath"],
                BROWSER_COMMAND,
            )
            backups = list(Path(directory).glob("*.pre-whisper-*"))
            self.assertEqual(len(backups), 2)
            self.assertEqual(
                {p.read_bytes() for p in backups}, {original, before_browser}
            )
            self.assertTrue(
                all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in [path] + backups)
            )

    def test_deep_invariants_and_idempotency(self):
        original = fixture()
        untouched = copy.deepcopy(original)
        result = config_patch.patch_config(original, COMMAND)
        self.assertEqual(original, untouched)
        expected = copy.deepcopy(original)
        expected["tools"]["media"]["models"] = [
            {
                "type": "cli",
                "command": COMMAND,
                "args": ["{{AttachmentPath}}"],
                "timeoutSeconds": 300,
                "capabilities": ["audio"],
            },
        ] + original["tools"]["media"]["models"][1:]
        self.assertEqual(result, expected)
        self.assertEqual(config_patch.patch_config(result, COMMAND), result)
        result["tools"]["media"]["models"].append(
            {
                "type": "cli",
                "command": "/nix/store/old/bin/openclaw-whisper",
                "capabilities": ["audio"],
                "args": ["old"],
            }
        )
        self.assertEqual(config_patch.patch_config(result, COMMAND), expected)

    def test_combined_openai_keeps_image(self):
        original = fixture()
        original["tools"]["media"]["models"][0]["capabilities"].append("image")
        result = config_patch.patch_config(original, COMMAND)
        preserved = result["tools"]["media"]["models"][1]
        self.assertEqual(
            preserved,
            {
                **original["tools"]["media"]["models"][0],
                "capabilities": ["image"],
            },
        )

    def test_atomic_private_backup_and_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "openclaw.json"
            original = json.dumps(fixture()).encode()
            path.write_bytes(original)
            path.chmod(0o600)
            os.utime(
                path, (1, 2)
            )  # Reads can advance atime; must not look like an edit.
            with patch("sys.stderr", io.StringIO()):
                self.assertTrue(config_patch.patch_file(path, COMMAND))
                inode = path.stat().st_ino
                after = path.read_bytes()
                self.assertFalse(config_patch.patch_file(path, COMMAND))
            self.assertEqual(path.read_bytes(), after)
            self.assertEqual(path.stat().st_ino, inode)
            backups = list(Path(directory).glob("*.pre-whisper-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), original)
            for item in (path, backups[0]):
                self.assertEqual(stat.S_IMODE(item.stat().st_mode), 0o600)
            self.assertEqual(len(list(Path(directory).iterdir())), 2)

    def test_refuses_unknown_and_malformed_without_writes(self):
        unknown = fixture()
        del unknown["tools"]["media"]["models"][0]["capabilities"]
        invalids = [
            b"{",
            b'{"tools": {}, "tools": {}}',
            b"{}",
            json.dumps(unknown).encode(),
            b'{"value": NaN}',
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "openclaw.json"
            for contents in invalids:
                path.write_bytes(contents)
                path.chmod(0o600)
                with self.assertRaises(ValueError):
                    config_patch.patch_file(path, COMMAND)
                self.assertEqual(path.read_bytes(), contents)
                self.assertEqual(list(Path(directory).iterdir()), [path])
            path.write_text(json.dumps(fixture()))
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                config_patch.patch_file(path, COMMAND)
            link = Path(directory) / "link.json"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                config_patch.patch_file(link, COMMAND)


class WrapperTests(unittest.TestCase):
    def exercise(self, failure=None, text="  a plain transcript\n"):
        directories = []
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "audio with spaces;not shell.ogg"
            source.write_bytes(b"mock audio, not a recording")
            icd = Path(directory) / "radv.json"
            icd.write_text("{}")

            def run(argv, **kwargs):
                calls.append((argv, kwargs))
                output = Path(argv[argv.index("--output-file") + 1])
                directories.append(output.parent)
                self.assertEqual(
                    argv,
                    [
                        "whisper",
                        "--model",
                        "model",
                        "--file",
                        str(source.resolve()),
                        "--language",
                        "auto",
                        "--output-txt",
                        "--output-file",
                        str(output),
                    ],
                )
                self.assertEqual(list(output.parent.iterdir()), [])
                self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o700)
                self.assertEqual(kwargs["env"]["VK_DRIVER_FILES"], str(icd))
                if failure == "cli":
                    raise subprocess.CalledProcessError(2, argv)
                if failure == "timeout":
                    raise subprocess.TimeoutExpired(argv, 230)
                if failure != "missing-output":
                    output.with_suffix(".txt").write_text(text)

            with (
                patch.object(whisper, "RADV_ICD", str(icd)),
                patch.object(whisper.subprocess, "run", side_effect=run),
            ):
                if failure:
                    with self.assertRaises((OSError, subprocess.SubprocessError)):
                        whisper.transcribe(source, whisper="whisper", model="model")
                else:
                    self.assertEqual(
                        whisper.transcribe(source, whisper="whisper", model="model"),
                        text.strip(),
                    )
        self.assertTrue(directories)
        self.assertEqual(len(calls), 1)
        self.assertTrue(all(not path.exists() for path in directories))
        for _, kwargs in calls:
            self.assertIs(kwargs["stdout"], subprocess.DEVNULL)
            self.assertIs(kwargs["stderr"], whisper.sys.stderr)
            self.assertTrue(kwargs["check"])
            self.assertEqual(kwargs["timeout"], 230)

    def test_success_spaces_and_cleanup(self):
        self.exercise()

    def test_silence_is_valid(self):
        self.exercise(text="")

    def test_failures_and_cleanup(self):
        for failure in ("cli", "timeout", "missing-output"):
            with self.subTest(failure=failure):
                self.exercise(failure)

    def test_missing_unreadable_and_directory_input(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(whisper.subprocess, "run") as run,
        ):
            with self.assertRaises(FileNotFoundError):
                whisper.transcribe(Path(directory) / "missing")
            with self.assertRaises(ValueError):
                whisper.transcribe(directory)
            source = Path(directory) / "unreadable"
            source.touch()
            with (
                patch.object(Path, "open", side_effect=PermissionError("fixture")),
                self.assertRaises(PermissionError),
            ):
                whisper.transcribe(source)
            run.assert_not_called()

    def test_cli_stdout_and_nonzero_contract(self):
        with (
            patch.object(whisper.sys, "argv", ["openclaw-whisper", "spaced path"]),
            patch.object(whisper, "transcribe", return_value="only transcript"),
            patch("sys.stdout", new_callable=io.StringIO) as stdout,
        ):
            self.assertEqual(whisper.main(), 0)
            self.assertEqual(stdout.getvalue(), "only transcript\n")
        for error in (
            FileNotFoundError(),
            subprocess.CalledProcessError(1, ["whisper"]),
            subprocess.TimeoutExpired(["whisper"], 230),
        ):
            with (
                patch.object(whisper.sys, "argv", ["openclaw-whisper", "file"]),
                patch.object(whisper, "transcribe", side_effect=error),
                patch("sys.stdout", new_callable=io.StringIO) as stdout,
                patch("sys.stderr", new_callable=io.StringIO) as stderr,
            ):
                self.assertEqual(whisper.main(), 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertIn("openclaw-whisper:", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
