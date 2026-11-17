#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
version=1.14.3
revision=7054cac5124465ffdb145870d7c01885566711b1
repository=https://github.com/SagerNet/sing-box.git
# Enable the networking stacks used by AAUV's node importer.
tags=with_gvisor,with_quic,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0
ios_tags="$tags,with_low_memory,grpcnotrace"
target=${1:-all}
case "$target" in
  source-info) printf '%s\n' "$version" "$revision" "$repository" "$tags" "$ios_tags"; exit 0 ;;
  all|macos|ios) ;;
  *) echo "Usage: $0 [all|macos|ios|source-info]" >&2; exit 2 ;;
esac
source="$root/build/upstream/sing-box"
framework="$root/Vendor/Libbox.xcframework"
export GOCACHE="${GOCACHE:-$root/build/go-cache}"
export GOMODCACHE="$(go env GOMODCACHE)"
export CLANG_MODULE_CACHE_PATH="$root/build/clang-proxy-cache"
export GOWORK=off
export GOFLAGS=-mod=readonly

mkdir -p "$root/Vendor" "$root/build/upstream" "$GOCACHE"
stage=$(mktemp -d "$root/build/proxy.XXXXXXXX")
cleanup() {
  if [ ! -e "$framework" ] && [ ! -L "$framework" ] &&
     { [ -e "$stage/previous" ] || [ -L "$stage/previous" ]; }; then
    mv "$stage/previous" "$framework" || return
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

packaged="$root/ThirdPartySources"
if [ -f "$packaged/inventory.json" ]; then
  python3 - "$packaged" "$version" "$revision" <<'PY'
import hashlib
import json
from pathlib import Path
from sys import argv

directory = Path(argv[1])
record = json.loads((directory / "inventory.json").read_text())["source_archives"]["sing-box"]
digest = hashlib.sha256((directory / "sing-box.tar.gz").read_bytes()).hexdigest()
if (record["version"], record["revision"], record["sha256"]) != (argv[2], argv[3], digest):
    raise SystemExit("Bundled sing-box source does not match the pinned archive")
PY
  mkdir "$stage/packaged-source"
  tar -xzf "$packaged/sing-box.tar.gz" -C "$stage/packaged-source"
  source="$stage/packaged-source/sing-box"
else
  if [ ! -d "$source/.git" ]; then
    git clone --depth 1 --branch "v$version" "$repository" "$stage/source"
    test "$(git -C "$stage/source" rev-parse HEAD)" = "$revision"
    mv "$stage/source" "$source"
  fi
  if [ "$(git -C "$source" rev-parse HEAD)" != "$revision" ] ||
     [ -n "$(git -C "$source" status --porcelain --untracked-files=all)" ]; then
    echo "error: Expected an unmodified sing-box $revision at $source" >&2
    exit 1
  fi
fi

cd "$source"
ldflags="-s -w -buildid= -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$version"

if [ "$target" = all ] || [ "$target" = macos ]; then
  for arch in arm64 amd64; do
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -buildvcs=false \
      -tags "$tags" -ldflags "$ldflags" -o "$stage/sing-box-$arch" ./cmd/sing-box
  done
  /usr/bin/lipo -create "$stage/sing-box-arm64" "$stage/sing-box-amd64" \
    -output "$stage/sing-box"
  /usr/bin/lipo -verify_arch arm64 "$stage/sing-box"
  /usr/bin/lipo -verify_arch x86_64 "$stage/sing-box"
  cp LICENSE "$stage/sing-box-LICENSE"
  mv -f "$stage/sing-box-LICENSE" "$stage/sing-box" "$root/Vendor/"
fi

if [ "$target" = all ] || [ "$target" = ios ]; then
  "$root/Scripts/build-mobile-tools.sh"
  export PATH="$root/build/tools/bin:$PATH"
  # gomobile otherwise builds all three archives concurrently.
  for slice in ios/arm64 iossimulator/arm64 iossimulator/amd64; do
    name=$(printf '%s' "$slice" | tr / -)
    mkdir "$stage/$name"
    gomobile bind -target="$slice" -iosversion=17.0 -libname=box \
      -trimpath -buildvcs=false -tags "$ios_tags" \
      -ldflags "$ldflags" -o "$stage/$name/Libbox.xcframework" ./experimental/libbox
  done
  device="$stage/ios-arm64/Libbox.xcframework/ios-arm64/Libbox.framework"
  simulator="$stage/iossimulator-arm64/Libbox.xcframework/ios-arm64-simulator/Libbox.framework"
  intel="$stage/iossimulator-amd64/Libbox.xcframework/ios-x86_64-simulator/Libbox.framework"
  diff -rq "$simulator/Versions/A/Headers" "$intel/Versions/A/Headers"
  cmp "$simulator/Modules/module.modulemap" "$intel/Modules/module.modulemap"
  /usr/bin/lipo -create "$simulator/Libbox" "$intel/Libbox" -output "$stage/Libbox-simulator"
  mv "$stage/Libbox-simulator" "$simulator/Versions/A/Libbox"
  /usr/bin/xcodebuild -create-xcframework -framework "$device" -framework "$simulator" -output "$stage/Libbox.xcframework"
  cp LICENSE "$stage/sing-box-LICENSE"
  # mv handles a prior development symlink without changing its target.
  if [ -e "$framework" ] || [ -L "$framework" ]; then
    mv "$framework" "$stage/previous"
  fi
  mv "$stage/Libbox.xcframework" "$framework"
  mv -f "$stage/sing-box-LICENSE" "$root/Vendor/"
fi
