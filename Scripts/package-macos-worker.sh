#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
destination=${1:-$root/build/dist/AAUV-macOS-local.zip}
identity=${AAUV_MAC_SIGNING_IDENTITY:--}
profile=${AAUV_MAC_PROVISIONING_PROFILE:-}
device=${AAUV_MAC_DEVICE_ID:-}
if [ "$#" -gt 1 ] || [ -e "$destination" ] || [ -L "$destination" ]; then
  echo 'Choose one new ZIP output path; existing outputs are never replaced.' >&2
  exit 1
fi
if [ -z "$profile" ] && [ -n "$device" ]; then
  echo 'AAUV_MAC_DEVICE_ID requires an explicit AAUV_MAC_PROVISIONING_PROFILE.' >&2
  exit 1
fi
mkdir -p "$(dirname "$destination")"
stage=$(mktemp -d "$root/build/mac-package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM

# Local mode deliberately omits restricted claims. Profile mode validates its
# explicit inputs before any build/signing and uses a frozen profile copy.
if [ -n "$profile" ]; then
  cp "$profile" "$stage/development.provisionprofile"
  python3 "$root/Scripts/macos-development-profile.py" prepare \
    --profile "$stage/development.provisionprofile" --identity-sha1 "$identity" \
    --device-id "$device" --source-entitlements "$root/AAUV-App-macOS.entitlements" \
    --output-entitlements "$stage/main.entitlements"
fi
sh "$root/Scripts/build-macos-worker.sh"

mkdir "$stage/AAUV"
app="$stage/AAUV/AAUV.app"
ditto "$root/build/mac/Build/Products/Release/AAUV.app" "$app"

# Keep the vendor signatures and exact runtime bytes. Seal the complete app
# only after the embedded executables and resources have been copied.
for architecture in arm64 x86_64; do
  /usr/bin/lipo -verify_arch "$architecture" "$app/Contents/MacOS/AAUV"
  /usr/bin/lipo -verify_arch "$architecture" "$app/Contents/MacOS/sing-box"
  folder="$app/Contents/MacOS/Copilot-$architecture"
  /usr/bin/lipo -verify_arch "$architecture" "$folder/bridge"
  /usr/bin/codesign --force --sign "$identity" --timestamp=none "$folder/bridge"
  for executable in copilot-runtime runtime.node; do
    /usr/bin/lipo -verify_arch "$architecture" "$folder/$executable"
    cmp "$root/Vendor/copilot/$architecture/$executable" "$folder/$executable"
    /usr/bin/codesign --verify --strict "$folder/$executable"
  done
done
/usr/bin/codesign --force --sign "$identity" --timestamp=none "$app/Contents/MacOS/sing-box"
if [ -n "$profile" ]; then
  cp "$stage/development.provisionprofile" "$app/Contents/embedded.provisionprofile"
  /usr/bin/codesign --force --sign "$identity" --timestamp=none \
    --entitlements "$stage/main.entitlements" "$app"
  python3 "$root/Scripts/macos-development-profile.py" verify \
    --profile "$stage/development.provisionprofile" --identity-sha1 "$identity" \
    --device-id "$device" --source-entitlements "$root/AAUV-App-macOS.entitlements" --app "$app"
else
  /usr/bin/codesign --force --sign "$identity" --timestamp=none "$app"
  /usr/bin/codesign --verify --deep --strict "$app"
fi

python3 "$root/Scripts/package-source.py" "$stage/AAUV/AAUV-source.tar.gz"
ditto -c -k --sequesterRsrc --keepParent "$stage/AAUV" "$stage/AAUV-macOS-local.zip"
# Publish without replacing an existing path, including a concurrent writer.
python3 - "$stage/AAUV-macOS-local.zip" "$destination" <<'PY'
from pathlib import Path
import os, shutil, sys, tempfile
source, destination = map(Path, sys.argv[1:])
with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.aauv-package-') as pending:
    with source.open('rb') as original:
        shutil.copyfileobj(original, pending)
    pending.flush()
    os.fsync(pending.fileno())
    os.link(pending.name, destination)
PY
echo "$destination"
