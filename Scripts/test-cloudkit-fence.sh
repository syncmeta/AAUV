#!/bin/sh
set -eu
umask 077
root=$(cd "$(dirname "$0")/.." && pwd)
test_directory=${AAUV_CLOUD_FENCE_TEST_DIR:-"$root/build/cloudkit-configuration-fence-tests"}
module_cache="$test_directory/module-cache"
mkdir -p "$test_directory" "$module_cache"
framework="$root/Vendor/AAUVCore.xcframework/macos-arm64_x86_64"
python3 - "$root" "$test_directory" <<'PY'
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
excluded = {'AAUVApp.swift', 'MarkdownCitations.swift', 'MathRendering.swift', 'MessageMarkdown.swift'}
files = sorted(path for path in (root / 'Sources').rglob('*.swift') if path.name not in excluded)
keychain = root / 'Sources/APIKey.swift'
original = keychain.read_text()
assert original.count('"com.pendingname.aauv.byok"') == original.count('import Security\n') == 1
isolated = destination / 'APIKey.swift'
isolated.write_text(original.replace('import Security\n', 'import Security\n\nprivate let aauvSyntheticKeychainService = "com.pendingname.aauv.synthetic-tests." + UUID().uuidString\n')
                   .replace('"com.pendingname.aauv.byok"', 'aauvSyntheticKeychainService'))
files = [isolated if path == keychain else path for path in files]
(destination / 'sources').write_text(''.join('"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"\n' for path in files))
PY
if [ "$#" -eq 0 ]; then
  set -- CloudSyncConfigurationFenceTests CloudSyncRunIntentTests CloudSyncReconcileLivenessTests ConfigurationRecoveryTests ConfigurationImportTests ReplicaRecoveryTests
fi
for test_case do
  case "$test_case" in
    CloudSyncConfigurationFenceTests|CloudSyncRunIntentTests|CloudSyncReconcileLivenessTests|CloudSyncForegroundTests|CloudZoneCatchUpTests|ConfigurationRecoveryTests|ConfigurationImportTests|ReplicaRecoveryTests) ;;
    *) echo 'Only the cloud/configuration fence native fixtures are allowed.' >&2; exit 2 ;;
  esac
  xcrun swiftc -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$module_cache" -Xfrontend -disable-sandbox \
    -F "$framework" -framework AAUVCore -lsqlite3 \
    @"$test_directory/sources" "$root/Tests/$test_case.swift" \
    -o "$test_directory/$test_case" > "$test_directory/$test_case-build.log" 2>&1 || {
      cat "$test_directory/$test_case-build.log"; exit 1;
    }
  "$test_directory/$test_case" > "$test_directory/$test_case.log" 2>&1 || {
    cat "$test_directory/$test_case.log"; exit 1;
  }
  cat "$test_directory/$test_case.log"
done
