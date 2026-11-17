import Foundation

private final class PlanReadGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let credentials: OAuthCredentials

    init(_ credentials: OAuthCredentials) {
        self.credentials = credentials
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func read(_ id: String) -> OAuthCredentials? {
        precondition(!Thread.isMainThread)
        started.yield(())
        precondition(release.wait(timeout: .now() + 5) == .success,
                     "A ChatGPT credential read blocked the main actor")
        return id == credentials.clientID ? credentials : nil
    }
}

private final class PlanFixtureVault: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: OAuthCredentials

    init(_ credentials: OAuthCredentials) { self.credentials = credentials }

    func read(_ id: String) -> OAuthCredentials? {
        precondition(!Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        return id == credentials.clientID ? credentials : nil
    }

    func save(_ updated: OAuthCredentials) {
        lock.lock()
        credentials = updated
        lock.unlock()
    }
}

@main
struct ChatGPTRequestReadTests {
    @MainActor static func main() async throws {
        let suite = "com.pendingname.aauv.fixture.plan-request.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = OAuthCredentials(flow: .chatgptPlan, accessToken: "synthetic-access",
                                            refreshToken: "synthetic-refresh", clientID: "oaiapp_async_read",
                                            expiresAt: Date().timeIntervalSince1970 + 3600,
                                            scopes: ["chatgpt.tokens.use.direct", "resource.invoke"])
        let id = credentials.clientID!
        func reset() {
            defaults.set(id, forKey: ChatGPTPlanSession.selectionKey)
            defaults.set([id], forKey: "preferredNativeChatGPTRegistrations")
            defaults.removeObject(forKey: APIKey.revisionKey)
        }
        reset()
        let gate = PlanReadGate(credentials)
        let explicit = Task {
            try await ChatGPTPlanSession.selectionForRequest(clientID: id, defaults: defaults,
                                                              native: { gate.read($0) }, imported: { _ in nil })
        }
        for await _ in gate.events.prefix(1) {}
        // Creating the request session must not try another synchronous read.
        let bot = BotSnapshot(name: "fixture", endpoint: "https://api.openai.com/v1", model: "fixture",
                              loginMethod: .chatgpt, chatGPTClientID: id)
        _ = try await ModelSession(bot: bot, instructions: "", proxy: SingBox(defaults: defaults))
        defaults.set("oaiapp_other_default", forKey: ChatGPTPlanSession.selectionKey)
        APIKey.announceNativeChatGPTWrite(clientID: "oaiapp_other_default", defaults: defaults)
        gate.release.signal()
        let selected = try await explicit.value
        precondition(selected?.credentials.clientID == id && selected?.source == .native)

        for change in ["revision", "native-write", "source", "default", "cancel"] {
            reset()
            let gate = PlanReadGate(credentials)
            let pending = Task {
                try await ChatGPTPlanSession.selectionForRequest(clientID: change == "default" ? nil : id,
                                                                  defaults: defaults,
                                                                  native: { gate.read($0) }, imported: { _ in nil })
            }
            for await _ in gate.events.prefix(1) {}
            switch change {
            case "revision": defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
            case "native-write": APIKey.announceNativeChatGPTWrite(clientID: id, defaults: defaults)
            case "source": defaults.set([], forKey: "preferredNativeChatGPTRegistrations")
            case "default": defaults.set("oaiapp_other_default", forKey: ChatGPTPlanSession.selectionKey)
            default: pending.cancel()
            }
            gate.release.signal()
            do {
                _ = try await pending.value
                preconditionFailure("A stale or cancelled selection escaped its read context")
            } catch is CancellationError { precondition(change == "cancel") }
            catch is ChatClient.ClientError { precondition(change != "cancel") }
        }

