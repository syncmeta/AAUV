import Foundation

private enum RecoveryStage: String, Error, Sendable { case read, publish, preferences, clear }

private final class RecoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var journal: ConfigurationImport?
    private var calls: [RecoveryStage] = []
    private var failure: RecoveryStage?
    private let blocked: RecoveryStage?
    private var didBlock = false
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation

    init(_ journal: ConfigurationImport?, fail: RecoveryStage? = nil, block: RecoveryStage? = nil) {
        self.journal = journal
        failure = fail
        blocked = block
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func read() throws -> ConfigurationImport? {
        precondition(!Thread.isMainThread)
        try step(.read)
        lock.lock()
        defer { lock.unlock() }
        return journal
    }

    func publish(_ settings: PortableSettings) throws {
        precondition(!Thread.isMainThread && settings.credentials?.byokKeys?.values.first == "synthetic-only")
        try step(.publish)
    }

    func clear() throws {
        precondition(!Thread.isMainThread)
        try step(.clear)
        lock.lock()
        journal = nil
        lock.unlock()
    }

    func step(_ stage: RecoveryStage) throws {
        lock.lock()
        calls.append(stage)
        let shouldFail = failure == stage
        if shouldFail { failure = nil }
        let shouldBlock = blocked == stage && !didBlock
        if shouldBlock { didBlock = true }
        lock.unlock()
        if shouldBlock {
            started.yield(())
            precondition(release.wait(timeout: .now() + 5) == .success,
                         "Configuration recovery blocked the main actor.")
        }
        if shouldFail { throw stage }
    }

    var history: [RecoveryStage] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@main
struct ConfigurationRecoveryTests {
    @MainActor static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        let settings = try PortableSettings(endpoint: "https://example.invalid/v1", model: "fixture",
                                            key: "synthetic-only").validated()
        let pending = try ConfigurationImport(settings: settings,
                                              vault: APIKey.configurationToStore(settings, previous: nil),
                                              previous: nil, incoming: settings.loginCredentials())
        func store(committed: Bool = true) throws -> ConversationStore {
            let store = ConversationStore(file: directory.url.appending(path: UUID().uuidString).appending(path: "conversations.json"))
            if committed { try store.saveBots([], configurationImportID: pending.id) }
            return store
        }
        func resume(_ store: ConversationStore, _ fixture: RecoveryFixture) -> Task<Void, Never> {
            store.resumeConfigurationImport(read: { try fixture.read() }, publish: { try fixture.publish($0) },
                                            writePreferences: { _ in
                                                MainActor.preconditionIsolated()
                                                try fixture.step(.preferences)
                                            }, clear: { try fixture.clear() })
        }

        let waiting = try store()
        let gated = RecoveryFixture(pending, block: .read)
        let recovery = resume(waiting, gated)
        precondition(waiting.configurationRecovering && waiting.configurationUnavailable)
        for await _ in gated.events.prefix(1) {}
        let duplicate = resume(waiting, gated)
        // Another window must fail before it can read or replace the journal.
        let other = ConversationStore(file: waiting.file)
        let forbidden = RecoveryFixture(nil)
        await resume(other, forbidden).value
        precondition(forbidden.history.isEmpty && other.configurationRecoveryError != nil)
        gated.release.signal()
        await recovery.value
        await duplicate.value
        precondition(gated.history == [.read, .publish, .preferences, .clear])
        precondition(!waiting.configurationUnavailable && !waiting.configurationRecovering)

        for stage in [RecoveryStage.read, .publish, .preferences, .clear] {
            let interrupted = try store()
            let fixture = RecoveryFixture(pending, fail: stage)
            await resume(interrupted, fixture).value
            precondition(interrupted.configurationUnavailable && !interrupted.configurationRecovering)
            await resume(interrupted, fixture).value
            precondition(!interrupted.configurationUnavailable)
            precondition(Array(fixture.history.suffix(4)) == [.read, .publish, .preferences, .clear])
        }

        let uncommitted = try store(committed: false)
        let abandoned = RecoveryFixture(pending)
        await resume(uncommitted, abandoned).value
        precondition(abandoned.history == [.read, .clear] && !uncommitted.configurationUnavailable)
        let empty = RecoveryFixture(nil)
        await resume(uncommitted, empty).value
        precondition(empty.history == [.read] && !uncommitted.configurationUnavailable)

        let cancelled = try store()
        let publishing = RecoveryFixture(pending, block: .publish)
        let cancelledTask = resume(cancelled, publishing)
        for await _ in publishing.events.prefix(1) {}
        cancelledTask.cancel()
        publishing.release.signal()
        await cancelledTask.value
        precondition(publishing.history == [.read, .publish] && cancelled.configurationUnavailable)
        await resume(cancelled, publishing).value
        precondition(!cancelled.configurationUnavailable)
        print("Startup recovery kept the main actor responsive, held the cross-window lock, retried every interruption, and preserved cancelled journals.")
    }
}
