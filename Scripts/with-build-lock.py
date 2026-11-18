#!/usr/bin/env python3
"""Run one build transaction with a nonblocking, OS-owned file lock.

Usage: with-build-lock.py LOCKFILE -- COMMAND [ARG ...]
The persistent empty lock file must not be removed: unlinking it while another
process holds it would allow two writers to acquire different file locks.
"""
import fcntl
import os
from pathlib import Path
import subprocess
import sys


def main():
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print(__doc__, file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    path.parent.mkdir(parents=True, exist_ok=True)
    # Reject links to avoid opening/truncating an unrelated file.
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"Build already running; reusable output is locked: {path}", file=sys.stderr)
            return 75
        # Inherit the descriptor so a killed coordinator cannot release the
        # lock while its build subprocess is still writing shared outputs.
        result = subprocess.run(sys.argv[3:], pass_fds=(descriptor,))
        return result.returncode if result.returncode >= 0 else 128 - result.returncode
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    sys.exit(main())
