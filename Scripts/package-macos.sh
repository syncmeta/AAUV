#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
# One reusable build tree; hold its lock through signing and source packaging.
# The OS releases this advisory lock after failures or process termination.
mkdir -p "$root/build"
exec python3 "$root/Scripts/with-build-lock.py" "$root/build/.mac-package.lock" -- \
  sh "$root/Scripts/package-macos-worker.sh" "$@"
