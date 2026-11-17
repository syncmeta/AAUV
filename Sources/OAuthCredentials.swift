import Foundation
import Network

/// Imported credentials are unverified until checked with their provider.
struct OAuthCredentials: Codable, Sendable {
    enum Flow: String, Codable {
        case chatgptPlan, codex, githubCopilot
    }

    var flow: Flow
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var clientID: String?
    var expiresAt: Double?
    var scopes: [String]?
    var verifiedSubject: String?
    var verifiedEmail: String?
    var verifiedLogin: String?
    var reauthorizationRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case flow, scopes, verifiedSubject, verifiedEmail, verifiedLogin
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case clientID = "client_id"
        case expiresAt = "expires_at"
        case reauthorizationRequired = "reauthorization_required"
    }

    var loginMethod: LoginMethod {
        flow == .githubCopilot ? .copilot : .chatgpt
    }

    var permitsChatGPTPlan: Bool {
        guard flow == .chatgptPlan, reauthorizationRequired != true else { return false }
        // Older imported OAuth records may omit scope metadata. Their grants
        // are checked by OpenAI; native token responses always record scopes.
        guard let scopes else { return verifiedSubject == nil }
        return scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke")
    }

    var transferable: Self {
        var copy = self
        copy.verifiedSubject = nil
        copy.verifiedEmail = nil
        copy.verifiedLogin = nil
        return copy
    }

    func validateStructure() throws {
        let cleared = flow == .chatgptPlan && reauthorizationRequired == true &&
            accessToken.isEmpty && refreshToken == nil && expiresAt == nil
        let usable = reauthorizationRequired != true && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard cleared || usable, accessToken.utf8.count <= 65_536,
              !accessToken.contains(where: \.isNewline),
              [refreshToken, idToken].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 65_536 }),
              expiresAt.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw ChatClient.ClientError.message("OAuth 凭证格式无效。")
        }
        if flow == .chatgptPlan {
            guard let clientID, !clientID.isEmpty else {
                throw ChatClient.ClientError.message("ChatGPT 授权凭证需要包含原 client_id。")
            }
        }
    }
}

@MainActor
enum ChatGPTPlanSession {
    struct Account: Identifiable, Sendable {
        let id: String
        let email: String?

        var label: String {
            "\(email ?? "ChatGPT") · \(id.suffix(10))"
        }
    }

    struct Selection: Sendable {
        enum Source: Sendable { case native, imported }

        let credentials: OAuthCredentials
        let source: Source

        func matches(_ other: Self) -> Bool {
            source == other.source && credentials.clientID == other.credentials.clientID &&
                credentials.accessToken == other.credentials.accessToken && credentials.refreshToken == other.credentials.refreshToken
        }
    }

    struct SettingsCredentials: Sendable {
        let selected: OAuthCredentials?
        let accounts: [Account]
        let hasLocalTokens: Bool
        let canReauthorize: Bool
        let webSearch: Bool
        let legacyModel: String?
    }

    private struct Renewal {
        let starting: Selection
        let task: Task<OAuthCredentials, Error>
    }

    nonisolated static let endpoint = URL(string: "https://api.openai.com/v1")!
    nonisolated static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static let selectionKey = "activeChatGPTRegistration"
    static let usagePauseKey = "chatGPTUsagePausedRegistrations"
    private static let nativePreferencesKey = "preferredNativeChatGPTRegistrations"
    private static let missingCredentials = ChatClient.ClientError.message("请先通过 ChatGPT 登录，或导入此会话使用的订阅 OAuth 凭证。")
    private static let missingPlanPermission = ChatClient.ClientError.message("此账户尚未授权使用 ChatGPT 订阅。可在设置中授权，或选择 BYOK。")
    private static let signInAgain = ChatClient.ClientError.message("此 ChatGPT 授权已失效。请在设置重新登录，或导入新的授权凭证。")
    private static var renewals: [String: Renewal] = [:]
    private static var signingOut: Set<String> = []
    private static var requests: [String: [UUID: Task<String, Error>]] = [:]

    static func usagePaused(_ id: String, in snapshot: Data? = nil, defaults: UserDefaults = .standard) -> Bool {
        pausedRegistrations(snapshot ?? defaults.data(forKey: usagePauseKey)).contains(id)
    }

