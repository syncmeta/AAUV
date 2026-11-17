import CloudKit
import Foundation

private enum FenceFailure: Error, Sendable { case read, preferences, check(String) }

@main
struct CloudSyncConfigurationFenceTests {
    @MainActor private struct Fixture {
        let directory: PrivateTemporaryDirectory
        let defaults: UserDefaults
        let suite: String
        let store: ConversationStore
        let pending: ConfigurationImport
        let originalOutbox: Data

        init(oldEnabled: Bool = true, finalEnabled: Bool = false) throws {
            directory = try PrivateTemporaryDirectory()
            suite = "com.pendingname.aauv.fixture.cloud-fence." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { throw FenceFailure.check("fixture_defaults") }
            self.defaults = defaults
            defaults.set(oldEnabled, forKey: "cloudSyncEnabled")
            let settings = try PortableSettings(endpoint: "https://example.invalid/v1", model: "fixture",
                                                cloudSyncEnabled: finalEnabled).validated()
            pending = try ConfigurationImport(settings: settings, vault: settings, previous: nil,
                                              incoming: settings.loginCredentials())
            store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
            var conversation = Conversation()
            conversation.messages = [ChatMessage(role: .user, content: "synthetic committed import")]
            try store.importCopies([conversation], configurationImportID: pending.id)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            originalOutbox = try encoder.encode(store.pendingReplica())
            guard !originalOutbox.isEmpty, try store.pendingReplicaCount() > 0,
                  try store.configurationImportCommitted(pending.id) else { throw FenceFailure.check("fixture_committed_outbox") }
        }

        func expectPreserved() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try expect(try encoder.encode(store.pendingReplica()) == originalOutbox, "committed_outbox_changed")
            try expect(store.conversations.count == 1 && store.conversations[0].messages.count == 1, "committed_data_changed")
        }

        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor static func main() async {
        do {
            try await failedReadBlocksOldEnabled()
            try await pendingPublicationBlocksOldEnabled()
            try await failedPreferencesBlockOldEnabled()
            try await successfulRecoveryUsesFinalPreference(false)
            try await successfulRecoveryUsesFinalPreference(true)
            try await accessChangeDuringStartupDoesNotScheduleRetry()
            try await recoveryFailureStopsScheduledRetry()
            print("Cloud configuration fence passed 7 scenarios: committed pending false/old true, blocked read/publication, failed preferences, final false/true, late startup and queued retry. Cloud container constructions=0; injected open attempts only.")
        } catch {
            print("Cloud configuration fence FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor private static func expect(_ value: Bool, _ name: String) throws {
        if !value { throw FenceFailure.check(name) }
    }

    @MainActor private static func failedReadBlocksOldEnabled() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        await fixture.store.resumeConfigurationImport(read: { throw FenceFailure.read }, publish: { _ in },
                                                       writePreferences: { _ in }, clear: {}).value
        try expect(fixture.store.configurationUnavailable && fixture.defaults.bool(forKey: "cloudSyncEnabled"), "read_failure_fixture")
        var opened = 0
        let sync = CloudSync(store: fixture.store, defaults: fixture.defaults,
                             openContainer: { opened += 1; throw CKError(.badContainer) })
        await sync.syncNow()
        try expect(opened == 0, "failed_recovery_opened_cloud_\(opened)_expected_0")
        try expect(!sync.busy && !sync.waitingToRetry, "failed_recovery_left_work")
        try fixture.expectPreserved()
    }

    @MainActor private static func pendingPublicationBlocksOldEnabled() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pending = fixture.pending
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let recovery = fixture.store.resumeConfigurationImport(read: { pending }, publish: { _ in
            started.continuation.yield(())
            guard release.wait(timeout: .now() + 5) == .success else { throw FenceFailure.check("publication_fixture_timeout") }
        }, writePreferences: { try $0.persistAppPreferences(defaults: fixture.defaults) }, clear: {})
        for await _ in started.stream.prefix(1) {}
        var opened = 0
        let sync = CloudSync(store: fixture.store, defaults: fixture.defaults,
                             openContainer: { opened += 1; throw CKError(.badContainer) })
        await sync.syncNow()
        try expect(fixture.store.configurationRecovering && opened == 0, "pending_publication_opened_cloud")
        release.signal(); await recovery.value
        await sync.syncNow()
        try expect(!fixture.store.configurationUnavailable && !fixture.defaults.bool(forKey: "cloudSyncEnabled") && opened == 0,
                   "final_false_reopened_cloud")
        try fixture.expectPreserved()
    }

