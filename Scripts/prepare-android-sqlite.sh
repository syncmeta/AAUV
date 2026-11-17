#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
version=3540100
checksum=92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
asset="sqlite-amalgamation-$version.zip"
download="https://www.sqlite.org/2026/$asset"
if [ "${1:-}" = source-info ]; then
  printf '%s\n' "$asset" "$download" "$checksum"
  exit 0
fi
archive="$root/build/upstream/$asset"
destination="$root/core/build/android-sqlite-$version"
mkdir -p "$root/build/upstream" "$root/core/build"
stage=$(mktemp -d "$root/core/build/sqlite.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$archive" ]; then
  source="$archive"
elif [ -f "$root/ThirdPartySources/$asset" ]; then
  source="$root/ThirdPartySources/$asset"
else
  curl --fail --silent --show-error --location --connect-timeout 15 --max-time 90 \
    "$download" -o "$stage/$asset"
  source="$stage/$asset"
fi

python3 - "$source" "$stage" "$version" "$checksum" <<'PY'
from hashlib import sha3_256
from pathlib import Path
from sys import argv
from zipfile import ZipFile

source, stage, version, checksum = argv[1:]
digest = sha3_256(Path(source).read_bytes()).hexdigest()
if digest != checksum:
    raise SystemExit("SQLite archive does not match the published SHA3-256 digest")
with ZipFile(source) as archive:
    for name in ("sqlite3.c", "sqlite3.h"):
        path = Path(stage, name)
        path.write_bytes(archive.read(f"sqlite-amalgamation-{version}/{name}"))
PY

if [ "$source" = "$stage/$asset" ]; then
  mv "$source" "$archive"
fi
mkdir -p "$destination"
for name in sqlite3.c sqlite3.h; do
  if ! cmp -s "$stage/$name" "$destination/$name"; then
    mv -f "$stage/$name" "$destination/$name"
  fi
done
