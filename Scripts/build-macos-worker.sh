#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
# Internal worker: public build/package entry points hold the shared lock.
xcodebuild -project "$root/AAUV.xcodeproj" -scheme AAUV_macOS \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$root/build/mac" \
  -clonedSourcePackagesDirPath "$root/build/markdown-packages" \
  -packageCachePath "$root/build/swiftpm-cache" \
  -scmProvider system -skipPackageUpdates -disablePackageRepositoryCache \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_DEBUG_DYLIB=NO \
  COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build
