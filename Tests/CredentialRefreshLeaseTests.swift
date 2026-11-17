import Foundation

private enum LeaseFixtureError: Error { case pendingImport }

private final class LeaseCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failure: Bool
    private let block: Bool
    let started: AsyncStream<Void>
    private let notify: AsyncStream<Void>.Continuation
    let release = DispatchSemaphore(value: 0)

    init(fail: Bool = false, block: Bool = false) {
        failure = fail
        self.block = block
        let pair = AsyncStream<Void>.makeStream()
        started = pair.stream
        notify = pair.continuation
    }

    func check() throws {
        precondition(!Thread.isMainThread)
        lock.lock()
        calls += 1
        lock.unlock()
        if block {
            notify.yield(())
            precondition(release.wait(timeout: .now() + 8) == .success,
                         "A lease check blocked the main actor.")
        }
        if failure { throw LeaseFixtureError.pendingImport }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@main
struct CredentialRefreshLeaseTests {
    @MainActor static func main() async throws {
        precondition(CredentialRefreshLease.defaultStoreFile ==
                     URL.applicationSupportDirectory.appending(path: "AAUV/conversations.json"))
        let directory = try PrivateTemporaryDirectory()
        let store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
        let settings = PortableSettings(endpoint: "https://example.invalid/v1", model: "synthetic-only")

        func recover(_ check: LeaseCheck) async {
            await store.resumeConfigurationImport(read: {
                try check.check()
                return nil
            }, publish: { _ in preconditionFailure("No fixture journal exists.") },
               writePreferences: { _ in preconditionFailure("No fixture journal exists.") },
               clear: { preconditionFailure("No fixture journal exists.") }).value
        }

        func requireExclusiveBlocked() async throws {
            let read = LeaseCheck()
            await recover(read)
            precondition(read.count == 0 && store.configurationUnavailable,
                         "Recovery read the journal before obtaining its exclusive lock.")
            var updatedStore = false
            do {
                try store.commitConfiguration(settings) { _ in updatedStore = true }
                preconditionFailure("Import staged a journal while a refresh lease was held.")
            } catch let error as ChatClient.ClientError {
                precondition(error.localizedDescription.contains("应用配置或授权正在保存"))
            }
            precondition(!updatedStore)
        }

        func requireExclusiveAvailable() async {
            let read = LeaseCheck()
            await recover(read)
            precondition(read.count == 1 && !store.configurationUnavailable)
        }

        // Separate descriptors allow both providers to refresh concurrently.
        let firstCheck = LeaseCheck()
        let first = try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try firstCheck.check() })
        let secondCheck = LeaseCheck()
        let second = try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try secondCheck.check() })
        precondition(firstCheck.count == 1 && secondCheck.count == 1)
        try await requireExclusiveBlocked()
        first.release()
        first.release()
        try await requireExclusiveBlocked()
        second.release()
        await requireExclusiveAvailable()

        // A durable journal blocks refresh before any provider operation, even
        // when no recovery currently holds the exclusive lock.
        let pending = LeaseCheck(fail: true)
        do {
            _ = try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try pending.check() })
            preconditionFailure("A refresh accepted a pending configuration import.")
        } catch LeaseFixtureError.pendingImport {}
        precondition(pending.count == 1)
        await requireExclusiveAvailable()

        // While recovery is suspended off-main, shared acquisition fails before
        // dispatching a keychain check. It must not queue behind its own blocker.
        let heldRecovery = LeaseCheck(block: true)
        let recovering = Task { await recover(heldRecovery) }
        for await _ in heldRecovery.started.prefix(1) {}
        let forbidden = LeaseCheck()
        do {
            _ = try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try forbidden.check() })
            preconditionFailure("Refresh entered an active configuration recovery.")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("配置导入正在进行"))
        }
        precondition(forbidden.count == 0)
        heldRecovery.release.signal()
        await recovering.value
        await requireExclusiveAvailable()

        // Cancellation before or during the background check releases every fd.
        let cancelledCheck = LeaseCheck()
        let before = Task { try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try cancelledCheck.check() }) }
        before.cancel()
        do { _ = try await before.value; preconditionFailure("Cancelled acquisition succeeded.") }
        catch is CancellationError {}
        precondition(cancelledCheck.count == 0)
        await requireExclusiveAvailable()

        let checking = LeaseCheck(block: true)
        let during = Task { try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try checking.check() }) }
        for await _ in checking.started.prefix(1) {}
        during.cancel()
        checking.release.signal()
        do { _ = try await during.value; preconditionFailure("Cancelled acquisition retained its lease.") }
        catch is CancellationError {}
        await requireExclusiveAvailable()

        // Cancelling a caller does not cancel an already shared renewal. Its
        // explicit defer keeps imports out until the synthetic save completes.
        let acquired = AsyncStream<Void>.makeStream()
        let provider = AsyncStream<Void>.makeStream()
        var saved = false
        let syntheticCheck = LeaseCheck()
        let renewal = Task {
            let lease = try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try syntheticCheck.check() })
            defer { lease.release() }
            acquired.continuation.yield(())
            for await _ in provider.stream.prefix(1) {}
            MainActor.preconditionIsolated()
            precondition(!Task.isCancelled)
            saved = true
        }
        let caller = Task {
            try await renewal.value
            try Task.checkCancellation()
        }
        for await _ in acquired.stream.prefix(1) {}
        caller.cancel()
        try await requireExclusiveBlocked()
        precondition(!saved)
        provider.continuation.yield(())
        do { try await caller.value; preconditionFailure("Cancelled caller returned success.") }
        catch is CancellationError {}
        precondition(saved)
        await requireExclusiveAvailable()
        print("Refresh shared leases excluded imports through save, respected pending journals and recovery, allowed concurrent providers, and released after cancellation or failure.")
    }
}
