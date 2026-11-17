import SwiftUI
import Network
import AAUVCore
#if os(iOS)
import SafariServices
#elseif os(macOS)
import AppKit
#endif

struct ChatGPTLoginSection: View {
    private struct RetryAuthorization {
        let clientID: String
        let requestConsent: Bool
    }

    let proxy: SingBox
    let referencedRegistrations: [SyncedChatGPTEnrollment.Reference]
    @AppStorage(ChatGPTPlanSession.selectionKey) private var registration = ""
    @AppStorage(ChatGPTPlanSession.usagePauseKey) private var usagePauseState = Data()
    @AppStorage(APIKey.revisionKey) private var credentialRevision = ""
    @AppStorage("chatGPTModel") private var selectedModel = ""
    @AppStorage("loginMethod") private var loginMethod = LoginMethod.byok.rawValue
    @State private var task: Task<Void, Never>?
    @State private var catalogIntent = ChatGPTCatalogIntent()
    @State private var credentialTask: Task<Void, Never>?
    @State private var loadingCredentials = false
    @State private var loadingRegistration: String?
    @State private var credentialReadFailed = false
    @State private var credentialSnapshotLoaded = false
    @State private var feedback = ""
    @State private var accounts: [ChatGPTPlanSession.Account] = []
    @State private var selectedAccountID: String?
    @State private var planEnabled = false
    @State private var canReauthorizePlan = false
    @State private var needsSignIn = false
    @State private var retryAuthorization: RetryAuthorization?
    @State private var confirmSignOut = false
    @State private var signingOut = false
    @State private var hasLocalTokens = false
    @State private var remoteRevocationUnconfirmed = false
    @State private var webSearch = false
    @State private var models: [ChatGPTModelCatalog.Model] = []
    #if os(iOS)
    @State private var browser: BrowserPage?
    @State private var waitingForBrowser = false
    #endif

    init(proxy: SingBox, referencedRegistrations: [SyncedChatGPTEnrollment.Reference] = []) {
        self.proxy = proxy
        self.referencedRegistrations = referencedRegistrations
    }