        reset()
        let valid = ChatGPTPlanSession.Selection(credentials: credentials, source: .native)
        try await ChatGPTPlanSession.validateTokenForRequest(credentials.accessToken, for: id, read: { _ in valid })
        for invalid in ["token", "scope", "identity"] {
            var changed = credentials
            if invalid == "token" { changed.accessToken = "replacement-access" }
            if invalid == "scope" { changed.scopes = [] }
            if invalid == "identity" { changed.clientID = "oaiapp_different" }
            let replacement = ChatGPTPlanSession.Selection(credentials: changed, source: .native)
            do {
                try await ChatGPTPlanSession.validateTokenForRequest(credentials.accessToken, for: id,
                                                                     read: { _ in replacement })
                preconditionFailure("A stale token, revoked scope or wrong registration passed submission validation")
            } catch is ChatClient.ClientError {}
        }
        try await checkSignOutDuringRead(credentials, defaults: defaults)
        try await checkSignOutDuringRenewalVerification(credentials)
        try await checkCancelledRenewalWaiter(credentials)
        try await checkOwnRefreshReadNonce(credentials, defaults: defaults)
        print("ChatGPT request reads stayed off main, preserved explicit bindings, rejected changed/cancelled contexts, and kept shared renewal/sign-out semantics.")
    }

    @MainActor private static func checkOwnRefreshReadNonce(_ original: OAuthCredentials, defaults: UserDefaults) async throws {
        var expired = original
        expired.clientID = "oaiapp_own_refresh_nonce"
        expired.expiresAt = 1
        let id = expired.clientID!
        let vault = PlanFixtureVault(expired)
        var fresh = expired
        fresh.accessToken = "synthetic-nonce-renewed"
        fresh.expiresAt = Date().timeIntervalSince1970 + 3600
        let read: @MainActor (String?) async throws -> ChatGPTPlanSession.Selection? = { requested in
            try await ChatGPTPlanSession.selectionForRequest(clientID: requested, defaults: defaults,
                                                              native: { vault.read($0) }, imported: { _ in nil })
        }
        let token = try await ChatGPTPlanSession.resolveToken(clientID: id, read: read) { _ in
            vault.save(fresh)
            APIKey.announceNativeChatGPTWrite(clientID: id, defaults: defaults)
            return fresh
        }
        precondition(token == fresh.accessToken)
        try await ChatGPTPlanSession.validateTokenForRequest(token, for: id, read: read)
    }

    @MainActor private static func checkSignOutDuringRead(_ credentials: OAuthCredentials, defaults: UserDefaults) async throws {
        let id = credentials.clientID!
        let gate = PlanReadGate(credentials)
        let pending = Task {
            try await ChatGPTPlanSession.selectionForRequest(clientID: id, defaults: defaults,
                                                              native: { gate.read($0) }, imported: { _ in nil })
        }
        for await _ in gate.events.prefix(1) {}
        let revoking = AsyncStream<Void>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let signOut = Task {
            try await ChatGPTPlanSession.endSession(id, read: { [.init(credentials: credentials, source: .native)] },
                                                    revoke: { _ in
                                                        revoking.continuation.yield(())
                                                        for await _ in finish.stream.prefix(1) {}
                                                        return true
                                                    }, replace: { _, _ in })
        }
        for await _ in revoking.stream.prefix(1) {}
        try ChatGPTPlanSession.requireNotSigningOut("oaiapp_unrelated")
        gate.release.signal()
        do {
            _ = try await pending.value
            preconditionFailure("A read returned usable credentials during sign-out")
        } catch is ChatClient.ClientError {}
        finish.continuation.yield(())
        _ = try await signOut.value
    }

    @MainActor private static func checkSignOutDuringRenewalVerification(_ original: OAuthCredentials) async throws {
        var expired = original
        expired.clientID = "oaiapp_renewal_read"
        expired.expiresAt = 1
        var refreshed = expired
        refreshed.accessToken = "synthetic-renewed"
        refreshed.expiresAt = Date().timeIntervalSince1970 + 3600
        var current = ChatGPTPlanSession.Selection(credentials: expired, source: .native)
        var reads = 0
        let verifying = AsyncStream<Void>.makeStream()
        let releaseRead = AsyncStream<Void>.makeStream()
        let resolving = Task {
            try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: { _ in
                reads += 1
                if reads == 2 {
                    verifying.continuation.yield(())
                    for await _ in releaseRead.stream.prefix(1) {}
                }
                return current
            }) { _ in
                current = .init(credentials: refreshed, source: .native)
                return refreshed
            }
        }
        for await _ in verifying.stream.prefix(1) {}
        let revoking = AsyncStream<Void>.makeStream()
        let releaseRevoke = AsyncStream<Void>.makeStream()
        let signOut = Task {
            try await ChatGPTPlanSession.endSession(expired.clientID!, read: { [current] }, revoke: { _ in
                revoking.continuation.yield(())
                for await _ in releaseRevoke.stream.prefix(1) {}
                return true
            }, replace: { _, cleared in current = .init(credentials: cleared, source: .native) })
        }
        for await _ in revoking.stream.prefix(1) {}
        releaseRead.continuation.yield(())
        do {
            _ = try await resolving.value
            preconditionFailure("A renewed token escaped sign-out while verification was suspended")
        } catch is ChatClient.ClientError {}
        releaseRevoke.continuation.yield(())
        _ = try await signOut.value
    }

    @MainActor private static func checkCancelledRenewalWaiter(_ original: OAuthCredentials) async throws {
        var expired = original
        expired.clientID = "oaiapp_shared_cancel"
        expired.expiresAt = 1
        var refreshed = expired
        refreshed.accessToken = "synthetic-shared-renewed"
        refreshed.expiresAt = Date().timeIntervalSince1970 + 3600
        var current = ChatGPTPlanSession.Selection(credentials: expired, source: .native)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let joined = AsyncStream<Void>.makeStream()
        var renewals = 0
        let first = Task {
            try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: { _ in current }) { _ in
                renewals += 1
                started.continuation.yield(())
                for await _ in release.stream.prefix(1) {}
                current = .init(credentials: refreshed, source: .native)
                return refreshed
            }
        }
        for await _ in started.stream.prefix(1) {}
        let second = Task {
            try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: { _ in
                joined.continuation.yield(())
                return current
            }) { _ in preconditionFailure("A second waiter started a duplicate renewal") }
        }
        for await _ in joined.stream.prefix(1) {}
        first.cancel()
        release.continuation.yield(())
        do {
            _ = try await first.value
            preconditionFailure("A cancelled waiter returned the shared token")
        } catch is CancellationError {}
        let token = try await second.value
        precondition(token == refreshed.accessToken && renewals == 1)
    }
}
