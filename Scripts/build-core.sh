#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/Scripts/build-mobile-tools.sh"
export PATH="$root/build/tools/bin:$PATH"
export GOCACHE="${GOCACHE:-$root/build/go-cache}"
export GOMODCACHE="$(go env GOMODCACHE)"
export CLANG_MODULE_CACHE_PATH="$root/build/clang-core-cache"
mkdir -p "$root/Vendor"
framework="$root/Vendor/AAUVCore.xcframework"
stage=$(mktemp -d "$root/build/core.XXXXXXXX")
cleanup() {
  if [ ! -e "$framework" ] && [ -e "$stage/previous" ]; then
    mv "$stage/previous" "$framework" || return
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cd "$root/core"
gomobile bind -target=ios,iossimulator,macos -iosversion=17.0 \
  -o "$stage/AAUVCore.xcframework" .
if [ -e "$framework" ]; then
  mv "$framework" "$stage/previous"
fi
mv "$stage/AAUVCore.xcframework" "$framework"
