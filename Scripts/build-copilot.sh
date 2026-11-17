#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
version=1.0.105
target=${1:-$(uname -m)}
case "$target" in
  all) architectures="arm64 x86_64" ;;
  arm64|x86_64) architectures=$target ;;
  *) echo "Usage: $0 [arm64|x86_64|all]" >&2; exit 2 ;;
esac

export GOWORK=off
export GOCACHE="$root/build/go-cache"
export GOMODCACHE="${GOMODCACHE:-$root/build/copilot-module-cache}"
mkdir -p "$root/build" "$GOCACHE" "$root/build/upstream" "$root/Vendor/copilot"
stage=$(mktemp -d "$root/build/copilot.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
release="https://github.com/github/copilot-cli/releases/download/v$version"

for arch in $architectures; do
  case "$arch" in
    arm64)
      goarch=arm64
      platform=darwin-arm64
      digest=bf394d7c2f3dcd81efa8d4b7adcacfe4fd748103601d334b948678f67f00fa59
      ;;
    x86_64)
      goarch=amd64
      platform=darwin-x64
      digest=f864d87ce9ad5c8e36323ea667e20ca6e761df057dae386aef1eaa561039503a
      ;;
  esac
  destination="$root/Vendor/copilot/$arch"
  mkdir -p "$stage/$arch" "$destination"
  CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" go -C "$root/copilot" build \
    -mod=readonly -trimpath -buildvcs=false -o "$stage/$arch/bridge" .
  asset="github-copilot-$version-$platform.tgz"
  archive="$root/build/upstream/$asset"
  if [ ! -f "$archive" ]; then
    curl --fail --silent --show-error --location "$release/$asset" -o "$stage/$asset"
    printf '%s  %s\n' "$digest" "$stage/$asset" | shasum -a 256 --check
    mv "$stage/$asset" "$archive"
  fi
  printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 --check
  native="package/prebuilds/$platform"
  tar -xzf "$archive" -C "$stage/$arch" "$native/copilot-runtime" "$native/runtime.node" package/LICENSE.md
  /usr/bin/lipo -verify_arch "$arch" "$stage/$arch/$native/copilot-runtime"
  /usr/bin/lipo -verify_arch "$arch" "$stage/$arch/$native/runtime.node"
  /usr/bin/lipo -verify_arch "$arch" "$stage/$arch/bridge"
  mv -f "$stage/$arch/$native/copilot-runtime" "$stage/$arch/$native/runtime.node" "$stage/$arch/bridge" "$destination/"
  install -m 644 "$stage/$arch/package/LICENSE.md" "$destination/CLI-LICENSE"
done

sdk=$(go -C "$root/copilot" list -f '{{.Dir}}' github.com/github/copilot-sdk/go)
install -m 644 "$sdk/LICENSE" "$root/Vendor/copilot/SDK-LICENSE"
