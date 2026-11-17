import Foundation

private final class CopilotReadFixture: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    let credentials: OAuthCredentials

    init(_ credentials: OAuthCredentials) {
        self.credentials = credentials
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func read() -> OAuthCredentials? {
        precondition(!Thread.isMainThread)
        started.yield(())
        precondition(release.wait(timeout: .now() + 5) == .success,
                     "Copilot credential lookup blocked the main actor.")
        return credentials
    }
}

@main
struct CopilotCredentialReadTests {
    @MainActor static func main() async throws {
        let suite = "com.pendingname.aauv.copilot-read-fixture.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try PrivateTemporaryDirectory()
        let leaseFile = directory.url.appending(path: "fixture.json")
        let acquireLease: @MainActor () async throws -> CredentialRefreshLease = {
            try await CredentialRefreshLease.acquire(file: leaseFile, checkPending: {})
        }
        let credentials = OAuthCredentials(flow: .githubCopilot, accessToken: "gho_synthetic-only")
        for action in ["finish", "cancel", "credentials", "route"] {
            defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
            let session = CopilotSession(defaults: defaults)
            let fixture = CopilotReadFixture(credentials)
            var routeIsCurrent = true
            let task = Task {
                try await session.token(proxy: nil, validateRoute: {
                    guard routeIsCurrent else { throw URLError(.networkConnectionLost) }
                }, read: { fixture.read() })
            }
            for await _ in fixture.events.prefix(1) {}
            switch action {
            case "cancel": task.cancel()
            case "credentials": defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
            case "route": routeIsCurrent = false
            default: break
            }
            fixture.release.signal()
            do {
                let token = try await task.value
                precondition(action == "finish" && token == credentials.accessToken)
            } catch {
                precondition(action != "finish")
                if action == "cancel" { precondition(error is CancellationError) }
            }
        }

        // Cancelling one waiter must not cancel a renewal shared by another.
        defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
        let session = CopilotSession(defaults: defaults)
        let expired = OAuthCredentials(flow: .githubCopilot, accessToken: "gho_expired-synthetic",
                                       refreshToken: "synthetic-refresh", expiresAt: 1)
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        var readCount = 0
        var renewCount = 0
        var saveCount = 0
        let reader: @Sendable () throws -> OAuthCredentials? = { expired }
        let renew: @MainActor (OAuthCredentials) async throws -> OAuthCredentials = { old in
            renewCount += 1
            started.continuation.yield(())
            for await _ in gate.stream { break }
            var updated = old
            updated.accessToken = "gho_renewed-synthetic"
            updated.expiresAt = Date().timeIntervalSince1970 + 3600
            return updated
        }
        let replace: @MainActor (OAuthCredentials, OAuthCredentials) throws -> Void = { old, updated in
            precondition(old.accessToken == expired.accessToken && updated.accessToken == "gho_renewed-synthetic")
            saveCount += 1
        }
        let first = Task { try await session.token(proxy: nil, read: reader, renew: renew,
                                                 acquireRenewalLease: acquireLease, replace: replace) }
        for await _ in started.stream.prefix(1) {}
        let secondRead = AsyncStream<Void>.makeStream()
        let second = Task {
            try await session.token(proxy: nil, validateRoute: {
                readCount += 1
                if readCount == 2 { secondRead.continuation.yield(()) }
            }, read: reader, renew: renew, acquireRenewalLease: acquireLease, replace: replace)
        }
        for await _ in secondRead.stream.prefix(1) {}
        first.cancel()
        gate.continuation.yield(())
        do { _ = try await first.value; preconditionFailure("Cancelled renewal waiter returned a token.") }
        catch is CancellationError {}
        let updated = try await second.value
        precondition(updated == "gho_renewed-synthetic" && renewCount == 1 && saveCount == 1)

        // A renewal completed after a different login must not overwrite it.
        defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
        let staleSession = CopilotSession(defaults: defaults)
        let staleGate = AsyncStream<Void>.makeStream()
        let staleStarted = AsyncStream<Void>.makeStream()
        let stale = Task {
            try await staleSession.token(proxy: nil, read: reader, renew: { previous in
                staleStarted.continuation.yield(())
                for await _ in staleGate.stream { break }
                return previous
            }, acquireRenewalLease: acquireLease,
               replace: { _, _ in preconditionFailure("A stale renewal overwrote the new login.") })
        }
        for await _ in staleStarted.stream.prefix(1) {}
        defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
        staleGate.continuation.yield(())
        do { _ = try await stale.value; preconditionFailure("A replaced Copilot authorization returned a token.") }
        catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("授权已更换"))
        }
        print("Copilot credential reads stayed responsive, rejected stale results and preserved shared renewal after waiter cancellation.")
    }
}
