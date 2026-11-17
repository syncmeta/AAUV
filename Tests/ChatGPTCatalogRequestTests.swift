import Foundation

private final class CatalogVault: @unchecked Sendable {
    private let lock = NSLock()
    private var nativeValue: OAuthCredentials
    private var importedValue: OAuthCredentials?
    private var blockNextNative = false
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation

    init(_ value: OAuthCredentials) {
        nativeValue = value
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func block() {
        lock.lock()
        blockNextNative = true
        lock.unlock()
    }

    func native(_ id: String) -> OAuthCredentials? {
        precondition(!Thread.isMainThread)
        lock.lock()
        let wait = blockNextNative
        blockNextNative = false
        let result = id == nativeValue.clientID ? nativeValue : nil
        lock.unlock()
        if wait {
            started.yield(())
            precondition(release.wait(timeout: .now() + 5) == .success,
                         "A model-catalog read blocked the main actor")
        }
        return result
    }

    func imported(_ id: String?) -> OAuthCredentials? {
        precondition(!Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        return id == nil || id == importedValue?.clientID ? importedValue : nil
    }

    func save(_ value: OAuthCredentials, imported: Bool = false) {
        lock.lock()
        if imported { importedValue = value } else { nativeValue = value }
        lock.unlock()
    }
}

@main
struct ChatGPTCatalogRequestTests {
    private enum FixtureError: Error { case invalidRoute, rejectedBeforeHTTP }
    private static let body = Data(#"{"models":[{"slug":"model-a","display_name":"A","visibility":"list"},{"slug":"model-a","display_name":"Duplicate","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hidden"},{"slug":"","display_name":"Empty","visibility":"list"},{"slug":"model-b","display_name":"B","visibility":"list"}]}"#.utf8)

    @MainActor static func main() async throws {
        let suite = "com.pendingname.aauv.fixture.catalog.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = OAuthCredentials(flow: .chatgptPlan, accessToken: "synthetic-catalog-access",
                                         refreshToken: "synthetic-catalog-refresh", clientID: "oaiapp_catalog",
                                         expiresAt: Date().timeIntervalSince1970 + 3600,
                                         scopes: ["chatgpt.tokens.use.direct", "resource.invoke"])
        let id = original.clientID!
        func reset() {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(id, forKey: ChatGPTPlanSession.selectionKey)
            defaults.set([id], forKey: "preferredNativeChatGPTRegistrations")
        }
        func reader(_ vault: CatalogVault) -> ChatGPTCatalogRequest.ReadSelection {
            { requested in
                try await ChatGPTPlanSession.selectionForRequest(clientID: requested, defaults: defaults,
                                                                  native: { vault.native($0) }, imported: { vault.imported($0) })
            }
        }
        reset()
        let vault = CatalogVault(original)
        let intent = ChatGPTCatalogIntent()
        let validate = intent.begin()
        vault.block()
        let preparing = Task {
            try await ChatGPTCatalogRequest.account(id, validateIntent: validate, read: reader(vault))
        }
        for await _ in vault.events.prefix(1) {}
        try validate()
        vault.release.signal()
        let account = try await preparing.value
        precondition(account == id)
        let request = ChatGPTCatalogRequest(account: account, validateIntent: validate, validateRoute: {},
                                             defaults: defaults, read: reader(vault))
        var submitted = 0
        let result = try await request.load(token: original.accessToken) { request, guardCredential in
            precondition(request.url?.path == "/v1/models")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + original.accessToken)
            precondition(guardCredential != nil)
            try await guardCredential?()
            submitted += 1
            APIKey.announceNativeChatGPTWrite(clientID: "oaiapp_unrelated", defaults: defaults)
            return body
        }
        try result.validatePublication()
        precondition(submitted == 1 && result.models.map(\.slug) == ["model-a", "model-b"])
        defaults.set("oaiapp_changed_after_return", forKey: ChatGPTPlanSession.selectionKey)
        do { try result.validatePublication(); preconditionFailure("An account change after return escaped the publication guard") }
        catch is CancellationError {}
        defaults.set(id, forKey: ChatGPTPlanSession.selectionKey)
        intent.invalidate()
        do { try result.validatePublication(); preconditionFailure("An obsolete result remained publishable") }
        catch is CancellationError {}

        for change in ["default", "source", "native-write", "import-write", "token", "scope", "intent", "route"] {
            reset()
            let vault = CatalogVault(original)
            let intent = ChatGPTCatalogIntent()
            let validate = intent.begin()
            var routeValid = true
            let request = ChatGPTCatalogRequest(account: id, validateIntent: validate, validateRoute: {
                guard routeValid else { throw FixtureError.invalidRoute }
            }, defaults: defaults, read: reader(vault))
            var submitted = 0
            do {
                _ = try await request.load(token: original.accessToken) { _, guardCredential in
                    try await guardCredential?()
                    submitted += 1
                    switch change {
                    case "default": defaults.set("oaiapp_other", forKey: ChatGPTPlanSession.selectionKey)
                    case "source":
                        vault.save(original, imported: true)
                        defaults.set([], forKey: "preferredNativeChatGPTRegistrations")
                    case "native-write": APIKey.announceNativeChatGPTWrite(clientID: id, defaults: defaults)
                    case "import-write": defaults.set("external-vault", forKey: APIKey.revisionKey)
                    case "token":
                        var changed = original
                        changed.accessToken = "synthetic-external-new-token"
                        vault.save(changed)
                    case "scope":
                        var changed = original
                        changed.scopes = []
                        vault.save(changed)
                    case "intent": intent.invalidate()
                    default: routeValid = false
                    }
                    return body
                }
                preconditionFailure("A late catalog response survived changed credentials, account or UI intent")
            } catch is CancellationError {}
            catch is ChatClient.ClientError {}
            catch FixtureError.invalidRoute {}
            precondition(submitted == 1)
        }

        reset()
        let before = ChatGPTCatalogIntent()
        let beforeGuard = before.begin()
        let beforeRequest = ChatGPTCatalogRequest(account: id, validateIntent: beforeGuard, validateRoute: {},
                                                   defaults: defaults, read: reader(vault))
        var sends = 0
        do {
            _ = try await beforeRequest.load(token: original.accessToken) { _, guardCredential in
                APIKey.announceNativeChatGPTWrite(clientID: id, defaults: defaults)
                try await guardCredential?()
                sends += 1
                return body
            }
            preconditionFailure("A changed authorization reached HTTP submission")
        } catch is CancellationError {}
        precondition(sends == 0)

        reset()
        try await checkCancelledResponse(original, defaults: defaults, read: reader(vault))
        try await checkOwnImportedRefresh(original, defaults: defaults)
        try await checkExternalChangeDuringTokenRead(original, defaults: defaults)

        // Exercise the real fetch preflight with a non-network URL and a guard
        // that always throws before URLSession can submit anything.
        do {
            _ = try await ChatGPTPlanSession.fetch(URLRequest(url: URL(string: "urn:aauv:catalog-test")!), proxy: nil,
                                                   validateRoute: { preconditionFailure("Route ran after rejected credentials") },
                                                   validateCredential: { throw FixtureError.rejectedBeforeHTTP })
            preconditionFailure("Fetch bypassed its asynchronous credential guard")
        } catch FixtureError.rejectedBeforeHTTP {}
        print("Catalog loading stayed off main, discarded obsolete account/token/source/nonce/route/intent results, and accepted its own imported-token rotation.")
    }

    @MainActor private static func checkCancelledResponse(
        _ original: OAuthCredentials, defaults: UserDefaults, read: @escaping ChatGPTCatalogRequest.ReadSelection
    ) async throws {
        let intent = ChatGPTCatalogIntent()
        let validate = intent.begin()
        let waiting = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let task = Task {
            try await ChatGPTCatalogRequest(account: original.clientID!, validateIntent: validate, validateRoute: {},
                                             defaults: defaults, read: read)
                .load(token: original.accessToken) { _, guardCredential in
                    try await guardCredential?()
                    waiting.continuation.yield(())
                    for await _ in release.stream.prefix(1) {}
                    return body
                }
        }
        for await _ in waiting.stream.prefix(1) {}
        task.cancel()
        release.continuation.yield(())
        do { _ = try await task.value; preconditionFailure("Cancelled catalog data was returned for publication") }
        catch is CancellationError {}
    }

    @MainActor private static func checkOwnImportedRefresh(_ original: OAuthCredentials, defaults: UserDefaults) async throws {
        var expired = original
        expired.expiresAt = 1
        let vault = CatalogVault(original)
        vault.save(expired, imported: true)
        defaults.set([], forKey: "preferredNativeChatGPTRegistrations")
        let read: ChatGPTCatalogRequest.ReadSelection = { requested in
            try await ChatGPTPlanSession.selectionForRequest(clientID: requested, defaults: defaults,
                                                              native: { vault.native($0) }, imported: { vault.imported($0) })
        }
        let intent = ChatGPTCatalogIntent()
        let validate = intent.begin()
        let account = try await ChatGPTCatalogRequest.account(validateIntent: validate, read: read)
        intent.beginTokenRead()
        var fresh = original
        fresh.accessToken = "synthetic-own-rotation"
        fresh.refreshToken = "synthetic-own-rotated-refresh"
        let token = try await ChatGPTPlanSession.resolveToken(clientID: account, read: read) { _ in
            vault.save(fresh, imported: true)
            defaults.set("own-rotation", forKey: APIKey.revisionKey)
            precondition(!intent.credentialsDidChange("own-rotation"))
            return fresh
        }
        intent.didReadToken(revision: "own-rotation")
        let result = try await ChatGPTCatalogRequest(account: account, validateIntent: validate, validateRoute: {},
                                                     defaults: defaults, read: read).load(token: token) { _, guardCredential in
            try await guardCredential?()
            return body
        }
        precondition(!intent.credentialsDidChange("own-rotation"))
        try result.validatePublication()
        intent.finish()
        precondition(!intent.credentialsDidChange("own-rotation"))
        defaults.set("external-rotation", forKey: APIKey.revisionKey)
        precondition(intent.credentialsDidChange("external-rotation"))
        do { try result.validatePublication(); preconditionFailure("A newer external revision left an old directory publishable") }
        catch is CancellationError {}
    }

    @MainActor private static func checkExternalChangeDuringTokenRead(_ original: OAuthCredentials, defaults: UserDefaults) async throws {
        let vault = CatalogVault(original)
        var external = original
        external.accessToken = "synthetic-external-token"
        vault.save(external, imported: true)
        defaults.set([], forKey: "preferredNativeChatGPTRegistrations")
        let intent = ChatGPTCatalogIntent()
        let validate = intent.begin()
        intent.beginTokenRead()
        defaults.set("external-during-read", forKey: APIKey.revisionKey)
        precondition(!intent.credentialsDidChange("external-during-read"))
        intent.didReadToken(revision: "external-during-read")
        let read: ChatGPTCatalogRequest.ReadSelection = { requested in
            try await ChatGPTPlanSession.selectionForRequest(clientID: requested, defaults: defaults,
                                                              native: { vault.native($0) }, imported: { vault.imported($0) })
        }
        var sent = 0
        do {
            _ = try await ChatGPTCatalogRequest(account: original.clientID!, validateIntent: validate, validateRoute: {},
                                                 defaults: defaults, read: read).load(token: original.accessToken) { _, guardCredential in
                try await guardCredential?()
                sent += 1
                return body
            }
            preconditionFailure("Suppressing the UI event during token retrieval accepted an obsolete token")
        } catch is ChatClient.ClientError {}
        precondition(sent == 0)
    }
}
