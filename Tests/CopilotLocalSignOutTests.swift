import Foundation
import Security

private enum SignOutFixtureError: Error { case deletionFailed, keychain(OSStatus) }

private final class SignOutVaultFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: PortableSettings?
    private var slots = Set(["https://aauv.invalid/github-copilot", "https://aauv.invalid/imported-github-copilot"])
    var failLegacyDelete = false // Mutated only by the main test actor.
    private(set) var writes = 0

    init(_ configuration: PortableSettings?) { self.configuration = configuration }

    func read() throws -> APIKey.CopilotSignOutSnapshot {
        precondition(!Thread.isMainThread, "Credential lookup blocked the main actor.")
        lock.lock()
        let value = configuration
        lock.unlock()
        return try APIKey.copilotSignOutSnapshot(readConfiguration: { value })
    }

    func publish(_ value: PortableSettings) {
        precondition(Thread.isMainThread)
        lock.lock()
        configuration = value
        writes += 1
        lock.unlock()
    }

    func remove(_ url: URL) throws {
        precondition(Thread.isMainThread)
        if failLegacyDelete && url.absoluteString == "https://aauv.invalid/imported-github-copilot" {
            throw SignOutFixtureError.deletionFailed
        }
        lock.lock()
        slots.remove(url.absoluteString)
        writes += 1
        lock.unlock()
    }

    func stored() -> (PortableSettings?, Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        return (configuration, slots)
    }
}

private final class BlockedSignOutRead: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let vault: SignOutVaultFixture

    init(_ vault: SignOutVaultFixture) {
        self.vault = vault
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func read() throws -> APIKey.CopilotSignOutSnapshot {
        let snapshot = try vault.read()
        started.yield(())
        precondition(release.wait(timeout: .now() + 5) == .success)
        return snapshot
    }
}

// Every query, including teardown, is scoped to a fresh test-only service. This
// is injected into the real sign-out preparation/commit functions; no production
// service, existing account or global Keychain enumeration is used.
private final class IsolatedSignOutKeychain: @unchecked Sendable {
    let service = "com.pendingname.aauv.tests.copilot-signout.\(UUID().uuidString)"

    private func query(_ endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: endpoint.absoluteString, kSecAttrSynchronizable as String: false]
    }

    func read(_ endpoint: URL) throws -> String {
        precondition(!Thread.isMainThread)
        var attributes = query(endpoint)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { throw SignOutFixtureError.keychain(status) }
        return text
    }

    func save(_ text: String, at endpoint: URL) throws {
        precondition(Thread.isMainThread)
        let attributes = query(endpoint)
        let changes = [kSecValueData as String: Data(text.utf8)]
        let status = SecItemUpdate(attributes as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SignOutFixtureError.keychain(status) }
        var new = attributes
        new[kSecValueData as String] = Data(text.utf8)
        let added = SecItemAdd(new as CFDictionary, nil)
        guard added == errSecSuccess else { throw SignOutFixtureError.keychain(added) }
    }

    func remove(_ endpoint: URL) throws {
        precondition(Thread.isMainThread)
        let status = SecItemDelete(query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SignOutFixtureError.keychain(status) }
    }

    func cleanup() {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: false] as CFDictionary)
        precondition(status == errSecSuccess || status == errSecItemNotFound, "Fresh test service cleanup failed.")
    }
}

@main @MainActor
struct CopilotLocalSignOutTests {
    static func main() async throws {
        let suite = "com.pendingname.aauv.tests.copilot-signout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try PrivateTemporaryDirectory()
        let leaseFile = directory.url.appending(path: "fixture.json")
        let acquire: @MainActor () async throws -> CredentialRefreshLease = {
            try await CredentialRefreshLease.acquire(file: leaseFile, checkPending: {})
        }
        try await verifySnapshots()
        reset(defaults)
        try await verifyRenewalAndRequestInvalidation(defaults, acquire: acquire)
        reset(defaults)
        try await verifyFailureAndRetry(defaults, suite: suite, acquire: acquire)
        reset(defaults)
        try await verifyReadFailure(defaults, acquire: acquire)
        for change in ["identity", "vault", "cancel"] {
            reset(defaults)
            try await verifyReadCAS(defaults, change: change, acquire: acquire)
        }
        if CommandLine.arguments.contains("--keychain") {
            reset(defaults)
            try await verifyFreshKeychainService(defaults, acquire: acquire)
            print("Copilot local sign-out synthetic regressions and isolated fresh-service Keychain cleanup passed.")
        } else {
            print("Copilot local sign-out synthetic regressions passed; fresh-service Keychain mode was not requested.")
        }
    }

