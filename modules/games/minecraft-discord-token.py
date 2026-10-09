"""Prepare only DiscordSRV's text token; generic game secrets remain raw bytes."""

import os
from pathlib import Path
import pwd
import sys
import tempfile


def prepare(source, destination):
    token = source.read_bytes().decode("utf-8").strip()
    if not token:
        raise ValueError("DiscordSRV token is empty after trimming whitespace")
    destination.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    descriptor, filename = tempfile.mkstemp(dir=destination.parent, prefix=".discord-token-")
    temporary = Path(filename)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(token.encode("utf-8"))
            output.flush()
            os.fsync(output.fileno())
        # Replace the directory entry without following a pre-existing token symlink.
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    if len(sys.argv) != 3:
        raise ValueError("expected token source and destination paths")
    identity = pwd.getpwnam("minecraft")
    # Plugin directories are writable by Minecraft, so root must not write there.
    os.setgroups([])
    os.setgid(identity.pw_gid)
    os.setuid(identity.pw_uid)
    prepare(Path(sys.argv[1]), Path(sys.argv[2]))


if __name__ == "__main__":
    main()
