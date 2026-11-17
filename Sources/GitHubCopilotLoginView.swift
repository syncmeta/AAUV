import SwiftUI

struct GitHubCopilotLoginSection: View {
    let proxy: SingBox
    @AppStorage(APIKey.copilotRevisionKey) private var credentialRevision = ""
    @AppStorage(APIKey.copilotSignOutPendingKey) private var signOutPending = false
    @AppStorage("githubCopilotClientID") private var clientID = ""
    @AppStorage("githubCopilotModel") private var model = ""
    @AppStorage("loginMethod") private var loginMethod = LoginMethod.byok.rawValue
    @State private var expanded = false
    @State private var task: Task<Void, Never>?
    @State private var credentialTask: Task<Void, Never>?
    @State private var loadingCredentials = false
    @State private var credentialReadFailed = false
    @State private var userCode: String?
    @State private var account: String?
    @State private var hasCredentials = false
    @State private var signingOut = false
    @State private var confirmSignOut = false
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Sign in with GitHub Copilot") {
                expanded = true
                if clientID.isEmpty, let configured = Bundle.main.object(forInfoDictionaryKey: "AAUVGitHubClientID") as? String {
                    clientID = configured
                }
                if !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { signIn() }
            }
            .disabled(task != nil || signOutPending)
            if loadingCredentials { ProgressView("正在读取本机钥匙串…") }
            if credentialReadFailed { Button("重新读取钥匙串", action: reloadCredentials) }
            if let account {
                Text("已授权 GitHub 账户 @\(account)").font(.footnote).textSelection(.enabled)
            }
            #if os(iOS)
            Text("直连预览，以账户检查结果为准").font(.footnote).foregroundStyle(.secondary)
            #endif
            if hasCredentials && CopilotClient.available {
                CopilotModelPicker(proxy: proxy, model: $model)
                    .disabled(task != nil)
                    .onChange(of: model) { BotSnapshot.resetRecentDefault() }
                Button(loginMethod == LoginMethod.copilot.rawValue ? "检查 Copilot 访问权限" : "使用 GitHub Copilot",
                       action: activate)
                    .disabled(task != nil)
            } else if hasCredentials {
                Text(CopilotClient.unavailableMessage).font(.footnote)
            }
            if signOutPending {
                Text("本机 Copilot 请求已停止，凭证清理尚未完成。请重试退出。")
                    .font(.footnote)
            }
            if hasCredentials || signOutPending || credentialReadFailed {
                Button(signOutPending ? String(localized: "重试退出本机 Copilot") : String(localized: "退出本机 Copilot…"), role: .destructive) {
                    confirmSignOut = true
                }
                .disabled(task != nil)
            }
            Link("在 GitHub 管理应用授权", destination: URL(string: "https://github.com/settings/applications")!)
            if expanded {
                TextField("GitHub OAuth Client ID", text: $clientID)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(task != nil)
                Text("使用已启用设备授权的 GitHub 应用 Client ID。")
                    .font(.footnote)
                if task == nil {
                    Button("开始 GitHub 设备授权") { signIn() }
                        .disabled(signOutPending || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let userCode {
                Text(userCode).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Link("在 GitHub 输入设备码", destination: GitHubDeviceAuthorization.verificationURL)
            }
            if task != nil && !signingOut { Button("取消") { task?.cancel() } }
            if !feedback.isEmpty { Text(feedback).font(.footnote) }
        }
        .disabled(loadingCredentials)
        .confirmationDialog("退出本机 GitHub Copilot？", isPresented: $confirmSignOut) {
            Button("清除本机 Copilot 凭证", role: .destructive, action: signOut)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止本机 Copilot 请求并清除本机及导入的 Copilot 凭证，保留聊天和机器人。GitHub 上的授权仍需在应用授权页面管理。")
        }
        .onAppear { reloadCredentials() }
        .onChange(of: credentialRevision) { reloadCredentials() }
        .onDisappear { task?.cancel(); credentialTask?.cancel() }
    }

    private func reloadCredentials() {
        credentialTask?.cancel()
        if signOutPending {
            loadingCredentials = false
            credentialReadFailed = false
            account = nil
            hasCredentials = false
            return
        }
        loadingCredentials = true
        if credentialReadFailed { feedback = "" }
        credentialReadFailed = false
        let revision = UserDefaults.standard.string(forKey: APIKey.copilotRevisionKey)
        credentialTask = Task { @MainActor in
            defer { if !Task.isCancelled { loadingCredentials = false } }
            do {
                let credentials = try await APIKey.readInBackground { try APIKey.copilotCredentials() }
                try Task.checkCancellation()
                guard revision == UserDefaults.standard.string(forKey: APIKey.copilotRevisionKey),
                      !UserDefaults.standard.bool(forKey: APIKey.copilotSignOutPendingKey) else { throw CancellationError() }
                account = credentials?.verifiedLogin
                hasCredentials = credentials != nil
            } catch is CancellationError {
                return
            } catch {
                account = nil
                hasCredentials = false
                credentialReadFailed = true
                feedback = error.localizedDescription
            }
        }
    }

    private func signOut() {
        guard task == nil else { return }
        signingOut = true
        feedback = String(localized: "正在清除本机 Copilot 凭证…")
        task = Task { @MainActor in
            defer {
                signingOut = false
                task = nil
                reloadCredentials()
            }
            do {
                try await CopilotSession.signOut()
                account = nil
                hasCredentials = false
                feedback = String(localized: "已退出本机 Copilot。GitHub 上的应用授权未撤销。")
            } catch {
                feedback = String(localized: "未能完全清除本机 Copilot 凭证，请重试退出。")
            }
        }
    }

    private func activate() {
        guard task == nil else { return }
        let previousMethod = loginMethod
        task = Task { @MainActor in
            defer { task = nil }
            await checkAccessAndActivate(replacing: previousMethod)
        }
    }

    private func checkAccessAndActivate(replacing previousMethod: String) async {
        feedback = "正在检查 GitHub Copilot 访问权限…"
        do {
            let authorization = CopilotSession()
            #if os(iOS)
            _ = try await authorization.models(proxy: proxy, selectedModel: model)
            #else
            _ = try await authorization.models(proxy: proxy)
            #endif
            try authorization.validate()
            if loginMethod == previousMethod, loginMethod != LoginMethod.copilot.rawValue {
                loginMethod = LoginMethod.copilot.rawValue
                BotSnapshot.resetRecentDefault()
                #if os(iOS)
                feedback = String(localized: "已完成账户检查并启用 Copilot 直连预览。推理请求仍以 GitHub 接纳结果为准。")
                #else
                feedback = "已启用 GitHub Copilot。"
                #endif
            } else {
                feedback = "已验证 GitHub Copilot 访问权限。"
            }
        } catch {
            feedback = Task.isCancelled ? "已取消检查。" : "Copilot 访问检查失败。\(error.localizedDescription)"
        }
    }

    private func signIn() {
        guard task == nil, !signOutPending else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousMethod = loginMethod
        feedback = "正在向 GitHub 请求设备码…"
        task = Task { @MainActor in
            defer { task = nil; userCode = nil }
            do {
                let previousAuthorization = CopilotSession()
                let route = try proxy.requestRoute()
                let authorization = GitHubDeviceAuthorization(proxy: route.configuration, validateRoute: route.validate)
                let credentials = try await previousAuthorization.withRequest {
                    let grant = try await authorization.begin(clientID: id)
                    try Task.checkCancellation()
                    userCode = grant.userCode
                    feedback = "请在 GitHub 输入设备码并确认授权。"
                    var credentials = try await authorization.finish(grant)
                    let identity = try await authorization.verify(credentials)
                    try route.validate()
                    try previousAuthorization.validate()
                    credentials.verifiedSubject = String(identity.id)
                    credentials.verifiedLogin = identity.login
                    return credentials
                }
                try route.validate()
                try previousAuthorization.validate()
                try APIKey.saveNativeCopilot(credentials)
                account = credentials.verifiedLogin
                hasCredentials = true
                userCode = nil
                if CopilotClient.available {
                    await checkAccessAndActivate(replacing: previousMethod)
                } else {
                    feedback = "凭证已保存到本机钥匙串，可随配置导出。"
                }
            } catch {
                feedback = Task.isCancelled ? "已取消 GitHub 授权。" : error.localizedDescription
            }
        }
    }
}
