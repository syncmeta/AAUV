import CloudKit
import Foundation

private enum ForegroundFailure: Error, Sendable { case recovery, check(String) }

@main
struct CloudSyncForegroundTests {
    @MainActor private final class Clock {
        var now = ContinuousClock.now
        func advance(_ duration: Duration) { now = now.advanced(by: duration) }
    }

    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false
        var waiting: Bool { continuation != nil }

        func wait() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    @MainActor private final class Fixture {
        let directory: PrivateTemporaryDirectory
        let suite: String
        let defaults: UserDefaults
        let store: ConversationStore
        let clock = Clock()
        let originalOutbox: Data
        let originalConversations: Data
        var sync: CloudSync?
        var tasks: [Task<Void, Never>] = []
        var gates: [Gate] = []

        init(enabled: Bool) throws {
            directory = try PrivateTemporaryDirectory()
            suite = "com.pendingname.aauv.fixture.cloud-foreground." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite),
                  defaults.persistentDomain(forName: suite) == nil else {
                throw ForegroundFailure.check("fresh_private_defaults")
            }
            self.defaults = defaults
            defaults.set(enabled, forKey: "cloudSyncEnabled")
            store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
            var conversation = Conversation()
            conversation.title = "Synthetic foreground outbox"
            conversation.messages = [ChatMessage(role: .user, content: "Keep this local committed message.")]
            try store.insert(conversation)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            originalOutbox = try encoder.encode(store.pendingReplica())
            originalConversations = try encoder.encode(store.conversations)
            guard store.loadError == nil, try store.pendingReplicaCount() > 0 else {
                throw ForegroundFailure.check("committed_private_outbox")
            }
        }

        func makeSync(
            open: @escaping @MainActor () async throws -> CKContainer,
            sleep: @escaping @MainActor (Duration) async throws -> Void = { _ in
                throw ForegroundFailure.check("unexpected_retry")
            }
        ) -> CloudSync {
            let clock = clock
            let value = CloudSync(store: store, defaults: defaults, openContainer: open,
                                  sleepBeforeRetry: sleep, foregroundNow: { clock.now })
            sync = value
            return value
        }

        func gate() -> Gate {
            let value = Gate(); gates.append(value); return value
        }