    private static func reset(_ defaults: UserDefaults) {
        defaults.set(false, forKey: APIKey.copilotSignOutPendingKey)
        defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
        defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
    }

    private static func configuration() -> PortableSettings {
        let chatGPT = OAuthCredentials(flow: .chatgptPlan, accessToken: "synthetic-chatgpt-only",
                                      clientID: "oaiapp_synthetic-retained")
        let copilot = OAuthCredentials(flow: .githubCopilot, accessToken: "gho_synthetic-imported-only")
        return PortableSettings(endpoint: "https://fixture.invalid/v1", model: "retained-model", loginMethod: .byok,
                                key: "synthetic-legacy-byok-only", nodeLinks: ["trojan://synthetic@fixture.invalid:443"],
                                credentials: PortableCredentials(chatGPT: [chatGPT], copilot: copilot))
    }

    private static func clear(_ snapshot: APIKey.CopilotSignOutSnapshot, vault: SignOutVaultFixture) throws {
        try APIKey.clearCopilotSignOut(snapshot, publish: { vault.publish($0) }, remove: { try vault.remove($0) })
    }

    private static func verifyRetainedConfiguration(_ stored: PortableSettings?) throws {
        let value = stored!
        precondition(value.credentials?.copilot == nil && value.oauth == nil && value.key == nil)
        precondition(value.credentials?.chatGPT?.first?.clientID == "oaiapp_synthetic-retained")
        precondition(value.credentials?.chatGPT?.first?.accessToken == "synthetic-chatgpt-only")
        precondition(value.credentials?.byokKeys?["https://fixture.invalid/v1"] == "synthetic-legacy-byok-only")
        precondition(value.nodeLinks == configuration().nodeLinks && value.model == "retained-model")
    }

    private static func verifySnapshots() async throws {
        let fixture = SignOutVaultFixture(configuration())
        let snapshot = try await APIKey.readInBackground { try fixture.read() }
        try clear(snapshot, vault: fixture)
        let (stored, slots) = fixture.stored()
        try verifyRetainedConfiguration(stored)
        precondition(slots.isEmpty)
        // Legacy single-OAuth documents are normalized without losing another
        // provider's authorization or accidentally keeping Copilot's old field.
        for flow in [OAuthCredentials.Flow.chatgptPlan, .githubCopilot] {
            let credentials = OAuthCredentials(flow: flow, accessToken: "synthetic-legacy-only",
                                              clientID: flow == .chatgptPlan ? "oaiapp_synthetic-legacy" : nil)
            let legacy = PortableSettings(endpoint: "https://fixture.invalid/v1", model: "legacy",
                                          loginMethod: credentials.loginMethod, oauth: credentials)
            let snapshot = try await APIKey.readInBackground { try APIKey.copilotSignOutSnapshot(readConfiguration: { legacy }) }
            if flow == .chatgptPlan {
                precondition(snapshot.configurationWithoutCopilot == nil) // Leave an unrelated vault byte-for-byte alone.
            } else {
                precondition(snapshot.configurationWithoutCopilot?.oauth == nil)
                precondition(snapshot.configurationWithoutCopilot?.credentials?.copilot == nil)
            }
        }
    }

