"""Read a frozen game tree at its original paths inside a private mount namespace."""

import os
import subprocess
import sys


def main():
    if os.geteuid() != 0:
        raise PermissionError("online restic requires root")
    mount, view, source, restic, *arguments = sys.argv[1:]
    subprocess.run([mount, "--bind", view, source], check=True)
    subprocess.run([mount, "-o", "remount,bind,ro", source], check=True)
    os.execv(restic, [restic, *arguments])


if __name__ == "__main__":
    main()
