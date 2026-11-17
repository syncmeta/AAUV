#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$ANDROID_HOME" ] || [ ! -d "$ANDROID_HOME/platforms" ]; then
  echo 'error: Set ANDROID_HOME to an Android SDK with an installed platform.' >&2
  exit 1
fi
if [ -n "${JAVA_HOME:-}" ]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi
if ! javac -version >/dev/null 2>&1 || ! command -v jar >/dev/null 2>&1; then
  echo 'error: Install a JDK and set JAVA_HOME or add its bin directory to PATH.' >&2
  exit 1
fi

"$root/Scripts/prepare-android-sqlite.sh"
"$root/Scripts/build-mobile-tools.sh"
export PATH="$root/build/tools/bin:$PATH"
export GOCACHE="${GOCACHE:-$root/build/go-cache}"
export GOMODCACHE="$(go env GOMODCACHE)"
export GOWORK=off
mkdir -p "$root/Vendor"
stage=$(mktemp -d "$root/build/android-core.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM

cd "$root/core"
gomobile bind -target=android/arm64,android/amd64 -androidapi=24 \
  -javapkg=com.pendingname.aauv -trimpath -buildvcs=false \
  -ldflags='-s -w -extldflags=-Wl,-z,max-page-size=16384' \
  -o "$stage/AAUVCore.aar" .
mv -f "$stage/AAUVCore.aar" "$root/Vendor/AAUVCore.aar"