    private var knownLocalRegistrations: Set<String>? {
        guard credentialSnapshotLoaded, !loadingCredentials, !credentialReadFailed else { return nil }
        return Set(accounts.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Sign in with ChatGPT") { signIn(newRegistration: false) }
                .disabled(task != nil)
            if loadingCredentials { ProgressView("正在读取本机钥匙串…") }
            if credentialReadFailed { Button("重新读取钥匙串") { reloadCredentials() } }
            if let retryAuthorization {
                Button("继续上次 ChatGPT 登录") {
                    signIn(newRegistration: false, requestConsent: retryAuthorization.requestConsent,
                           resuming: retryAuthorization.clientID)
                }
                .disabled(task != nil)
            }
            if !registration.isEmpty || selectedAccountID != nil || !accounts.isEmpty {
                if !accounts.isEmpty {
                    Picker("ChatGPT 账户", selection: Binding(
                        get: { selectedAccountID ?? "" },
                        set: { switchAccount(to: $0) }
                    )) {
                        if selectedAccountID == nil { Text("请选择账户").tag("") }
                        ForEach(accounts) { account in
                            Text(account.label).tag(account.id)
                        }
                    }
                    .disabled(task != nil)
                }
                Button("使用 ChatGPT 订阅") {
                    loginMethod = LoginMethod.chatgpt.rawValue
                    BotSnapshot.resetRecentDefault()
                }
                .disabled(task != nil || !planEnabled || loginMethod == LoginMethod.chatgpt.rawValue)
                if selectedAccountID != nil, !planEnabled {
                    Text(needsSignIn ? "此账户的授权已失效。请重新登录，或导入新的授权凭证。"
                         : "此账户已保存，仍需授权使用 ChatGPT 订阅。也可在下方配置 BYOK。").font(.footnote)
                    if canReauthorizePlan {
                        Button(needsSignIn ? "重新登录此账户" : "授权使用 ChatGPT 订阅") {
                            signIn(newRegistration: false, requestConsent: !needsSignIn, resuming: selectedAccountID)
                        }
                            .disabled(task != nil)
                    }
                }
                Button("登录另一个 ChatGPT 账户") { signIn(newRegistration: true) }
                    .disabled(task != nil)
                if hasLocalTokens {
                    Button("退出此 ChatGPT 账户…", role: .destructive) { confirmSignOut = true }
                        .disabled(task != nil)
                }
                Button("刷新 ChatGPT 模型列表") { refreshModels() }
                    .disabled(task != nil || !planEnabled)
                if let selectedAccountID, ChatGPTPlanSession.usagePaused(selectedAccountID, in: usagePauseState) {
                    Text("此账户的 ChatGPT 订阅请求已暂停。").font(.footnote)
                    Link("查看 ChatGPT 用量", destination: ChatGPTPlanSession.usageURL)
                    Button("恢复 ChatGPT 请求") { ChatGPTPlanSession.setUsagePaused(false, for: selectedAccountID) }
                }
                if !models.isEmpty {
                    Picker("ChatGPT 模型", selection: $selectedModel) {
                        ForEach(models) { model in
                            Text(model.display_name).tag(model.slug)
                        }
                    }
                    .onChange(of: selectedModel) {
                        BotSnapshot.resetRecentDefault()
                    }
                } else {
                    TextField("ChatGPT 模型名称", text: $selectedModel)
                        .autocorrectionDisabled()
                        .disabled(!planEnabled)
                        .onChange(of: selectedModel) { BotSnapshot.resetRecentDefault() }
                }
                Toggle("ChatGPT 网页搜索", isOn: Binding(
                    get: { webSearch },
                    set: { enabled in
                        webSearch = enabled
                        DefaultHostedTools.saveChatGPT(enabled ? [HostedTool.webSearch.rawValue] : [])
                        BotSnapshot.resetRecentDefault()
                    }
                ))
                .disabled(!planEnabled)
                Text("网页搜索是否可用取决于模型和账号策略。").font(.footnote)
            }
            if let missing = SyncedChatGPTEnrollment.missingReferences(referencedRegistrations,
                                                                      knownLocalRegistrations: knownLocalRegistrations),
               !missing.isEmpty {
                DisclosureGroup("在此设备使用同步的 ChatGPT 连接") {
                    Text("这些机器人或会话使用的 ChatGPT 连接尚未在此设备授权。授权后保留原有注册和同步记录。")
                        .font(.footnote)
                    Text("请使用会话原来的同一 ChatGPT 用户和工作区完成授权。")
                        .font(.footnote)
                    ForEach(missing) { reference in
                        VStack(alignment: .leading, spacing: 6) {
                            if let name = reference.displayName { Text(name).font(.headline) }
                            else { Text("同步的 ChatGPT 连接").font(.headline) }
                            Text("关联 \(reference.botCount) 个机器人、\(reference.conversationCount) 个会话").font(.footnote)
                            if !reference.conversationTitles.isEmpty {
                                Text(reference.conversationTitles.prefix(2).joined(separator: " · ")).font(.footnote)
                            }
                            Button("为此设备授权") {
                                guard let client = SyncedChatGPTEnrollment.requestedClientID(
                                    reference.clientID, references: referencedRegistrations,
                                    knownLocalRegistrations: knownLocalRegistrations
                                ) else { return }
                                signIn(newRegistration: false, requestConsent: true, resuming: client)
                            }
                            .disabled(task != nil)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .disabled(task != nil)
            }
            if task != nil && !signingOut {
                Button("取消 ChatGPT 操作") {
                    catalogIntent.invalidate()
                    task?.cancel()
                    feedback = "已取消 ChatGPT 操作。"
                }
            }
            if !feedback.isEmpty { Text(feedback).font(.footnote) }
            if remoteRevocationUnconfirmed { Link("在 ChatGPT 管理应用授权", destination: ChatGPTPlanSession.usageURL) }
        }
        .disabled(loadingCredentials)
        .confirmationDialog("退出此 ChatGPT 账户？", isPresented: $confirmSignOut) {
            Button("退出账户", role: .destructive) { signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机将停止该账户的请求并清除登录凭证，聊天记录仍会保留。使用同一份授权的其他设备可能需要重新登录。")
        }
        .onAppear { reloadCredentials() }
        .onChange(of: registration) {
            if loadingRegistration != registration {
                catalogIntent.invalidate()
                task?.cancel()
                feedback = ""
                reloadCredentials()
            }
        }
        .onChange(of: credentialRevision) {
            let current = UserDefaults.standard.string(forKey: APIKey.revisionKey) ?? ""
            if catalogIntent.credentialsDidChange(current) {
                task?.cancel()
                models = []
                feedback = ""
            }
            reloadCredentials()
        }
        .onDisappear {
            credentialSnapshotLoaded = false
            catalogIntent.invalidate(); task?.cancel(); credentialTask?.cancel()
        }
        #if os(iOS)
        .sheet(item: $browser, onDismiss: {
            if waitingForBrowser { task?.cancel() }
        }) { page in
            AuthenticationBrowser(url: page.url).ignoresSafeArea()
        }
        #endif
    }

    @discardableResult
    private func reloadCredentials() -> Task<Void, Never> {
        credentialTask?.cancel()
        loadingCredentials = true
        credentialSnapshotLoaded = false
        if credentialReadFailed { feedback = "" }
        credentialReadFailed = false
        loadingRegistration = registration
        let next = Task { @MainActor in
            defer { if !Task.isCancelled { loadingCredentials = false } }
            do {
                let snapshot = try await ChatGPTPlanSession.settingsCredentials()
                try Task.checkCancellation()
                let credentials = snapshot.selected
                if selectedAccountID != credentials?.clientID { models = [] }
                selectedAccountID = credentials?.clientID
                planEnabled = credentials?.permitsChatGPTPlan == true
                needsSignIn = credentials?.reauthorizationRequired == true
                hasLocalTokens = snapshot.hasLocalTokens
                canReauthorizePlan = snapshot.canReauthorize
                if !planEnabled { models = [] }
                accounts = snapshot.accounts
                credentialSnapshotLoaded = true
                webSearch = snapshot.webSearch
                if selectedModel.isEmpty, ChatGPTPlanSession.activeRegistration == nil {
                    selectedModel = snapshot.legacyModel ?? ""
                }
            } catch is CancellationError {
                return
            } catch {
                selectedAccountID = nil
                planEnabled = false
                hasLocalTokens = false
                canReauthorizePlan = false
                credentialReadFailed = true
                feedback = safeMessage(error)
            }
        }
        credentialTask = next
        return next
    }

    private func switchAccount(to id: String) {
        guard task == nil, id != selectedAccountID, accounts.contains(where: { $0.id == id }) else { return }
        let validateIntent = catalogIntent.begin()
        let previousRegistration = registration
        feedback = "正在切换 ChatGPT 账户…"
        task = Task { @MainActor in
            defer { catalogIntent.finish(); task = nil }
            do {
                _ = try await ChatGPTCatalogRequest.account(id, validateIntent: {
                    try validateIntent()
                    guard registration == previousRegistration else { throw CancellationError() }
                })
                try validateIntent()
                // Capture the legacy source preference before changing the default registration.
                ChatGPTPlanSession.recordCredentialSources()
                remoteRevocationUnconfirmed = false
                registration = id
                selectedModel = ""
                await reloadCredentials().value
                try validateIntent()
                guard !credentialReadFailed else { return }
                BotSnapshot.resetRecentDefault()
                guard planEnabled else { feedback = "已切换 ChatGPT 账户。"; return }
                let network = try proxy.requestRoute()
                catalogIntent.beginTokenRead()
                let token = try await ChatGPTPlanSession.token(proxy: network.configuration, clientID: id,
                                                               validateRoute: network.validate)
                catalogIntent.didReadToken(revision: UserDefaults.standard.string(forKey: APIKey.revisionKey) ?? "")
                try await loadModels(token: token, registration: id, network: network, validateIntent: validateIntent)
                feedback = "已切换 ChatGPT 账户并更新模型列表。"
            } catch is CancellationError {
                return
            } catch {
                feedback = safeMessage(error)
            }
        }
    }

    private func signIn(newRegistration: Bool, requestConsent: Bool = false, resuming: String? = nil) {
        guard task == nil else { return }
        let validateIntent = catalogIntent.begin()
        remoteRevocationUnconfirmed = false
        let persistence = ChatGPTSignInRevision()
        UserDefaults.standard.removeObject(forKey: ChatGPTSignInFeedback.diagnosticKey)
        task = Task { @MainActor in
            var stage = ChatGPTSignInFeedback.Stage.callback
            defer {
                catalogIntent.finish()
                task = nil
                #if os(iOS)
                waitingForBrowser = false
                browser = nil
                #endif
            }
            do {
                let network = try proxy.requestRoute()
                let previous = newRegistration ? nil : try APIKey.nativeChatGPT(clientID: resuming ?? selectedAccountID ?? registration)
                let attempt = try begin(previous, resuming: resuming)
                defer { attempt.cancel() }
                guard var authorization = URLComponents(string: attempt.authorizationURL()) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if requestConsent, previous != nil || resuming != nil {
                    authorization.queryItems = (authorization.queryItems ?? []) + [URLQueryItem(name: "prompt", value: "consent")]
                }
                guard let url = authorization.url else { throw CocoaError(.fileReadCorruptFile) }
                feedback = stage.progressMessage
                #if os(iOS)
                waitingForBrowser = true
                browser = BrowserPage(url: url)
                #elseif os(macOS)
                guard NSWorkspace.shared.open(url) else {
                    throw ChatClient.ClientError.message("无法打开浏览器。")
                }
                #endif
                let callback = try await withTaskCancellationHandler {
                    try await Task.detached {
                        var error: NSError?
                        let data = attempt.awaitCallback(&error)
                        if let error { throw error }
                        return try JSONDecoder().decode(Callback.self, from: Data(data.utf8))
                    }.value
                } onCancel: {
                    attempt.cancel()
                }
                #if os(iOS)
                waitingForBrowser = false
                browser = nil
                #endif
                try Task.checkCancellation()
                // Keep the issued public registration for a retry if token
                // exchange or local persistence fails after browser approval.
                retryAuthorization = RetryAuthorization(clientID: callback.client_id, requestConsent: requestConsent)
                stage = .tokenExchange
                feedback = stage.progressMessage
                let token: ChatGPTPlanSession.TokenResponse
                do {
                    token = try await ChatGPTPlanSession.exchange(form: callback.form, proxy: network.configuration,
                                                                  validateRoute: network.validate)
                } catch let failure as ChatGPTPlanSession.TokenExchangeError where failure.code == .invalidGrant {
                    retryAuthorization = RetryAuthorization(clientID: callback.client_id, requestConsent: requestConsent)
                    throw failure
                }
                let scopes = token.scope?.split(separator: " ").map(String.init) ?? []
                guard let idToken = token.id_token else {
                    throw ChatClient.ClientError.message("OpenAI 未返回用于验证账户身份的令牌。")
                }
                let identity = try await verify(attempt, token: idToken, client: callback.client_id, network: network) { next in
                    stage = next
                    feedback = next.progressMessage
                }
                if let saved = try APIKey.nativeChatGPT(clientID: callback.client_id),
                   saved.verifiedSubject != identity.sub {
                    throw ChatClient.ClientError.message("本次授权返回的账户与现有注册不一致。")
                }
                let credentials = OAuthCredentials(
                    flow: .chatgptPlan, accessToken: token.access_token, refreshToken: token.refresh_token,
                    idToken: idToken, clientID: callback.client_id, expiresAt: Date().timeIntervalSince1970 + token.expires_in,
                    scopes: scopes, verifiedSubject: identity.sub, verifiedEmail: identity.email
                )
                try credentials.validateStructure()
                try Task.checkCancellation()
                stage = .save
                feedback = stage.progressMessage
                try ChatGPTPlanSession.requireNotSigningOut(callback.client_id)
                try persistence.validate()
                let active = try? ChatGPTPlanSession.credentials()
                try APIKey.saveNativeChatGPT(credentials)
                retryAuthorization = nil
                ChatGPTPlanSession.recordCredentialSources(native: callback.client_id)
                if credentials.permitsChatGPTPlan { loginMethod = LoginMethod.chatgpt.rawValue }
                if credentials.permitsChatGPTPlan || active?.permitsChatGPTPlan != true || active?.clientID == callback.client_id {
                    if selectedAccountID != callback.client_id { selectedModel = ""; models = [] }
                    registration = callback.client_id
                    BotSnapshot.resetRecentDefault()
                }
                await reloadCredentials().value
                guard credentials.permitsChatGPTPlan else {
                    feedback = "ChatGPT 账户已保存。请在账户列表选择它，再授权使用订阅，或配置 BYOK。"
                    return
                }
                feedback = "已通过 ChatGPT 登录，正在读取可用模型。"
                do {
                    catalogIntent.didReadToken(revision: UserDefaults.standard.string(forKey: APIKey.revisionKey) ?? "")
                    try await loadModels(token: token.access_token, registration: callback.client_id, network: network,
                                         validateIntent: validateIntent)
                    feedback = "已通过 ChatGPT 登录。"
                } catch is CancellationError {
                    return
                } catch {
                    feedback = "已通过 ChatGPT 登录。模型列表暂不可用，可手动刷新。"
                }
            } catch {
                if !Task.isCancelled { ChatGPTSignInFeedback.record(error, stage: stage) }
                feedback = Task.isCancelled ? "已取消 ChatGPT 登录。" : safeMessage(error, stage: stage)
            }
        }
    }

    private func signOut() {
        guard task == nil, let id = selectedAccountID else { return }
        remoteRevocationUnconfirmed = false
        signingOut = true
        feedback = "正在退出 ChatGPT 账户…"
        task = Task { @MainActor in
            defer {
                signingOut = false
                task = nil
                reloadCredentials()
            }
            do {
                let confirmed = try await ChatGPTPlanSession.signOut(id, route: try? proxy.requestRoute())
                if retryAuthorization?.clientID == id { retryAuthorization = nil }
                UserDefaults.standard.set(UUID().uuidString, forKey: APIKey.revisionKey)
                feedback = confirmed ? "已退出此 ChatGPT 账户。" : "已在本机退出，未能确认 OpenAI 已撤销此次授权。"
                remoteRevocationUnconfirmed = !confirmed
            } catch {
                feedback = "未能完全清除本机 ChatGPT 凭证。请重试。"
            }
        }
    }

    private func refreshModels() {
        guard task == nil else { return }
        let validateIntent = catalogIntent.begin()
        task = Task { @MainActor in
            defer { catalogIntent.finish(); task = nil }
            do {
                let network = try proxy.requestRoute()
                let account = try await ChatGPTCatalogRequest.account(validateIntent: validateIntent)
                catalogIntent.beginTokenRead()
                let token = try await ChatGPTPlanSession.token(proxy: network.configuration, clientID: account,
                                                               validateRoute: network.validate)
                catalogIntent.didReadToken(revision: UserDefaults.standard.string(forKey: APIKey.revisionKey) ?? "")
                try await loadModels(token: token, registration: account, network: network, validateIntent: validateIntent)
                feedback = "已更新 ChatGPT 模型列表。"
            } catch is CancellationError {
                return
            } catch {
                reloadCredentials()
                feedback = Task.isCancelled ? "已取消刷新。" : safeMessage(error)
            }
        }
    }

    private func begin(_ previous: OAuthCredentials?, resuming: String?) throws -> AauvcoreChatGPTSignIn {
        let defaults = UserDefaults.standard
        let key = "chatGPTAuthorizationHost"
        let host = defaults.string(forKey: key) ?? "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(host, forKey: key)
        var error: NSError?
        guard let attempt = AauvcoreBeginChatGPTSignIn(host, resuming ?? previous?.clientID ?? "", previous?.idToken ?? "", &error) else {
            throw ChatClient.ClientError.message("无法启动 ChatGPT 登录回调，请重试。")
        }
        return attempt
    }

    private func verify(
        _ attempt: AauvcoreChatGPTSignIn, token: String, client: String, network: ProxyRequestRoute,
        onStage: (ChatGPTSignInFeedback.Stage) -> Void
    ) async throws -> Identity {
        onStage(.discovery)
        let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
        let discovery = try await ChatGPTPlanSession.fetch(URLRequest(url: discoveryURL), proxy: network.configuration,
                                                          validateRoute: network.validate)
        let metadata = try JSONDecoder().decode(Discovery.self, from: discovery)
        guard metadata.issuer == "https://auth.openai.com",
              metadata.jwks_uri == "https://auth.openai.com/.well-known/jwks.json",
              let jwksURL = URL(string: metadata.jwks_uri) else {
            throw ChatClient.ClientError.message("OpenAI 身份验证服务返回了意外的签名地址。")
        }
        onStage(.jwks)
        let data = try await ChatGPTPlanSession.fetch(URLRequest(url: jwksURL), proxy: network.configuration,
                                                     validateRoute: network.validate)
        onStage(.identity)
        var error: NSError?
        let identity = attempt.verifyIdentity(token, jwks: String(decoding: data, as: UTF8.self), client: client, error: &error)
        if error != nil { throw ChatClient.ClientError.message("ChatGPT 账户签名或授权信息校验失败。") }
        return try JSONDecoder().decode(Identity.self, from: Data(identity.utf8))
    }

    private func loadModels(token: String, registration account: String, network: ProxyRequestRoute,
                            validateIntent: @escaping ProxyRouteCheck) async throws {
        let cacheSnapshot = BotSnapshot(name: "ChatGPT", endpoint: ChatGPTPlanSession.endpoint.absoluteString,
                                        model: "", loginMethod: .chatgpt, apiProtocol: "responses", chatGPTClientID: account)
        let cacheTicket = try? ModelServices.capture(ModelService.from(cacheSnapshot), requireExisting: false)
        let request = ChatGPTCatalogRequest(account: account, validateIntent: validateIntent, validateRoute: network.validate)
        let result = try await request.load(token: token) { request, credentialCheck in
            try await ChatGPTPlanSession.fetch(request, proxy: network.configuration, validateRoute: network.validate,
                                               validateCredential: credentialCheck)
        }
        try result.validatePublication()
        let available = result.models
        models = available
        // Public cache failures must never turn an already verified login into a failure.
        if let cacheTicket {
            do {
                try cacheTicket.validate()
                _ = try ModelServices.remember(cacheSnapshot, models: available.map {
                    ServiceModel(id: $0.slug, name: $0.display_name)
                })
            } catch { /* Keep the authenticated session and the existing public cache. */ }
        }
        if !available.contains(where: { $0.slug == selectedModel }) {
            selectedModel = available.first?.slug ?? ""
            BotSnapshot.resetRecentDefault()
        }
        if available.isEmpty { throw ChatClient.ClientError.message("当前 ChatGPT 账户没有可用模型。") }
    }

    private func safeMessage(_ error: Error, stage: ChatGPTSignInFeedback.Stage? = nil) -> String {
        if error is APIKey.NativeChatGPTSaveError || error is ChatGPTSignInRevision.Changed {
            return error.localizedDescription
        }
        if error is APIKey.KeychainError { return error.localizedDescription }
        if let error = error as? ChatClient.ClientError { return error.localizedDescription }
        if let error = error as? ChatGPTPlanSession.TokenExchangeError { return error.localizedDescription }
        if let stage, let message = ChatGPTSignInFeedback.networkMessage(error, stage: stage) { return message }
        // Token exchanges and browser redirects can carry secrets in their raw errors.
        switch (error as NSError).localizedDescription {
        case "authorization_declined": return "ChatGPT 授权未获同意。"
        case "authorization_expired": return "ChatGPT 登录已超时，请重试。"
        case "authorization_client_mismatch": return "返回的 ChatGPT 注册信息与本次请求不一致。"
        default:
            if let stage { return ChatGPTSignInFeedback.failureMessage(stage: stage, error: error) }
            return "ChatGPT 登录或模型查询未完成，请检查连接后重试。"
        }
    }

    private struct Callback: Decodable {
        let client_id: String
        let form: String
    }

    private struct Discovery: Decodable {
        let issuer: String
        let jwks_uri: String
    }

    private struct Identity: Decodable {
        let sub: String
        let email: String?
    }

    #if os(iOS)
    private struct BrowserPage: Identifiable {
        var id: URL { url }
        let url: URL
    }

    private struct AuthenticationBrowser: UIViewControllerRepresentable {
        let url: URL
        func makeUIViewController(context: Context) -> SFSafariViewController {
            SFSafariViewController(url: url)
        }
        func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    }
    #endif
}

// BEGIN CHATGPT_SIGN_IN_FEEDBACK
enum ChatGPTSignInFeedback {
    static let diagnosticKey = "lastChatGPTSignInFailure"
    enum Stage {
        case callback, tokenExchange, discovery, jwks, identity, save

        var label: String {
            switch self {
            case .callback: "等待浏览器授权返回"
            case .tokenExchange: "交换登录凭证"
            case .discovery: "读取身份验证信息"
            case .jwks: "读取账户签名公钥"
            case .identity: "校验账户身份"
            case .save: "保存登录凭证"
            }
        }

        var progressMessage: String {
            switch self {
            case .callback: "请在浏览器完成 ChatGPT 授权。"
            case .tokenExchange: "浏览器授权已返回，正在交换 ChatGPT 登录凭证…"
            default: "正在\(label)…"
            }
        }
    }

    // Only these typed codes and constant text may reach the feedback.
    // Never use the transport error's URL, description or userInfo.
    static func networkMessage(_ error: Error, stage: Stage) -> String? {
        guard let error = error as? URLError else { return nil }
        let reason: String
        switch error.code {
        case .timedOut: reason = "连接超时"
        case .notConnectedToInternet: reason = "设备未连接互联网"
        case .networkConnectionLost: reason = "连接已中断"
        case .cannotFindHost, .dnsLookupFailed: reason = "无法解析服务地址"
        case .cannotConnectToHost: reason = "无法连接服务"
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            reason = "安全连接验证失败"
        default: return nil
        }
        return "ChatGPT 登录未完成：\(stage.label)时\(reason)（网络错误 \(error.code.rawValue)）。请重试。"
    }

    static func failureMessage(stage: Stage, error: Error? = nil) -> String {
        if let error {
            let value = error as NSError
            if [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(value.domain) {
                return "ChatGPT 登录未完成（\(stage.label)，本地错误 \(value.code)）。请重试。"
            }
        }
        return "ChatGPT 登录未完成（\(stage.label)）。请重试。"
    }

    static func record(_ error: Error, stage: Stage, defaults: UserDefaults = .standard) {
        var record: [String: Any] = ["stage": String(describing: stage), "at": Date().timeIntervalSince1970,
                                     "validationAlgorithm": "ascii-bytes-v1"]
        if let error = error as? APIKey.NativeChatGPTSaveError {
            switch error {
            case .registration(let prefix, let length, let rejected):
                record["category"] = "registration_format"
                record["prefixValid"] = prefix
                record["identifierByteCount"] = length
                record["rejectedScalarValues"] = rejected.map(Int.init)
            case .identity: record["category"] = "unverified_identity"
            case .address: record["category"] = "credential_address"
            }
        } else if error is ChatGPTSignInRevision.Changed {
            record["category"] = "configuration_changed"
        } else if let error = error as? APIKey.KeychainError {
            record["category"] = "keychain"
            record["code"] = Int(error.status)
        } else {
            let value = error as NSError
            let domains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain]
            record["category"] = domains.contains(value.domain) ? value.domain : "other"
            record["code"] = value.code
        }
        defaults.set(record, forKey: diagnosticKey)
    }
}
// END CHATGPT_SIGN_IN_FEEDBACK

/// A missing revision and the UI's empty default both mean "no mutation yet".
/// A real vault change must still stop this authorization before any write.
struct ChatGPTSignInRevision {
    struct Changed: LocalizedError {
        var errorDescription: String? {
            String(localized: "登录期间配置或凭证发生了变化，未覆盖现有授权。请重新登录。")
        }
    }

    private let value: String
    init(defaults: UserDefaults = .standard) {
        value = defaults.string(forKey: APIKey.revisionKey) ?? ""
    }
    func validate(defaults: UserDefaults = .standard) throws {
        guard value == (defaults.string(forKey: APIKey.revisionKey) ?? "") else { throw Changed() }
    }
}
