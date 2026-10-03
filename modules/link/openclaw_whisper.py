"""OpenClaw CLI contract: transcript stdout; diagnostics stderr; failures nonzero."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

WHISPER = "@WHISPER@"
MODEL = "@MODEL@"
RADV_ICD = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"


def transcribe(attachment, *, whisper=WHISPER, model=MODEL):
    source = Path(attachment).resolve(strict=True)
    if not source.is_file():
        raise ValueError("attachment is not a regular file")
    with source.open("rb"):
        pass  # Explicitly reject unreadable input before running subprocesses.
    if not Path(RADV_ICD).is_file():
        raise ValueError("RADV Vulkan driver manifest is unavailable")
    env = os.environ.copy()
    # Vulkan loader's documented driver override: expose RADV, never llvmpipe.
    env["VK_DRIVER_FILES"] = RADV_ICD
    with tempfile.TemporaryDirectory(prefix="openclaw-whisper-") as directory:
        output = Path(directory) / "transcript"
        # The pinned CLI decodes OGG/Opus directly with built-in FFmpeg support.
        # No shell interpolation, even for spaced paths; only output is temporary.
        subprocess.run(
            [
                whisper,
                "--model",
                model,
                "--file",
                str(source),
                "--language",
                "auto",
                "--output-txt",
                "--output-file",
                str(output),
            ],
            # Whisper's console transcript must not leak into gateway logs.
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=sys.stderr,
            env=env,
            timeout=230,
        )
        # Some upstream input failures return 0. Require an actual text artifact;
        # an existing empty artifact is valid silence, not a fabricated failure.
        return output.with_suffix(".txt").read_text(encoding="utf-8").strip()


def main():
    if len(sys.argv) != 2:
        print("usage: openclaw-whisper ATTACHMENT", file=sys.stderr)
        return 2
    try:
        transcript = transcribe(sys.argv[1])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"openclaw-whisper: {error}", file=sys.stderr)
        return 1
    print(transcript)
    return 0


if __name__ == "__main__":
    sys.exit(main())