        func expectPreserved() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try expect(try encoder.encode(store.pendingReplica()) == originalOutbox, "committed_outbox_changed")
            try expect(try encoder.encode(store.conversations) == originalConversations, "committed_messages_changed")
        }

        func shutdown() async {
            // Fence queued source work before releasing a controlled await.
            defaults.set(false, forKey: "cloudSyncEnabled")
            await sync?.stop()
            for task in tasks { task.cancel() }
            for gate in gates { gate.release() }
            for task in tasks { await task.value }
            await settle()
        }
    }

    @MainActor static func main() async {
        do {
            try await disabledActivationDoesNotOpen()
            try await configurationFenceBlocksActivation()
            try await ordinarySyncAndRepeatedActivationsCoalesce()
            try await busyPendingDoesNotRetryFailedStartup()
            try await stopInvalidatesLateStartupAndPending()
            try await foregroundDoesNotBypassStartupRetry()
            print("Cloud foreground passed disabled/configuration fences, exact5s coalescing, failed busy startup, generation stop and scheduled-retry waiting; committed outboxes preserved; real Cloud container/engine constructions0.")
        } catch {
            print("Cloud foreground FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor private static func withFixture(
        enabled: Bool = true, _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture(enabled: enabled)
        var failure: Error?
        do { try await body(fixture); try fixture.expectPreserved() }
        catch { failure = error }
        await fixture.shutdown()
        do {
            try fixture.expectPreserved()
            try expect(fixture.gates.allSatisfy { !$0.waiting }, "unreleased_continuation")
            try expect(fixture.sync.map { !$0.busy && !$0.waitingToRetry } ?? true, "work_left_after_shutdown")
        } catch { if failure == nil { failure = error } }
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
        if let failure { throw failure }
    }

    @MainActor private static func disabledActivationDoesNotOpen() async throws {
        try await withFixture(enabled: false) { fixture in
            var opened = 0
            let sync = fixture.makeSync { opened += 1; throw CKError(.badContainer) }
            await sync.foregroundActivated()
            fixture.clock.advance(.seconds(60))
            await sync.foregroundActivated()
            try expect(opened == 0 && !sync.busy && !sync.waitingToRetry, "disabled_activation_opened")
        }
    }

    @MainActor private static func configurationFenceBlocksActivation() async throws {
        try await withFixture { fixture in
            var opened = 0
            let sync = fixture.makeSync { opened += 1; throw CKError(.badContainer) }
            await fixture.store.resumeConfigurationImport(read: { throw ForegroundFailure.recovery },
                                                          publish: { _ in }, writePreferences: { _ in }, clear: {}).value
            try expect(fixture.store.configurationUnavailable, "configuration_fixture_not_blocked")
            await sync.foregroundActivated()
            fixture.clock.advance(.seconds(60))
            await sync.foregroundActivated()
            try expect(opened == 0, "blocked_configuration_opened")
            await fixture.store.resumeConfigurationImport(read: { nil }, publish: { _ in },
                                                          writePreferences: { _ in }, clear: {}).value
            await sync.foregroundActivated()
            try expect(opened == 1, "recovered_activation_not_allowed")
        }
    }

    @MainActor private static func ordinarySyncAndRepeatedActivationsCoalesce() async throws {
        try await withFixture { fixture in
            var opened = 0
            let sync = fixture.makeSync { opened += 1; throw CKError(.badContainer) }
            await sync.syncNow() // A normal start must also establish the coalescing boundary.
            for _ in 0..<3 { await sync.foregroundActivated() }
            fixture.clock.advance(.milliseconds(4999))
            await sync.foregroundActivated()
            try expect(opened == 1, "activation_ignored_normal_start_or_opened_before5s")
            fixture.clock.advance(.milliseconds(1))
            await sync.foregroundActivated()
            await sync.foregroundActivated()
            try expect(opened == 2, "exact5s_activation_not_coalesced_once")
            fixture.clock.advance(.seconds(5))
            await sync.foregroundActivated()
            try expect(opened == 3, "later_activation_never_started")
            await sync.stop()
            await sync.foregroundActivated() // Stop clears the old start time without advancing this clock.
            try expect(opened == 4, "stop_retained_old_coalescing_time")
        }
    }

    @MainActor private static func busyPendingDoesNotRetryFailedStartup() async throws {
        try await withFixture { fixture in
            let gate = fixture.gate()
            var opened = 0
            var active = 0
            var maximumActive = 0
            let sync = fixture.makeSync {
                opened += 1; active += 1; maximumActive = max(maximumActive, active)
                defer { active -= 1 }
                if opened == 1 { await gate.wait() }
                throw CKError(.badContainer)
            }
            let original = Task { await sync.syncNow() }; fixture.tasks.append(original)
            try await until { gate.entered }
            fixture.clock.advance(.seconds(5))
            for _ in 0..<3 { await sync.foregroundActivated() }
            try expect(opened == 1 && active == 1, "busy_activation_opened_concurrently")
            gate.release(); await original.value
            await settle() // Give an erroneously queued reconcile task a chance to run.
            try expect(opened == 1 && active == 0 && maximumActive == 1, "failed_startup_replayed_pending_activation")
            try expect(!sync.busy && !sync.waitingToRetry, "failed_startup_left_work")
            await sync.foregroundActivated()
            try expect(opened == 2, "fresh_external_activation_after_failure_not_allowed")
        }
    }

    @MainActor private static func stopInvalidatesLateStartupAndPending() async throws {
        try await withFixture { fixture in
            let gate = fixture.gate()
            var opened = 0
            let sync = fixture.makeSync {
                opened += 1
                if opened == 1 { await gate.wait(); throw CKError(.networkUnavailable) }
                throw CKError(.badContainer)
            }
            let original = Task { await sync.syncNow() }; fixture.tasks.append(original)
            try await until { gate.entered }
            fixture.clock.advance(.seconds(5))
            await sync.foregroundActivated()
            await sync.stop()
            gate.release(); await original.value
            await settle()
            try expect(opened == 1 && !sync.busy && !sync.waitingToRetry, "late_stopped_startup_revived_or_retried")
            await sync.foregroundActivated()
            try expect(opened == 2, "stopped_generation_blocked_fresh_activation")
        }
    }

    @MainActor private static func foregroundDoesNotBypassStartupRetry() async throws {
        try await withFixture { fixture in
            let retry = fixture.gate()
            var opened = 0
            var slept = 0
            var sleepReturned = 0
            let sync = fixture.makeSync(open: {
                opened += 1
                throw CKError(.networkUnavailable)
            }, sleep: { _ in
                slept += 1
                await retry.wait()
                sleepReturned += 1
                try Task.checkCancellation()
            })
            await sync.syncNow()
            try await until { retry.entered }
            fixture.clock.advance(.seconds(60))
            for _ in 0..<3 { await sync.foregroundActivated() }
            try expect(opened == 1 && slept == 1 && sync.waitingToRetry, "activation_bypassed_retry_wait")
            await sync.stop()
            retry.release()
            try await until { sleepReturned == 1 }
            await settle()
            try expect(opened == 1 && !sync.busy && !sync.waitingToRetry, "stopped_retry_reopened_after_activation")
        }
    }

    @MainActor private static func expect(_ value: Bool, _ name: String) throws {
        if !value { throw ForegroundFailure.check(name) }
    }

    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ForegroundFailure.check("controlled_await_timeout")
    }

    @MainActor private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
