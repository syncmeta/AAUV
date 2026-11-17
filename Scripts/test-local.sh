#!/bin/sh
set -eu
umask 077

root=$(cd "$(dirname "$0")/.." && pwd)
test_directory=${AAUV_TEST_DIRECTORY:-"$root/build/local-tests"}
module_cache=${AAUV_TEST_MODULE_CACHE:-$test_directory/module-cache}
mkdir -p "$test_directory" "$module_cache"

# All fixtures use synthetic records and injected model/credential operations.
# Account login, CloudKit writes, device installation and network switching are
# separate acceptance steps and are never triggered by this command.
(
  cd "$root/core"
  GOENV=off GOTOOLCHAIN=local GOWORK=off GOSUMDB=off \
    GOPROXY="${GOPROXY:-off}" GOCACHE="$root/build/go-cache" \
    go test -mod=readonly ./...
) > "$test_directory/go.log" 2>&1 || {
  cat "$test_directory/go.log"
  exit 1
}
cat "$test_directory/go.log"

(
  cd "$root/copilot"
  GOENV=off GOTOOLCHAIN=local GOWORK=off GOSUMDB=off \
    GOPROXY="${GOPROXY:-off}" GOCACHE="$root/build/go-cache" \
    GOMODCACHE="${GOMODCACHE:-$root/build/copilot-module-cache}" \
    go test -mod=readonly ./...
) > "$test_directory/copilot-go.log" 2>&1 || {
  cat "$test_directory/copilot-go.log"
  exit 1
}
cat "$test_directory/copilot-go.log"

if [ "$(uname -s)" != Darwin ]; then
  echo 'Go tests passed; the native integration suite requires macOS and Xcode.' >&2
  exit 2
fi

framework="$root/Vendor/AAUVCore.xcframework/macos-arm64_x86_64"
if [ ! -d "$framework" ]; then
  echo 'Build the Apple core first with Scripts/build-core.sh.' >&2
  exit 2
fi

# These four files require the app entry point or external rendering packages.
# Full UI and rendering compilation is checked by the regular Xcode builds.
python3 - "$root" "$test_directory/sources" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
excluded = {'AAUVApp.swift', 'MarkdownCitations.swift', 'MathRendering.swift', 'MessageMarkdown.swift'}
files = sorted(path for path in (root / 'Sources').rglob('*.swift') if path.name not in excluded)
# Keep the complete adapter implementation, but every test process gets a new
# Keychain service. Even an unexpected error path cannot query production keys.
keychain = root / 'Sources/APIKey.swift'
original = keychain.read_text()
service = '"com.pendingname.aauv.byok"'
assert original.count(service) == 1
assert original.count('import Security\n') == 1
isolated = Path(sys.argv[2]).with_name('APIKey.swift')
header = 'private let aauvSyntheticKeychainService = "com.pendingname.aauv.synthetic-tests." + UUID().uuidString\n'
isolated.write_text(original.replace('import Security\n', 'import Security\n\n' + header)
                   .replace(service, 'aauvSyntheticKeychainService'))
files = [isolated if path == keychain else path for path in files]
Path(sys.argv[2]).write_text(''.join('"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"\n' for path in files))
PY

if [ "$#" -eq 0 ]; then
  set -- ConfigurationRecoveryTests ConfigurationImportTests DefaultBotMetadataTests DefaultBotSelectionTests BotChatGPTBindingTests PortableAppPreferencesTests SyncedPublicPreferencesTests PortableSettingsExportTests \
    RequestCredentialsTests ChatGPTRequestReadTests ChatGPTCatalogRequestTests SyncedChatGPTEnrollmentTests PortableCredentialsTests \
    CopilotCredentialReadTests CopilotLocalSignOutTests TransportCredentialTests CredentialRefreshLeaseTests RefreshImportCoordinationTests \
    KeychainReadTests ChatGPTSignInPersistenceTests LetterPurposeTests UnsentConversationTests RecentBotSubmissionTests AutomaticLetterTests ConversationActivityTests ConversationReplyScopeTests MessageDeletionTests ReplyAttemptRecoveryTests ResponseToolLoopTests \
    LocalCloudToolsTests LocalImageToolsTests LocalModelDelegationTests ConversationLocalToolsTests \
    LocalToolMediaIntegrationTests ImageOnlyFinalTests CopilotLocalToolsTests LocalToolTraceProducerTests RealtimeVoiceTests VoiceRunToolTests \
    ContextWindowTests RuntimePromptTests LocalToolTraceTests LocalToolTraceRuntimeTests PortableDataTests BackupAttachmentIdentityTests ReplicaRecoveryTests CloudSyncConfigurationFenceTests CloudSyncRunIntentTests CloudSyncReconcileLivenessTests CloudSyncForegroundTests CloudZoneCatchUpTests MacForegroundEventsTests PendingBotMigrationTests HostedToolsTests ImageGenerationTests FileUploadTests CopilotIOSIntegrationTests