    static func setUsagePaused(_ paused: Bool, for id: String, defaults: UserDefaults = .standard) {
        var registrations = pausedRegistrations(defaults.data(forKey: usagePauseKey))
        if paused { registrations.insert(id) }
        else { registrations.remove(id) }
        if let data = try? JSONEncoder().encode(registrations.sorted()) {
            defaults.set(data, forKey: usagePauseKey)
        }
    }

    static func requireUsageAvailable(_ id: String, defaults: UserDefaults = .standard) throws {
        guard !usagePaused(id, defaults: defaults) else {
            throw ChatClient.ClientError.message("此账户的 ChatGPT 订阅请求已暂停。请在设置查看用量并恢复请求。")
        }
    }

    private static func pausedRegistrations(_ snapshot: Data?) -> Set<String> {
        guard let data = snapshot,
              let registrations = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(registrations)
    }

    static var activeRegistration: String? {
        UserDefaults.standard.string(forKey: selectionKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static var nativePreferences: Set<String> {
        nativePreferences(in: .standard)
    }

    private static func nativePreferences(in defaults: UserDefaults) -> Set<String> {
        let saved = defaults.stringArray(forKey: nativePreferencesKey)
        // Older builds preferred the native credential only for the active registration.
        let active = defaults.string(forKey: selectionKey).flatMap { $0.isEmpty ? nil : $0 }
        return Set(saved ?? [active].compactMap { $0 })
    }

    static func prefersNativeSource(for id: String, defaults: UserDefaults = .standard) -> Bool {
        nativePreferences(in: defaults).contains(id)
    }

    static func recordCredentialSources(native id: String? = nil, imported: [String] = []) {
        var preferred = nativePreferences.subtracting(imported)
        if let id { preferred.insert(id) }
        UserDefaults.standard.set(preferred.sorted(), forKey: nativePreferencesKey)
    }

    nonisolated static func accounts() throws -> [Account] {
        let ids = Set(try APIKey.nativeChatGPTRegistrations()).union(try APIKey.importedChatGPTRegistrations())
        return ids.sorted().map { id in
            Account(id: id, email: (try? APIKey.nativeChatGPT(clientID: id))?.verifiedEmail)
        }
    }

    static func credentials(clientID: String? = nil) throws -> OAuthCredentials? {
        let credentials = try selected(clientID: clientID)?.credentials
        if let id = credentials?.clientID { try requireNotSigningOut(id) }
        return credentials
    }

    static func settingsCredentials() async throws -> SettingsCredentials {
        let active = activeRegistration
        let preferences = nativePreferences
        let revision = UserDefaults.standard.string(forKey: APIKey.revisionKey)
        let result = try await APIKey.readInBackground {
            let selection = try select(clientID: nil, activeRegistration: active, nativePreferences: preferences,
                                       native: APIKey.nativeChatGPT, imported: APIKey.importedChatGPT)
            let credentials = selection?.credentials
            let id = credentials?.clientID
            let native = try id.flatMap(APIKey.nativeChatGPT)
            let imported = try id.flatMap { try APIKey.importedChatGPT(clientID: $0) }
            let configuration = try APIKey.importedConfiguration()
            return SettingsCredentials(
                selected: credentials, accounts: try accounts(),
                hasLocalTokens: [native, imported].compactMap { $0 }.contains {
                    !$0.accessToken.isEmpty || $0.idToken != nil || $0.refreshToken != nil
                },
                canReauthorize: native != nil ||
                    (credentials?.reauthorizationRequired == true && credentials?.clientID?.hasPrefix("oaiapp_") == true),
                webSearch: DefaultHostedTools.chatGPT(imported: configuration).contains(HostedTool.webSearch.rawValue),
                legacyModel: configuration?.loginMethod == .chatgpt ? configuration?.model : nil
            )
        }
        guard active == activeRegistration, preferences == nativePreferences,
              revision == UserDefaults.standard.string(forKey: APIKey.revisionKey) else { throw CancellationError() }
        if let id = result.selected?.clientID { try requireNotSigningOut(id) }
        return result
    }

    static func requireRegistration(_ clientID: String?) throws -> String {
        guard let id = try credentials(clientID: clientID)?.clientID else { throw missingCredentials }
        return id
    }

    private static func selected(clientID: String?) throws -> Selection? {
        try select(clientID: clientID, activeRegistration: activeRegistration, nativePreferences: nativePreferences,
                   native: APIKey.nativeChatGPT, imported: APIKey.importedChatGPT)
    }

    static func selectionForRequest(
        clientID: String?, defaults: UserDefaults = .standard,
        native: @escaping @Sendable (String) throws -> OAuthCredentials? = { try APIKey.nativeChatGPT(clientID: $0) },
        imported: @escaping @Sendable (String?) throws -> OAuthCredentials? = { try APIKey.importedChatGPT(clientID: $0) }
    ) async throws -> Selection? {
        let active = defaults.string(forKey: selectionKey).flatMap { $0.isEmpty ? nil : $0 }
        let preferences = nativePreferences(in: defaults)
        let revision = defaults.string(forKey: APIKey.revisionKey)
        let requested = clientID ?? active
        let nativeRevision = requested.flatMap { APIKey.nativeChatGPTReadRevision(clientID: $0, defaults: defaults) }
        return try await readSelectionForRequest(
            clientID: clientID, activeRegistration: active, nativePreferences: preferences,
            validateContext: {
                guard revision == defaults.string(forKey: APIKey.revisionKey) else {
                    throw ChatClient.ClientError.message("读取期间 ChatGPT 凭证已更换，请重新发送。")
                }
                if let requested {
                    guard nativeRevision == APIKey.nativeChatGPTReadRevision(clientID: requested, defaults: defaults) else {
                        throw ChatClient.ClientError.message("读取期间此 ChatGPT 注册的凭证已更换，请重新发送。")
                    }
                }
                // An explicitly bound chat is independent of the default account.
                // Its own preferred credential source must still remain unchanged.
                if let id = clientID {
                    guard preferences.contains(id) == nativePreferences(in: defaults).contains(id) else {
                        throw ChatClient.ClientError.message("此 ChatGPT 注册的授权来源已更换，请重新发送。")
                    }
                } else {
                    guard active == defaults.string(forKey: selectionKey).flatMap({ $0.isEmpty ? nil : $0 }),
                          preferences == nativePreferences(in: defaults) else {
                        throw ChatClient.ClientError.message("ChatGPT 账户已更换，请重新发送。")
                    }
                }
            }, native: native, imported: imported
        )
    }

    static func readSelectionForRequest(
        clientID: String?, activeRegistration: String?, nativePreferences: Set<String>,
        validateContext: @escaping ProxyRouteCheck,
        native: @escaping @Sendable (String) throws -> OAuthCredentials?,
        imported: @escaping @Sendable (String?) throws -> OAuthCredentials?
    ) async throws -> Selection? {
        try Task.checkCancellation()
        try validateContext()
        let requested = clientID ?? activeRegistration
        if let requested { try requireNotSigningOut(requested) }
        let result = try await APIKey.readInBackground {
            try select(clientID: clientID, activeRegistration: activeRegistration, nativePreferences: nativePreferences,
                       native: native, imported: imported)
        }
        try Task.checkCancellation()
        try validateContext()
        if let id = result?.credentials.clientID {
            guard requested == nil || requested == id else { throw missingCredentials }
            try requireNotSigningOut(id)
        }
        return result
    }

    static func requireNotSigningOut(_ id: String) throws {
        guard !signingOut.contains(id) else {
            throw ChatClient.ClientError.message("此 ChatGPT 账户正在退出。")
        }
    }

    static func validateToken(_ token: String, for id: String) throws {
        try requireNotSigningOut(id)
        guard let credentials = try selected(clientID: id)?.credentials,
              credentials.permitsChatGPTPlan, credentials.accessToken == token else { throw signInAgain }
    }

    static func validateTokenForRequest(
        _ token: String, for id: String,
        read: @escaping @MainActor (String?) async throws -> Selection? = {
            try await selectionForRequest(clientID: $0)
        }
    ) async throws {
        try Task.checkCancellation()
        try requireNotSigningOut(id)
        let credentials = try await read(id)?.credentials
        try Task.checkCancellation()
        try requireNotSigningOut(id)
        guard credentials?.clientID == id, credentials?.permitsChatGPTPlan == true,
              credentials?.accessToken == token else { throw signInAgain }
    }

    static func withRequest(_ id: String, perform: @escaping () async throws -> String) async throws -> String {
        try requireNotSigningOut(id)
        try Task.checkCancellation()
        let request = UUID()
        let task = Task { try await perform() }
        requests[id, default: [:]][request] = task
        defer {
            requests[id]?.removeValue(forKey: request)
            if requests[id]?.isEmpty == true { requests.removeValue(forKey: id) }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func signOut(_ id: String, route: ProxyRequestRoute?) async throws -> Bool {
        try await endSession(id, read: {
            guard let active = try selected(clientID: id) else { return [] }
            var copies = [active]
            if active.source == .native, let imported = try APIKey.importedChatGPT(clientID: id) {
                copies.append(.init(credentials: imported, source: .imported))
            } else if active.source == .imported, let native = try APIKey.nativeChatGPT(clientID: id) {
                copies.append(.init(credentials: native, source: .native))
            }
            return copies
        }, revoke: { token in
            guard let route else { return false }
            return await revokeSession(token, clientID: id) { request in
                try await send(request, proxy: route.configuration, validateRoute: route.validate, timeout: 5)
            }
        }, replace: { previous, cleared in
            if previous.source == .imported {
                try APIKey.replaceImportedChatGPT(previous.credentials, with: cleared)
            } else {
                let current = try APIKey.nativeChatGPT(clientID: id)
                guard current.map({ Selection(credentials: $0, source: .native).matches(previous) }) == true else {
                    throw ChatClient.ClientError.message("退出期间 ChatGPT 授权已更换，请重试。")
                }
                try APIKey.saveNativeChatGPT(cleared)
            }
        })
    }

    static func endSession(_ id: String, read: () throws -> [Selection], revoke: (String) async -> Bool,
                           replace: (Selection, OAuthCredentials) throws -> Void) async throws -> Bool {
        try requireNotSigningOut(id)
        signingOut.insert(id)
        defer { signingOut.remove(id) }
        if let running = requests[id] {
            for request in running.values { request.cancel() }
        }
        // A rotation already sent may have issued a new refresh token. Revoke the
        // committed replacement so a concurrent refresh cannot revive the session.
        if let renewal = renewals[id] { _ = try? await renewal.task.value }
        let copies = try read()
        guard !copies.isEmpty else { throw missingCredentials }
        var confirmed = true
        var attempted = Set<String>()
        for selection in copies {
            let credentials = selection.credentials
            if let token = credentials.refreshToken, !token.isEmpty {
                if attempted.insert(token).inserted, !(await revoke(token)) { confirmed = false }
            } else if !credentials.accessToken.isEmpty {
                confirmed = false
            }
        }
        // Clear the preferred copy first. If the other slot cannot be written,
        // selection still resolves to the retained, token-free registration.
        for selection in copies {
            var cleared = selection.credentials
            cleared.accessToken = ""
            cleared.refreshToken = nil
            cleared.idToken = nil
            cleared.expiresAt = nil
            cleared.scopes = nil
            cleared.reauthorizationRequired = true
            try cleared.validateStructure()
            try replace(selection, cleared)
        }
        return confirmed
    }

    static func revokeSession(_ token: String, clientID: String, transport: (URLRequest) async throws -> (Data, Int)) async -> Bool {
        struct Discovery: Decodable { let revocation_endpoint: URL }
        let discovery = URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        for attempt in 0..<2 {
            do {
                let (metadata, discoveryStatus) = try await transport(discovery)
                if discoveryStatus >= 500 { throw URLError(.badServerResponse) }
                guard discoveryStatus == 200 else { return false }
                let endpoint = try JSONDecoder().decode(Discovery.self, from: metadata).revocation_endpoint
                guard endpoint.absoluteString == "https://auth.openai.com/api/accounts/oauth/revoke" else { return false }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(formBody([
                    "token": token, "token_type_hint": "refresh_token", "client_id": clientID
                ]).utf8)
                let (body, status) = try await transport(request)
                if status < 500 { return status == 200 && body.isEmpty }
            } catch is URLError {
                // Retry transport failures once while the refresh token is still available.
            } catch { return false }
            if attempt == 0 {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return false }
            }
        }
        return false
    }

    nonisolated static func select(clientID: String?, activeRegistration: String?,
                       nativePreferences: Set<String>,
                       native: (String) throws -> OAuthCredentials?,
                       imported: (String?) throws -> OAuthCredentials?) throws -> Selection? {
        if let id = clientID ?? activeRegistration {
            let transferred = try imported(id)
            if !nativePreferences.contains(id), let transferred { return Selection(credentials: transferred, source: .imported) }
            if let local = try native(id) { return Selection(credentials: local, source: .native) }
            return transferred.map { Selection(credentials: $0, source: .imported) }
        }
        return try imported(nil).map { Selection(credentials: $0, source: .imported) }
    }

    static func token(proxy: ProxyConfiguration?, clientID: String? = nil, validateRoute: ProxyRouteCheck? = nil) async throws -> String {
        let token = try await resolveToken(clientID: clientID ?? activeRegistration, read: {
            try await selectionForRequest(clientID: $0)
        }) {
            try await refresh($0, proxy: proxy, validateRoute: validateRoute)
        }
        try Task.checkCancellation()
        try validateRoute?()
        return token
    }

    static func resolveToken(clientID: String?, read: @escaping @MainActor (String?) async throws -> Selection?,
                             renew: @escaping (Selection) async throws -> OAuthCredentials) async throws -> String {
        try Task.checkCancellation()
        if let clientID { try requireNotSigningOut(clientID) }
        guard let selection = try await read(clientID), let id = selection.credentials.clientID,
              clientID == nil || id == clientID else {
            throw missingCredentials
        }
        try Task.checkCancellation()
        let credentials = selection.credentials
        try requireNotSigningOut(id)
        try credentials.validateStructure()
        guard credentials.reauthorizationRequired != true else { throw signInAgain }
        guard credentials.permitsChatGPTPlan else { throw missingPlanPermission }
        guard let expiry = credentials.expiresAt, expiry <= Date().timeIntervalSince1970 else {
            return credentials.accessToken
        }
        if let running = renewals[id] {
            guard running.starting.matches(selection) else {
                throw ChatClient.ClientError.message("此 ChatGPT 注册的先前续期仍在进行，请稍后重新发送。")
            }
            return try await renewedToken(running, id: id, read: read)
        }
        let renewal = Renewal(starting: selection, task: Task { try await renew(selection) })
        renewals[id] = renewal
        defer { renewals[id] = nil }
        return try await renewedToken(renewal, id: id, read: read)
    }

    private static func renewedToken(_ renewal: Renewal, id: String,
                                     read: @MainActor (String?) async throws -> Selection?) async throws -> String {
        let updated = try await renewal.task.value
        try Task.checkCancellation()
        try requireNotSigningOut(id)
        let expected = Selection(credentials: updated, source: renewal.starting.source)
        let actual = try await read(id)
        try Task.checkCancellation()
        try requireNotSigningOut(id)
        guard actual?.matches(expected) == true else {
            throw ChatClient.ClientError.message("续期期间 ChatGPT 凭证已更换，请重新发送。")
        }
        guard updated.reauthorizationRequired != true else { throw signInAgain }
        guard updated.permitsChatGPTPlan else { throw missingPlanPermission }
        return updated.accessToken
    }

    private static func refresh(_ selection: Selection, proxy: ProxyConfiguration?,
                                validateRoute: ProxyRouteCheck?) async throws -> OAuthCredentials {
        let credentials = selection.credentials
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty, let clientID = credentials.clientID else {
            throw ChatClient.ClientError.message("ChatGPT 授权已过期，请重新登录。")
        }
        let form = formBody([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID,
            "resource": endpoint.absoluteString
        ])
        return try await updateAfterRefresh(credentials, acquireLease: {
            try await CredentialRefreshLease.acquire()
        }, validateBeforeExchange: {
            let current = try await selectionForRequest(clientID: clientID)
            guard current?.matches(selection) == true else {
                throw ChatClient.ClientError.message("续期前 ChatGPT 凭证已更换，请重新发送。")
            }
        }, exchange: {
            try await exchange(form: form, proxy: proxy, validateRoute: validateRoute)
        }, save: { updated in
            if selection.source == .native {
                let latest = try APIKey.nativeChatGPT(clientID: clientID)
                guard latest?.refreshToken == refreshToken, latest?.accessToken == credentials.accessToken else {
                    throw ChatClient.ClientError.message("续期期间 ChatGPT 凭证已更换，请重新发送。")
                }
                try APIKey.saveNativeChatGPT(updated)
            } else {
                try APIKey.replaceImportedChatGPT(credentials, with: updated)
            }
        })
    }

    static func updateAfterRefresh(
        _ credentials: OAuthCredentials,
        acquireLease: (@MainActor () async throws -> CredentialRefreshLease)? = nil,
        validateBeforeExchange: (@MainActor () async throws -> Void)? = nil,
        exchange: () async throws -> TokenResponse, save: (OAuthCredentials) throws -> Void
    ) async throws -> OAuthCredentials {
        try Task.checkCancellation()
        let lease = try await acquireLease?()
        defer { lease?.release() }
        try await validateBeforeExchange?()
        try Task.checkCancellation()
        let updated: TokenResponse
        do { updated = try await exchange() }
        catch let failure as TokenExchangeError where failure.code?.unusableRefresh == true {
            var cleared = credentials
            cleared.accessToken = ""
            cleared.refreshToken = nil
            cleared.expiresAt = nil
            cleared.reauthorizationRequired = true
            try cleared.validateStructure()
            try save(cleared)
            throw signInAgain
        }
        guard let newRefresh = updated.refresh_token, !newRefresh.isEmpty else {
            throw ChatClient.ClientError.message("服务商没有返回新的 ChatGPT 续期凭证，请重新登录。")
        }
        var result = credentials
        result.accessToken = updated.access_token
        result.refreshToken = newRefresh
        result.expiresAt = Date().timeIntervalSince1970 + updated.expires_in
        result.reauthorizationRequired = nil
        if let scope = updated.scope { result.scopes = scope.split(separator: " ").map(String.init) }
        try result.validateStructure()

        try save(result)
        return result
    }

    static func exchange(form: String, proxy: ProxyConfiguration?, validateRoute: ProxyRouteCheck? = nil) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.utf8)
        let (data, status) = try await send(request, proxy: proxy, validateRoute: validateRoute)
        return try tokenResponse(data, status: status)
    }

    static func tokenResponse(_ data: Data, status: Int) throws -> TokenResponse {
        if status != 200 {
            struct Failure: Decodable {
                enum CodingKeys: CodingKey { case error }
                struct Details: Decodable { let code: String }
                let code: String
                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    if let plain = try? values.decode(String.self, forKey: .error) { code = plain }
                    else { code = try values.decode(Details.self, forKey: .error).code }
                }
            }
            let code: TokenExchangeError.Code?
            if [400, 401, 403].contains(status), data.count <= 64 * 1024,
               let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                code = TokenExchangeError.Code(rawValue: failure.code)
            } else {
                code = nil
            }
            throw TokenExchangeError(status: status, code: code)
        }
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard result.expires_in.isFinite, result.expires_in > 0,
              result.token_type.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw ChatClient.ClientError.message("OpenAI 返回的 OAuth 令牌格式无效。")
        }
        return result
    }

    static func fetch(_ request: URLRequest, proxy: ProxyConfiguration?, validateRoute: ProxyRouteCheck? = nil,
                      validateCredential: AsyncCredentialCheck? = nil) async throws -> Data {
        let (data, status) = try await send(request, proxy: proxy, validateRoute: validateRoute,
                                           validateCredential: validateCredential)
        guard status == 200 else {
            throw ChatClient.ClientError.message("OpenAI 授权服务返回 HTTP \(status)。请检查登录状态或重新授权。")
        }
        return data
    }

    private static func send(_ request: URLRequest, proxy: ProxyConfiguration?, validateRoute: ProxyRouteCheck?,
                             validateCredential: AsyncCredentialCheck? = nil,
                             timeout: TimeInterval = 30) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        if let proxy { config.proxyConfigurations = [proxy] }
        let session = URLSession(configuration: config, delegate: ChatClient.NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        if let validateCredential {
            try Task.checkCancellation()
            try await validateCredential()
            try Task.checkCancellation()
        }
        try validateRoute?()
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    nonisolated static func formBody(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let id_token: String?
        let scope: String?
        let token_type: String
    }

    struct TokenExchangeError: LocalizedError {
        enum Code: String {
            case invalidGrant = "invalid_grant"
            case invalidClient = "invalid_client"
            case invalidRefresh = "invalid_refresh_token"
            case tokenExpired = "token_expired"
            case refreshExpired = "refresh_token_expired"
            case refreshInvalidated = "refresh_token_invalidated"
            case refreshReused = "refresh_token_reused"

            var unusableRefresh: Bool { self != .invalidClient }
        }

        let status: Int
        let code: Code?

        var errorDescription: String? {
            switch code {
            case .invalidGrant: "这次 ChatGPT 授权码已失效，请继续上次登录。"
            case .invalidClient: "OpenAI 未接受此 ChatGPT 注册，请检查账户或应用注册。"
            default: "OpenAI 授权服务返回 HTTP \(status)，请稍后重试。"
            }
        }
    }
}
