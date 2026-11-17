#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/Vendor/copilot"
executables="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
for arch in arm64 x86_64; do
  source="$vendor/$arch"
  destination="$executables/Copilot-$arch"
  if [ -x "$source/bridge" ] && [ -x "$source/copilot-runtime" ] && [ -r "$source/runtime.node" ]; then
    mkdir -p "$destination"
    for file in bridge copilot-runtime runtime.node; do
      if ! cmp -s "$source/$file" "$destination/$file"; then
        install -m 755 "$source/$file" "$destination/$file"
      fi
    done
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
      /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$destination/bridge"
    fi
    install -m 644 "$source/CLI-LICENSE" "$resources/copilot-cli-$arch-LICENSE"
    install -m 644 "$vendor/SDK-LICENSE" "$resources/copilot-sdk-LICENSE"
  else
    rm -f "$destination/bridge" "$destination/copilot-runtime" "$destination/runtime.node"
    rm -f "$resources/copilot-cli-$arch-LICENSE"
    if [ -d "$destination" ]; then rmdir "$destination"; fi
  fi
done

if [ ! -f "$resources/copilot-cli-arm64-LICENSE" ] && [ ! -f "$resources/copilot-cli-x86_64-LICENSE" ]; then
  rm -f "$resources/copilot-sdk-LICENSE"
fi
