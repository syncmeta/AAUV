#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
if [ "$#" -ne 0 ]; then
  echo 'Usage: build-macos.sh (universal Release build in build/mac)' >&2
  exit 2
fi
# Reuse this entry point for routine acceptance builds; keep logs and test
# fixtures separate instead of cloning entire DerivedData or dependency trees.
mkdir -p "$root/build"
exec python3 "$root/Scripts/with-build-lock.py" "$root/build/.mac-package.lock" -- \
  sh "$root/Scripts/build-macos-worker.sh"
