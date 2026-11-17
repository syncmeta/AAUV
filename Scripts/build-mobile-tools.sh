#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
export GOCACHE="${GOCACHE:-$root/build/go-cache}"
export GOBIN="$root/build/tools/bin"
module=github.com/sagernet/gomobile
version=v0.1.12

mkdir -p "$GOCACHE" "$GOBIN"
for tool in gomobile gobind; do
  if [ -x "$GOBIN/$tool" ] && go version -m "$GOBIN/$tool" |
    awk -v module="$module" -v version="$version" '
      $1 == "mod" && $2 == module && $3 == version { matched = 1 }
      END { exit !matched }
    '; then
    continue
  fi
  go install "$module/cmd/$tool@$version"
done