    private static func verifyRenewalAndRequestInvalidation(
        _ defaults: UserDefaults, acquire: @escaping @MainActor () async throws -> CredentialRefreshLease
    ) async throws {
        let session = CopilotSession(defaults: defaults)
        let expired = OAuthCredentials(flow: .githubCopilot, accessToken: "gho_synthetic-expired-only",
                                       refreshToken: "synthetic-refresh-only", expiresAt: 1)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var replacements = 0
        let renewal = Task {
            try await session.token(proxy: nil, read: { expired }, renew: { old in
                started.continuation.yield(())
                for await _ in release.stream { break }
                var updated = old
                updated.accessToken = "gho_synthetic-rotated-only"
                return updated
            }, acquireRenewalLease: acquire, replace: { _, _ in replacements += 1 })
        }
        for await _ in started.stream.prefix(1) {}
        let requestStarted = AsyncStream<Void>.makeStream()
        let request = Task {
            try await session.withRequest {
                requestStarted.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
                return "late response"
            }
        }
        for await _ in requestStarted.stream.prefix(1) {}
        let vault = SignOutVaultFixture(configuration())
        let signOut = Task {
            try await CopilotSession.signOut(defaults: defaults, read: { try vault.read() }, acquireLease: acquire,
                                            clear: { try clear($0, vault: vault) })
        }
        try await waitForPending(defaults)
        do { try session.validate(); preconditionFailure("Old session survived sign-out intent.") } catch {}
        do { try CopilotSession(defaults: defaults).validate(); preconditionFailure("A new request bypassed pending cleanup.") } catch {}
        do { _ = try await request.value; preconditionFailure("A registered request was not cancelled.") } catch is CancellationError {}
        precondition(vault.writes == 0) // Still waiting for the sent exchange.
        release.continuation.yield(())
        do { _ = try await renewal.value; preconditionFailure("Late renewal returned credentials.") } catch {}
        try await signOut.value
        precondition(replacements == 0 && !defaults.bool(forKey: APIKey.copilotSignOutPendingKey))
        precondition(vault.stored().1.isEmpty)
        try verifyRetainedConfiguration(vault.stored().0)
    }

    private static func verifyFailureAndRetry(
        _ defaults: UserDefaults, suite: String, acquire: @escaping @MainActor () async throws -> CredentialRefreshLease
    ) async throws {
        let directory = try PrivateTemporaryDirectory()
        let store = ConversationStore(file: directory.url.appending(path: "history.json"))
        let bot = LocalBot(configuration: BotSnapshot(name: "Retained fixture bot", endpoint: "https://github.com", model: "",
                                                     loginMethod: .copilot))
        try store.saveBots([bot])
        let chat = try store.create(bot: bot.snapshot)
        try store.append(ChatMessage(role: .user, content: "retained synthetic history"), to: chat)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let originalBots = try encoder.encode(store.bots)
        let originalChats = try encoder.encode(store.conversations)
        let originalPending = try store.pendingReplicaCount()
        let vault = SignOutVaultFixture(configuration())
        vault.failLegacyDelete = true
        do {
            try await CopilotSession.signOut(defaults: defaults, read: { try vault.read() }, acquireLease: acquire,
                                            clear: { try clear($0, vault: vault) })
            preconditionFailure("Partial cleanup falsely succeeded.")
        } catch SignOutFixtureError.deletionFailed {}
        precondition(defaults.bool(forKey: APIKey.copilotSignOutPendingKey))
        precondition(UserDefaults(suiteName: suite)!.bool(forKey: APIKey.copilotSignOutPendingKey))
        precondition(vault.stored().1 == ["https://aauv.invalid/imported-github-copilot"])
        do {
            _ = try await CopilotSession(defaults: defaults).token(proxy: nil, read: {
                preconditionFailure("Pending cleanup read a fallback credential slot.")
            })
            preconditionFailure("Pending cleanup allowed a request.")
        } catch {}
        vault.failLegacyDelete = false
        try await CopilotSession.signOut(defaults: defaults, read: { try vault.read() }, acquireLease: acquire,
                                        clear: { try clear($0, vault: vault) })
        precondition(!defaults.bool(forKey: APIKey.copilotSignOutPendingKey) && vault.stored().1.isEmpty)
        let finalBots = try encoder.encode(store.bots)
        let finalChats = try encoder.encode(store.conversations)
        let finalPending = try store.pendingReplicaCount()
        precondition(originalBots == finalBots && originalChats == finalChats && originalPending == finalPending)
    }