    @MainActor private static func failedPreferencesBlockOldEnabled() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let pending = fixture.pending
        await fixture.store.resumeConfigurationImport(read: { pending }, publish: { _ in },
                                                       writePreferences: { _ in throw FenceFailure.preferences }, clear: {}).value
        var opened = 0
        let sync = CloudSync(store: fixture.store, defaults: fixture.defaults,
                             openContainer: { opened += 1; throw CKError(.badContainer) })
        await sync.syncNow(); await sync.accountStatusDidChange(); await sync.restoreFromLocal()
        try expect(fixture.store.configurationUnavailable && fixture.defaults.bool(forKey: "cloudSyncEnabled") && opened == 0,
                   "failed_preferences_opened_cloud")
        try fixture.expectPreserved()
    }

    @MainActor private static func successfulRecoveryUsesFinalPreference(_ enabled: Bool) async throws {
        let fixture = try Fixture(oldEnabled: !enabled, finalEnabled: enabled); defer { fixture.cleanup() }
        let pending = fixture.pending
        await fixture.store.resumeConfigurationImport(read: { pending }, publish: { _ in },
                                                       writePreferences: { try $0.persistAppPreferences(defaults: fixture.defaults) }, clear: {}).value
        var opened = 0
        let sync = CloudSync(store: fixture.store, defaults: fixture.defaults,
                             openContainer: { opened += 1; throw CKError(.badContainer) })
        await sync.syncNow()
        try expect(!fixture.store.configurationUnavailable && fixture.defaults.bool(forKey: "cloudSyncEnabled") == enabled,
                   "final_preference_not_published")
        try expect(opened == (enabled ? 1 : 0), "did_not_use_final_cloud_preference")
        try fixture.expectPreserved()
    }

    @MainActor private static func accessChangeDuringStartupDoesNotScheduleRetry() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var opened = 0
        var continuation: CheckedContinuation<Void, Never>?
        let sync = CloudSync(store: fixture.store, defaults: fixture.defaults, openContainer: {
            opened += 1
            await withCheckedContinuation { continuation = $0 }
            throw CKError(.networkUnavailable)
        })
        let startup = Task { await sync.syncNow() }
        try await until { continuation != nil }
        await fixture.store.resumeConfigurationImport(read: { throw FenceFailure.read }, publish: { _ in },
                                                       writePreferences: { _ in }, clear: {}).value
        continuation?.resume(); await startup.value
        try expect(opened == 1 && !sync.waitingToRetry && !sync.busy, "late_startup_scheduled_while_configuration_failed")
        try fixture.expectPreserved()
    }

    @MainActor private static func recoveryFailureStopsScheduledRetry() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var opened = 0
        var retry: CheckedContinuation<Void, Never>?
        let sync = CloudSync(store: fixture.store, defaults: fixture.defaults,
                             openContainer: { opened += 1; throw CKError(.networkUnavailable) },
                             sleepBeforeRetry: { _ in await withCheckedContinuation { retry = $0 } })
        await sync.syncNow(); try await until { retry != nil }
        await fixture.store.resumeConfigurationImport(read: { throw FenceFailure.read }, publish: { _ in },
                                                       writePreferences: { _ in }, clear: {}).value
        retry?.resume()
        try await until { !sync.waitingToRetry }
        try expect(opened == 1 && !sync.busy, "retry_reopened_while_configuration_failed")
        try fixture.expectPreserved()
    }

    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FenceFailure.check("fixture_timeout")
    }
}