fi

run_native_test() {
  case "$1" in
    RecentBotSubmissionTests)
      recent_bot_test_root=$(/usr/bin/mktemp -d "$test_directory/recent-bot.XXXXXX")
      AAUV_RECENT_BOT_TEST_ROOT="$recent_bot_test_root" "$test_directory/$1" ;;
    HostedToolsTests) python3 "$root/Tests/hosted-tools-fixture.py" "$test_directory/$1" ;;
    ImageGenerationTests) python3 "$root/Tests/image-generation-fixture.py" "$test_directory/$1" ;;
    FileUploadTests) python3 "$root/Tests/file-upload-fixture.py" "$test_directory/$1" ;;
    ConversationLocalToolsTests) python3 "$root/Tests/conversation-tools-fixture.py" "$test_directory/$1" ;;
    LocalToolMediaIntegrationTests) python3 "$root/Tests/local-tool-media-fixture.py" "$test_directory/$1" ;;
    ImageOnlyFinalTests) python3 "$root/Tests/image-only-final-fixture.py" "$test_directory/$1" ;;
    CopilotLocalToolsTests) python3 "$root/Tests/copilot-local-tools-fixture.py" "$test_directory/$1" ;;
    CopilotIOSIntegrationTests) python3 "$root/Tests/copilot-ios-integration-fixture.py" "$test_directory/$1" ;;
    RealtimeVoiceTests) python3 "$root/Tests/realtime-voice-fixture.py" "$test_directory/$1" ;;
    *) "$test_directory/$1" ;;
  esac
}

for test_case do
  case "$test_case" in
    ''|*[!A-Za-z0-9]*) echo 'Use a Swift test name without its path or extension.' >&2; exit 2 ;;
  esac
  if [ ! -f "$root/Tests/$test_case.swift" ]; then
    echo "Unknown test: $test_case" >&2
    exit 2
  fi
  conditional_flags="$test_directory/$test_case-flags"
  if [ "$test_case" = CopilotIOSIntegrationTests ]; then
    printf '%s\n' '-D' 'AAUV_COPILOT_IOS_FIXTURES' > "$conditional_flags"
  elif [ "$test_case" = ChatGPTSignInPersistenceTests ]; then
    printf '%s\n' '-O' '-whole-module-optimization' > "$conditional_flags"
  else
    : > "$conditional_flags"
  fi
  if ! xcrun swiftc -target "$(uname -m)-apple-macosx14.0" \
      -module-cache-path "$module_cache" -Xfrontend -disable-sandbox \
      -F "$framework" -framework AAUVCore -lsqlite3 \
      @"$conditional_flags" @"$test_directory/sources" "$root/Tests/$test_case.swift" \
      -o "$test_directory/$test_case" > "$test_directory/$test_case-build.log" 2>&1; then
    cat "$test_directory/$test_case-build.log"
    exit 1
  fi
  if ! run_native_test "$test_case" > "$test_directory/$test_case.log" 2>&1; then
    cat "$test_directory/$test_case.log"
    exit 1
  fi
  cat "$test_directory/$test_case.log"
done
PYTHONDONTWRITEBYTECODE=1 python3 "$root/Tests/pendingbot-migration-tests.py"