    private static func verifyReadCAS(
        _ defaults: UserDefaults, change: String,
        acquire: @escaping @MainActor () async throws -> CredentialRefreshLease
    ) async throws {
        let vault = SignOutVaultFixture(configuration())
        let blocked = BlockedSignOutRead(vault)
        let signOut = Task {
            try await CopilotSession.signOut(defaults: defaults, read: { try blocked.read() }, acquireLease: acquire,
                                            clear: { try clear($0, vault: vault) })
        }
        for await _ in blocked.events.prefix(1) {}
        switch change {
        case "identity":
            // Represents a newer explicitly completed login/import, not a
            // provider refresh. Its intent must survive this older sign-out.
            defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
            defaults.set(false, forKey: APIKey.copilotSignOutPendingKey)
        case "vault": defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
        default: signOut.cancel()
        }
        blocked.release.signal()
        do { try await signOut.value; preconditionFailure("Stale or cancelled deletion committed.") } catch {}
        precondition(vault.writes == 0 && vault.stored().1.count == 2)
        precondition(defaults.bool(forKey: APIKey.copilotSignOutPendingKey) == (change != "identity"))
    }

    private static func verifyReadFailure(
        _ defaults: UserDefaults, acquire: @escaping @MainActor () async throws -> CredentialRefreshLease
    ) async throws {
        let vault = SignOutVaultFixture(configuration())
        do {
            try await CopilotSession.signOut(defaults: defaults, read: {
                precondition(!Thread.isMainThread)
                throw APIKey.KeychainError(status: errSecAuthFailed)
            }, acquireLease: acquire, clear: { _ in preconditionFailure("A failed read reached deletion.") })
            preconditionFailure("A failed credential read falsely succeeded.")
        } catch is APIKey.KeychainError {}
        precondition(defaults.bool(forKey: APIKey.copilotSignOutPendingKey) && vault.writes == 0)
        try await CopilotSession.signOut(defaults: defaults, read: { try vault.read() }, acquireLease: acquire,
                                        clear: { try clear($0, vault: vault) })
        precondition(!defaults.bool(forKey: APIKey.copilotSignOutPendingKey) && vault.stored().1.isEmpty)
    }

    private static func verifyFreshKeychainService(
        _ defaults: UserDefaults, acquire: @escaping @MainActor () async throws -> CredentialRefreshLease
    ) async throws {
        let keychain = IsolatedSignOutKeychain()
        defer { keychain.cleanup() }
        let configurationURL = URL(string: "https://aauv.invalid/imported-configuration")!
        let nativeURL = URL(string: "https://aauv.invalid/github-copilot")!
        let legacyURL = URL(string: "https://aauv.invalid/imported-github-copilot")!
        let original = try JSONEncoder().encode(configuration())
        try keychain.save(String(decoding: original, as: UTF8.self), at: configurationURL)
        try keychain.save("synthetic-native-only", at: nativeURL)
        try keychain.save("synthetic-legacy-only", at: legacyURL)
        try await CopilotSession.signOut(defaults: defaults, read: {
            try APIKey.copilotSignOutSnapshot(readConfiguration: {
                let raw = try keychain.read(configurationURL)
                return raw.isEmpty ? nil : try JSONDecoder().decode(PortableSettings.self, from: Data(raw.utf8))
            })
        }, acquireLease: acquire, clear: { snapshot in
            try APIKey.clearCopilotSignOut(snapshot, publish: { value in
                try keychain.save(String(decoding: JSONEncoder().encode(value), as: UTF8.self), at: configurationURL)
            }, remove: { try keychain.remove($0) })
        })
        let result = try await APIKey.readInBackground {
            (try keychain.read(configurationURL), try keychain.read(nativeURL), try keychain.read(legacyURL))
        }
        precondition(result.1.isEmpty && result.2.isEmpty)
        try verifyRetainedConfiguration(JSONDecoder().decode(PortableSettings.self, from: Data(result.0.utf8)))
    }

    private static func waitForPending(_ defaults: UserDefaults) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !defaults.bool(forKey: APIKey.copilotSignOutPendingKey) {
            precondition(ContinuousClock.now < deadline, "Sign-out did not begin.")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
