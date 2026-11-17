import Foundation

private enum RotationFixtureError: Error { case pendingImport, changedCredential }

private final class RotationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var credential: OAuthCredentials
    private var journal = false
    private var count = 0

    init(_ credential: OAuthCredentials) { self.credential = credential }
    func read() -> OAuthCredentials {
        lock.lock()
        defer { lock.unlock() }
        return credential
    }
    func checkPending() throws {
        lock.lock()
        defer { lock.unlock() }
        if journal { throw RotationFixtureError.pendingImport }
    }
    func setPending(_ value: Bool) {
        lock.lock()
        journal = value
        lock.unlock()
    }
    func exchangeStarted() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var exchanges: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func replace(_ old: OAuthCredentials, with updated: OAuthCredentials) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !journal else { throw RotationFixtureError.pendingImport }
        guard old.accessToken == credential.accessToken, old.refreshToken == credential.refreshToken else {
            throw RotationFixtureError.changedCredential
        }
        credential = updated
    }
}

@main
struct RefreshImportCoordinationTests {
    @MainActor static func main() async throws {
        for flow in [OAuthCredentials.Flow.chatgptPlan, .githubCopilot] {
            for pendingAtStart in [false, true] {
                try await verify(flow: flow, pendingAtStart: pendingAtStart)
            }
        }
        print("Both providers blocked import before staging during rotation and refused refresh before exchange while a durable journal remained.")
    }

    @MainActor private static func verify(flow: OAuthCredentials.Flow, pendingAtStart: Bool) async throws {
        let directory = try PrivateTemporaryDirectory()
        let store = ConversationStore(file: directory.url.appending(path: "fixture.json"))
        let id = "oaiapp_synthetic_\(UUID().uuidString)"
        let old = OAuthCredentials(flow: flow, accessToken: "gho_old-synthetic", refreshToken: "old-synthetic-refresh",
                                   clientID: id, expiresAt: 1, scopes: ["resource.invoke", "chatgpt.tokens.use.direct"])
        var updated = old
        updated.accessToken = "gho_new-synthetic"
        updated.refreshToken = "new-synthetic-refresh"
        updated.expiresAt = Date().timeIntervalSince1970 + 3600
        let expected = updated
        let fixture = RotationFixture(old)
        fixture.setPending(pendingAtStart)
        let acquire: @MainActor () async throws -> CredentialRefreshLease = {
            try await CredentialRefreshLease.acquire(file: store.file, checkPending: { try fixture.checkPending() })
        }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let suite = "com.pendingname.aauv.rotation-fixture.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
        let copilot = CopilotSession(defaults: defaults)
        let rotating = Task { @MainActor in
            if flow == .chatgptPlan {
                return try await ChatGPTPlanSession.resolveToken(clientID: id, read: { _ in
                    let credentials = try await APIKey.readInBackground { fixture.read() }
                    return .init(credentials: credentials, source: .native)
                }) { selected in
                    try await ChatGPTPlanSession.updateAfterRefresh(selected.credentials, acquireLease: acquire,
                        validateBeforeExchange: {
                            let current = try await APIKey.readInBackground { fixture.read() }
                            guard current.accessToken == selected.credentials.accessToken else {
                                throw RotationFixtureError.changedCredential
                            }
                        }, exchange: {
                            fixture.exchangeStarted()
                            started.continuation.yield(())
                            for await _ in release.stream { break }
                            return .init(access_token: expected.accessToken, refresh_token: expected.refreshToken,
                                         expires_in: 3600, id_token: nil, scope: expected.scopes?.joined(separator: " "),
                                         token_type: "Bearer")
                        }, save: { try fixture.replace(selected.credentials, with: $0) }
                    )
                }
            }
            return try await copilot.token(proxy: nil, read: { fixture.read() }, renew: { _ in
                fixture.exchangeStarted()
                started.continuation.yield(())
                for await _ in release.stream { break }
                return expected
            }, acquireRenewalLease: acquire, replace: { try fixture.replace($0, with: $1) })
        }
        if pendingAtStart {
            do { _ = try await rotating.value; preconditionFailure("A pending journal allowed token rotation.") }
            catch RotationFixtureError.pendingImport {}
            precondition(fixture.exchanges == 0 && fixture.read().refreshToken == old.refreshToken)
            return
        }

        for await _ in started.stream.prefix(1) {}
        let settings = PortableSettings(endpoint: "https://example.invalid/v1", model: "fixture")
        var imported = false
        do {
            try store.commitConfiguration(settings) { _ in imported = true }
            preconditionFailure("Import entered its journal stage during token rotation.")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("应用配置或授权正在保存"))
        }
        precondition(!imported)
        await store.resumeConfigurationImport(read: {
            preconditionFailure("Recovery read its journal while token rotation held a shared lease.")
        }, publish: { _ in }, writePreferences: { _ in }, clear: {}).value
        precondition(store.configurationUnavailable)
        release.continuation.yield(())
        let token = try await rotating.value
        precondition(token == expected.accessToken && fixture.read().refreshToken == expected.refreshToken && fixture.exchanges == 1)
        await store.resumeConfigurationImport(read: { nil }, publish: { _ in }, writePreferences: { _ in }, clear: {}).value
        precondition(!store.configurationUnavailable)
    }
}
