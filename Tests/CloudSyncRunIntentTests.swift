import CloudKit
import Foundation

private enum RunIntentFailure: Error, Sendable { case read, check(String) }

@main
struct CloudSyncRunIntentTests {
    @MainActor static func main() async {
        do {
            let directory = try PrivateTemporaryDirectory()
            let suite = "com.pendingname.aauv.fixture.cloud-intent." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { throw RunIntentFailure.check("defaults") }
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "cloudSyncEnabled")
            let store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
            var opened = 0
            let sync = CloudSync(store: store, defaults: defaults,
                                 openContainer: { opened += 1; throw CKError(.badContainer) })
            let enabledIntent = sync.runIntent
            try expect(enabledIntent.allowed, "initial_intent")
            await sync.reconcileRunIntent()
            try expect(opened == 1, "available_reconcile_did_not_start")

            let started = AsyncStream<Void>.makeStream()
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let recovery = store.resumeConfigurationImport(read: {
                started.continuation.yield(())
                guard release.wait(timeout: .now() + 5) == .success else { throw RunIntentFailure.check("timeout") }
                throw RunIntentFailure.read
            }, publish: { _ in }, writePreferences: { _ in }, clear: {})
            for await _ in started.stream.prefix(1) {}
            let blockedIntent = sync.runIntent
            try expect(blockedIntent != enabledIntent && !blockedIntent.allowed, "recovery_not_in_task_identity")
            await sync.reconcileRunIntent()
            try expect(opened == 1 && !sync.busy && !sync.waitingToRetry, "pending_reconcile_started")
            release.signal(); await recovery.value
            try expect(store.configurationUnavailable && sync.runIntent == blockedIntent, "failed_recovery_unblocked_intent")
            await sync.reconcileRunIntent()
            try expect(opened == 1, "failed_reconcile_started")

            await store.resumeConfigurationImport(read: { nil }, publish: { _ in },
                                                  writePreferences: { _ in }, clear: {}).value
            try expect(sync.runIntent == enabledIntent, "successful_recovery_did_not_restore_task_identity")
            await sync.reconcileRunIntent()
            try expect(opened == 2, "successful_reconcile_did_not_restart")
            defaults.set(false, forKey: "cloudSyncEnabled")
            try expect(!sync.runIntent.allowed && sync.runIntent != enabledIntent, "disabled_intent")
            await sync.reconcileRunIntent()
            try expect(opened == 2, "disabled_reconcile_started")

            defaults.set(true, forKey: "cloudSyncEnabled")
            var delayedOpened = 0
            var continuation: CheckedContinuation<Void, Never>?
            let delayed = CloudSync(store: store, defaults: defaults, openContainer: {
                delayedOpened += 1
                if delayedOpened == 1 {
                    await withCheckedContinuation { continuation = $0 }
                    throw CKError(.networkUnavailable)
                }
                throw CKError(.badContainer)
            })
            let original = Task { await delayed.reconcileRunIntent() }
            for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
            try expect(continuation != nil, "delayed_start_not_entered")
            defaults.set(false, forKey: "cloudSyncEnabled")
            await delayed.reconcileRunIntent()
            continuation?.resume(); await original.value
            try expect(!delayed.busy && !delayed.waitingToRetry && delayedOpened == 1, "closed_startup_revived")
            defaults.set(true, forKey: "cloudSyncEnabled")
            await delayed.reconcileRunIntent()
            try expect(delayedOpened == 2 && !delayed.waitingToRetry, "fresh_enable_not_started")
            print("Cloud RunIntent/reconcile passed pending/failed/recovered/disabled transitions and closed-await/fresh-enable restart; real cloud constructions=0.")
        } catch {
            print("Cloud RunIntent FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor private static func expect(_ condition: Bool, _ name: String) throws {
        if !condition { throw RunIntentFailure.check(name) }
    }
}
