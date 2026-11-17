import CloudKit
import Foundation

private enum LivenessFailure: Error { case check(String) }

@main
struct CloudSyncReconcileLivenessTests {
    @MainActor static func main() async {
        do {
            try await cancelledReconcileHandsOff(finalEnabled: true)
            try await cancelledReconcileHandsOff(finalEnabled: false)
            print("Cloud reconcile liveness passed skipped-blocked-task/final-true handoff and final-false rejection; fresh startup exactly once, maximum concurrent startup1, real cloud constructions0.")
        } catch {
            print("Cloud reconcile liveness FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor private static func cancelledReconcileHandsOff(finalEnabled: Bool) async throws {
        let directory = try PrivateTemporaryDirectory()
        let suite = "com.pendingname.aauv.fixture.cloud-liveness." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw LivenessFailure.check("defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "cloudSyncEnabled")
        let store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
        var opened = 0
        var activeOpens = 0
        var maximumActiveOpens = 0
        var first: CheckedContinuation<Void, Never>?
        let sync = CloudSync(store: store, defaults: defaults, openContainer: {
            opened += 1; activeOpens += 1
            maximumActiveOpens = max(maximumActiveOpens, activeOpens)
            defer { activeOpens -= 1 }
            if opened == 1 { await withCheckedContinuation { first = $0 } }
            // Never construct a container or schedule an ordinary error retry.
            throw CKError(.badContainer)
        })
        let old = Task { await sync.reconcileRunIntent() }
        try await until { first != nil }
        old.cancel() // SwiftUI cancels the old task on the intermediate intent.
        let recovery = store.resumeConfigurationImport(read: { nil }, publish: { _ in },
                                                       writePreferences: { _ in }, clear: {})
        try expect(store.configurationUnavailable, "recovery_not_blocked")
        // Its blocked SwiftUI task is superseded before it gets to execute stop.
        await recovery.value
        try expect(sync.runIntent.allowed, "recovery_not_successfully_allowed")
        await sync.reconcileRunIntent() // The final task sees the old busy call.
        defaults.set(finalEnabled, forKey: "cloudSyncEnabled")
        first?.resume(); await old.value
        if finalEnabled {
            try await until { opened >= 2 }
        } else {
            for _ in 0..<10 { await Task.yield() }
        }
        try expect(opened == (finalEnabled ? 2 : 1), "fresh_start_count_\(opened)_final_\(finalEnabled)")
        try expect(maximumActiveOpens == 1 && activeOpens == 0, "overlapping_startups")
        try expect(!sync.busy && !sync.waitingToRetry, "left_busy_or_retry")
    }

    @MainActor private static func expect(_ value: Bool, _ name: String) throws {
        if !value { throw LivenessFailure.check(name) }
    }

    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LivenessFailure.check("final_allowed_but_no_fresh_start")
    }
}
