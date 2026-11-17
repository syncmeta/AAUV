import AppKit
import CloudKit
import Foundation

private enum MacForegroundFailure: Error, Sendable { case check(String) }

@main
struct MacForegroundEventsTests {
    @MainActor private final class Clock {
        var now = ContinuousClock.now
        func advance(_ duration: Duration) { now = now.advanced(by: duration) }
    }

    @MainActor private final class OpenProbe {
        var count = 0
        var retries = 0
    }

    @MainActor private final class Fixture {
        let directory: PrivateTemporaryDirectory
        let suite: String
        let defaults: UserDefaults
        let store: ConversationStore
        let delegate = MacOpenEvents()
        let clock = Clock()
        let probe = OpenProbe()
        let originalOutbox: Data
        let originalConversations: Data
        var sync: CloudSync?

        init(enabled: Bool) throws {
            directory = try PrivateTemporaryDirectory()
            suite = "com.pendingname.aauv.fixture.mac-foreground." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite),
                  defaults.persistentDomain(forName: suite) == nil else {
                throw MacForegroundFailure.check("fresh_private_defaults")
            }
            self.defaults = defaults
            defaults.set(enabled, forKey: "cloudSyncEnabled")
            store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
            var conversation = Conversation()
            conversation.title = "Synthetic Mac activation outbox"
            conversation.messages = [ChatMessage(role: .user, content: "Keep the committed local message.")]
            try store.insert(conversation)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            originalOutbox = try encoder.encode(store.pendingReplica())
            originalConversations = try encoder.encode(store.conversations)
            guard store.loadError == nil, try store.pendingReplicaCount() > 0 else {
                throw MacForegroundFailure.check("committed_private_outbox")
            }

            // Capture only the independent clock/probe, never this fixture.
            let clock = self.clock
            let probe = self.probe
            let value = CloudSync(store: store, defaults: defaults, openContainer: {
                probe.count += 1
                // Exercise the original source gate without constructing an engine.
                throw CKError(.badContainer)
            }, sleepBeforeRetry: { _ in
                probe.retries += 1
                throw MacForegroundFailure.check("unexpected_retry")
            }, foregroundNow: { clock.now })
            sync = value
            delegate.bindForegroundSync(value)
        }

        func becomeActive() {
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        }

        func resignActive() {
            delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        }

        func returnToApp() {
            resignActive()
            becomeActive()
        }

        func waitForOpenCount(_ count: Int) async throws {
            try await until {
                probe.count >= count && sync.map { !$0.busy && !$0.waitingToRetry } == true
            }
            await settle()
            try expect(probe.count == count, "unexpected_open_count_\(probe.count)_expected_\(count)")
        }

        func expectPreserved() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try expect(try encoder.encode(store.pendingReplica()) == originalOutbox, "committed_outbox_changed")
            try expect(try encoder.encode(store.conversations) == originalConversations, "committed_messages_changed")
            try expect(probe.retries == 0, "activation_scheduled_retry")
        }

        func shutdown() async {
            defaults.set(false, forKey: "cloudSyncEnabled")
            await sync?.stop()
            await settle()
            sync = nil
        }
    }

    @MainActor static func main() async {
        do {
            try await initialAndDuplicateBecomeDoNotOpen()
            try await repeatedResignProducesOneReturn()
            try await returnUsesOriginalFiveSecondGate()
            try await disabledReturnDoesNotOpen()
            try await delegateDoesNotRetainSyncAfterActivationTask()
            print("Mac foreground delegate passed initial/duplicate activation, resign pairing, original5s coalescing, disabled source and weak lifetime; committed private outboxes preserved; NSApplication/Cloud container/engine constructions0.")
        } catch {
            print("Mac foreground delegate FAIL: \(error)")
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
        do { try fixture.expectPreserved() }
        catch { if failure == nil { failure = error } }
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
        if let failure { throw failure }
    }

    @MainActor private static func initialAndDuplicateBecomeDoNotOpen() async throws {
        try await withFixture { fixture in
            fixture.becomeActive()
            fixture.becomeActive()
            await settle()
            try expect(fixture.probe.count == 0, "initial_activation_opened")
            fixture.returnToApp()
            try await fixture.waitForOpenCount(1)
            fixture.clock.advance(.seconds(60))
            // Passing the source coalescing boundary cannot turn a duplicate
            // become notification into a genuine return from the background.
            fixture.becomeActive()
            fixture.becomeActive()
            await settle()
            try expect(fixture.probe.count == 1, "duplicate_become_opened")
        }
    }

    @MainActor private static func repeatedResignProducesOneReturn() async throws {
        try await withFixture { fixture in
            fixture.resignActive()
            fixture.resignActive()
            fixture.becomeActive()
            try await fixture.waitForOpenCount(1)
            fixture.clock.advance(.seconds(60))
            fixture.becomeActive()
            await settle()
            try expect(fixture.probe.count == 1, "second_resign_left_extra_activation")
            fixture.returnToApp()
            try await fixture.waitForOpenCount(2)
        }
    }

    @MainActor private static func returnUsesOriginalFiveSecondGate() async throws {
        try await withFixture { fixture in
            fixture.returnToApp()
            try await fixture.waitForOpenCount(1)
            fixture.clock.advance(.milliseconds(4999))
            fixture.returnToApp()
            await settle()
            try expect(fixture.probe.count == 1, "short_return_bypassed_source_coalescing")
            fixture.clock.advance(.milliseconds(1))
            fixture.returnToApp()
            try await fixture.waitForOpenCount(2)
        }
    }

    @MainActor private static func disabledReturnDoesNotOpen() async throws {
        try await withFixture(enabled: false) { fixture in
            fixture.returnToApp()
            fixture.clock.advance(.seconds(60))
            fixture.returnToApp()
            await settle()
            try expect(fixture.probe.count == 0, "disabled_return_opened")
            fixture.defaults.set(true, forKey: "cloudSyncEnabled")
            fixture.becomeActive()
            await settle()
            try expect(fixture.probe.count == 0, "disabled_return_was_not_consumed")
            fixture.returnToApp()
            try await fixture.waitForOpenCount(1)
        }
    }

    @MainActor private static func delegateDoesNotRetainSyncAfterActivationTask() async throws {
        try await withFixture { fixture in
            fixture.returnToApp()
            try await fixture.waitForOpenCount(1)
            weak var released = fixture.sync
            await fixture.sync?.stop()
            fixture.sync = nil
            try await until { released == nil }
            fixture.clock.advance(.seconds(60))
            fixture.returnToApp()
            await settle()
            try expect(fixture.probe.count == 1, "delegate_revived_released_source")
        }
    }

    @MainActor private static func expect(_ value: Bool, _ name: String) throws {
        if !value { throw MacForegroundFailure.check(name) }
    }

    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MacForegroundFailure.check("delegate_task_timeout")
    }

    @MainActor private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
