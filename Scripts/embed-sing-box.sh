#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
engine=${AAUV_SING_BOX_BINARY:-$root/Vendor/sing-box}
if [ ! -x "$engine" ]; then
  echo 'error: Run Scripts/build-proxy.sh macos to build the AAUV proxy.' >&2
  exit 1
fi
if [ -n "${AAUV_SING_BOX_BINARY:-}" ] && [ -z "${AAUV_SING_BOX_LICENSE:-}" ]; then
  echo 'error: Set AAUV_SING_BOX_LICENSE for the supplied proxy binary.' >&2
  exit 1
fi
license=${AAUV_SING_BOX_LICENSE:-$root/Vendor/sing-box-LICENSE}
if [ ! -r "$license" ]; then
  echo "error: Missing proxy license notice at $license" >&2
  exit 1
fi
for arch in $ARCHS; do
  /usr/bin/lipo -verify_arch "$arch" "$engine"
done
/usr/bin/install -m 755 "$engine" "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/sing-box"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
    "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/sing-box"
fi
/usr/bin/install -m 644 "$license" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/sing-box-LICENSE"
