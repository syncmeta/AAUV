import Foundation

// The executable is placed beside the existing synthetic bridge/runtime fixture.
// It never runs the bundled provider runtime or uses a real account/token.
@main @MainActor
struct CopilotLocalSignOutRuntimeTests {
    private enum Rejected: Error { case changed }

    static func main() async throws {
        var checks = 0
        var received = false
        do {
            _ = try await CopilotClient.reply(to: [.init(role: .user, content: "使用默认模型")], model: "",
                                             instructions: "", token: "gho_reply_fixture", proxyURL: nil,
                                             validate: {
                precondition(Thread.isMainThread)
                checks += 1
                if checks == 3 { throw Rejected.changed } // After ready/submit, before first delta.
            }, onDelta: { _ in received = true })
            preconditionFailure("A newly invalidated stream published its event.")
        } catch Rejected.changed {}
        precondition(checks == 3 && !received)

        let suite = "com.pendingname.aauv.tests.copilot-signout-runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: APIKey.copilotSignOutPendingKey)
        defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
        defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
        let directory = try PrivateTemporaryDirectory()
        let session = CopilotSession(defaults: defaults)
        let started = AsyncStream<Void>.makeStream()
        var deltas = 0
        let request = Task {
            try await session.withRequest {
                try await CopilotClient.reply(to: [.init(role: .user, content: "取消回复")], model: "",
                                              instructions: "", token: "gho_reply_fixture", proxyURL: nil,
                                              validate: { try session.validate() }, onDelta: { _ in
                    deltas += 1
                    started.continuation.yield(())
                })
            }
        }
        for await _ in started.stream.prefix(1) {}
        var removed = Set<String>()
        try await CopilotSession.signOut(defaults: defaults, read: {
            precondition(!Thread.isMainThread)
            return try APIKey.copilotSignOutSnapshot(readConfiguration: { nil })
        }, acquireLease: {
            try await CredentialRefreshLease.acquire(file: directory.url.appending(path: "fixture.json"), checkPending: {})
        }, clear: { snapshot in
            try APIKey.clearCopilotSignOut(snapshot, publish: { _ in preconditionFailure("No imported vault existed.") },
                                          remove: { removed.insert($0.absoluteString) })
        })
        do { _ = try await request.value; preconditionFailure("A signed-out runtime request returned a response.") }
        catch is CancellationError {}
        precondition(deltas == 1 && removed.count == 2)
        print("Synthetic Copilot bridge rejected an invalidated delta on MainActor and interrupted an active stream during local sign-out.")
    }
}
