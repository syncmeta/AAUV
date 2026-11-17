import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PortableSettings: Codable, Sendable {
    static let maximumFileBytes = 64 * 1024 * 1024

    var version = 4
    var endpoint: String
    var model: String
    var offline: Bool?
    var format: String? = "aauv-config"
    var loginMethod: LoginMethod?
    var key: String?
    var nodeLinks: [String]?
    var oauth: OAuthCredentials?
    var apiProtocol: String?
    var hostedTools: [String]?
    var contextPolicy: ContextPolicy?
    var realtimeModel: String?
    var automaticConversationTitles: Bool?
    var botInstructions: BotInstructions?
    var bots: [LocalBot]?
    var credentials: PortableCredentials?
    var providerDefaults: ProviderDefaults?
    var localToolsEnabled: Bool?
    var defaultBotSelection: DefaultBotSelection?
    var selectedProxyNode: String?
    var proxyRequiresTunnel: Bool?
    var githubCopilotClientID: String?
    var cloudSyncEnabled: Bool?
    var localProfile: LocalDisplayProfile?
    var modelServices: [ModelService]?

    var appPreferences: PortableAppPreferences {
        .init(selectedProxyNode: selectedProxyNode, proxyRequiresTunnel: proxyRequiresTunnel,
              githubCopilotClientID: githubCopilotClientID, cloudSyncEnabled: cloudSyncEnabled,
              localProfile: localProfile, modelServices: modelServices)
    }

    func validated() throws -> Self {
        guard [1, 2, 3, 4].contains(version), format == nil || format == "aauv-config" else {
            throw ChatClient.ClientError.message("不支持这个配置版本。")
        }
        if let botInstructions { _ = try botInstructions.validated() }
        if let contextPolicy { _ = try contextPolicy.validated() }
        var copy = self
        let preferences = try appPreferences.validated()
        copy.selectedProxyNode = preferences.selectedProxyNode
        copy.proxyRequiresTunnel = preferences.proxyRequiresTunnel
        copy.githubCopilotClientID = preferences.githubCopilotClientID
        copy.cloudSyncEnabled = preferences.cloudSyncEnabled
        copy.localProfile = preferences.localProfile
        copy.modelServices = preferences.modelServices
        if let defaultBotSelection { copy.defaultBotSelection = try defaultBotSelection.validated() }
        if let realtimeModel { copy.realtimeModel = try RealtimeVoice.modelName(realtimeModel) }
        if let bots { copy.bots = try LocalBot.validateBatch(bots) }
        copy.apiProtocol = apiProtocol ?? (version < 3 ? "chat_completions" : "responses")
        guard ["responses", "chat_completions", "anthropic_messages"].contains(copy.apiProtocol!),
              (hostedTools ?? []).allSatisfy({ HostedTool(rawValue: $0) != nil }) else {
            throw ChatClient.ClientError.message("不支持的 API 或托管工具。")
        }
        if let oauth {
            guard oauth.flow != .codex else {
                throw ChatClient.ClientError.message("此配置包含 Codex CLI 授权。请导入通过 ChatGPT 登录后导出的 OAuth 凭证。")
            }
            try oauth.validateStructure()
            guard loginMethod == nil || loginMethod == oauth.loginMethod else {
                throw ChatClient.ClientError.message("OAuth 凭证与所选登录方式不匹配。")
            }
            copy.loginMethod = oauth.loginMethod
        }
        copy.endpoint = try ChatClient.baseURL(endpoint).absoluteString
        switch copy.loginMethod {
        case .chatgpt: copy.endpoint = ChatGPTPlanSession.endpoint.absoluteString
        case .copilot: copy.endpoint = "https://github.com"
        case .byok, nil: break
        }
        if let nodeLinks { copy.nodeLinks = try ProxyNodes.normalize(nodeLinks) }
        if let providerDefaults { copy.providerDefaults = try providerDefaults.validated() }
        if let credentials { copy.credentials = try credentials.validated() }
        _ = try copy.loginCredentials()
        return copy
    }

    static func readFile(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result {
                let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard properties.isRegularFile == true, let size = properties.fileSize else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard size <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
                let file = try FileHandle(forReadingFrom: source)
                defer { try? file.close() }
                var bytes = Data()
                while let part = try file.read(upToCount: min(256 * 1024, maximumFileBytes + 1 - bytes.count)), !part.isEmpty {
                    bytes.append(part)
                    guard bytes.count <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
                }
                return bytes
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

struct ProviderDefaults: Codable, Sendable {
    var byokEndpoint: String?
    var byokModel: String?
    var byokProtocol: String?
    var chatGPTModel: String?
    var copilotModel: String?
    var byokHostedTools: [String]?
    var chatGPTHostedTools: [String]?

    func validated() throws -> Self {
        var copy = self
        if let byokEndpoint { copy.byokEndpoint = try ChatClient.baseURL(byokEndpoint).absoluteString }
        guard byokProtocol.map({ ["responses", "chat_completions", "anthropic_messages"].contains($0) }) ?? true,
              [byokModel, chatGPTModel, copilotModel].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }),
              (byokHostedTools ?? []).allSatisfy({ HostedTool(rawValue: $0) != nil }),
              (chatGPTHostedTools ?? []).allSatisfy({ $0 == HostedTool.webSearch.rawValue }) else {
            throw ChatClient.ClientError.message("配置中的服务商默认模型或协议无效。")
        }
        copy.byokHostedTools = byokHostedTools.map { HostedTool.supported($0, by: .byok) }
        copy.chatGPTHostedTools = chatGPTHostedTools.map { HostedTool.supported($0, by: .chatgpt) }
        return copy
    }
}

struct PortableArchive: Codable {
    var version = 1
    var conversations: [Conversation]
    var files: [String: Data]?
    var bots: [LocalBot]?
    var instructions: BotInstructions?
    var settings: BackupSettings?
}

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PortableDataView: View {
    let store: ConversationStore
    @AppStorage(APIKey.revisionKey) private var credentialRevision = ""
    @AppStorage(APIKey.copilotRevisionKey) private var copilotCredentialRevision = ""
    @AppStorage("endpoint") private var endpoint = "https://api.openai.com/v1"
    @AppStorage("model") private var model = ""
    @AppStorage("githubCopilotModel") private var githubCopilotModel = ""
    @AppStorage("realtimeModel") private var realtimeModel = RealtimeVoice.defaultModel
    @AppStorage(ConversationTitleRequest.enabledKey) private var automaticTitles = false
    @AppStorage("apiProtocol") private var apiProtocol = "responses"
    @AppStorage("loginMethod") private var loginMethod = LoginMethod.byok.rawValue
    @State private var importing = false
    @State private var includeKey = false
    @State private var exportMethod: LoginMethod?
    var incomingDocument: FileOpenRequest? = nil
    var sharedImportID: UUID? = nil
    @State private var incomingImportFinished = false
    @State private var exporting = false
    @State private var configurationOnly = true
    @State private var document = JSONDocument(data: Data())
    @State private var exportingBackup = false
    @State private var backupFile: BackupFile?
    @State private var workingBackup = false
    @State private var backupIncludesSettings = true
    @State private var importOptions = false
    @State private var importLink = ""
    @State private var readingConfiguration = false
    @State private var configurationMessage = ""
    @State private var exportedLink: String?
    @State private var message = ""
    @State private var exportCoordinator = PortableExportCoordinator()
    @State private var preparingExport = false
    @State private var exportedGuard: (@MainActor @Sendable () throws -> Void)?
    @State private var pendingSettings: PortableSettings?
    @State private var pendingNode: String?
    @State private var pendingNodeName = ""
    @State private var pendingArchive: PreparedBackup?
    @State private var confirmingBackup = false

    var body: some View {
        Section("配置与数据") {
            if incomingDocument == nil {
                importExportControls
            } else {
                if let settings = pendingSettings {
                    Text(configurationPreview(settings)).textSelection(.enabled)
                    Button("导入配置", action: applyPending)
                        .disabled(!PortableSettingsExport.allowsMutation(in: store))
                } else if let backup = pendingArchive {
                    Text(backupPreview(backup.archive)).textSelection(.enabled)
                    backupRestoreActions(backup)
                } else if !incomingImportFinished {
                    if sharedImportID != nil {
                        Text("待导入文件会保留到导入成功或手动移除。").font(.footnote)
                    }
                    Button("预览待导入文件", action: prepareIncoming)
                        .disabled(workingBackup || readingConfiguration || store.restoringBackup)
                }
                if workingBackup { ProgressView(store.restoringBackup ? "正在恢复备份…" : "正在读取备份…") }
                if readingConfiguration { ProgressView("正在读取配置…") }
                if !configurationMessage.isEmpty { Text(configurationMessage).font(.footnote).textSelection(.enabled) }
                if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
            }
        }
        .onChange(of: includeKey) { invalidateExport() }
        .onChange(of: exportMethod) { invalidateExport() }
        .onChange(of: credentialRevision) { invalidateExport() }
        .onChange(of: copilotCredentialRevision) { invalidateExport() }
        .onChange(of: backupIncludesSettings) { invalidateExport() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            validateRenderedExport()
        }
        .onDisappear { invalidateExport() }
        .onAppear(perform: prepareIncoming)
        .fileImporter(isPresented: $importing, allowedContentTypes: configurationOnly
                      ? [.json, UTType(filenameExtension: "aauv") ?? .data]
                      : [.aauvBackup, .zip, .json]) { result in
            do {
                let url = try result.get()
                if configurationOnly {
                    prepareSettingsFile(url)
                } else {
                    prepareBackup(url)
                }
            } catch {
                if configurationOnly { configurationMessage = error.localizedDescription }
                else { message = error.localizedDescription }
            }
        }
        .alert("应用导入内容？", isPresented: Binding(
            get: { incomingDocument == nil && (pendingSettings != nil || pendingNode != nil) },
            set: { if !$0 && incomingDocument == nil { pendingSettings = nil; pendingNode = nil } }
        )) {
            Button("取消", role: .cancel) { pendingSettings = nil; pendingNode = nil }
            Button("导入") { applyPending() }
                .disabled(!PortableSettingsExport.allowsMutation(in: store))
        } message: {
            if pendingNode != nil {
                Text("保存节点 \(pendingNodeName)？")
            } else if let settings = pendingSettings {
                Text(configurationPreview(settings))
            }
        }

    }

    @ViewBuilder private func backupRestoreActions(_ backup: PreparedBackup) -> some View {
        Group {
            Button("仅导入会话和机器人") { restoreBackup(backup, instructions: false, settings: false) }
            if backup.archive.instructions != nil {
                Button("同时恢复共享提示词与技能") { restoreBackup(backup, instructions: true, settings: false) }
            }
            if backup.archive.settings != nil {
                Button("同时恢复应用设置") { restoreBackup(backup, instructions: false, settings: true) }
                if backup.archive.instructions != nil {
                    Button("同时恢复提示词、技能和设置") { restoreBackup(backup, instructions: true, settings: true) }
                }
            }
        }
        .disabled(!PortableSettingsExport.allowsMutation(in: store))
    }

    @ViewBuilder private var importExportControls: some View {
        Button("Paste Link") { importOptions.toggle() }
        if importOptions {
            TextField("粘贴配置或节点链接", text: $importLink, axis: .vertical)
                .lineLimit(1...4)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("预览链接") { prepareLink(importLink) }
                .disabled(importLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || readingConfiguration || workingBackup)
            PasteButton(payloadType: String.self) { values in
                guard let value = values.first else { return }
                importLink = value
                prepareLink(value)
            }
            .disabled(readingConfiguration || workingBackup)
            Button("选择配置文件…") {
                configurationOnly = true
                importing = true
            }
            .disabled(readingConfiguration || workingBackup)
        }
        if readingConfiguration { ProgressView("正在读取配置…") }
        if !configurationMessage.isEmpty { Text(configurationMessage).font(.footnote).textSelection(.enabled) }
        Picker("导出登录方式", selection: $exportMethod) {
            Text("当前设置").tag(LoginMethod?.none)
            Text("ChatGPT").tag(LoginMethod?.some(.chatgpt))
            Text("GitHub Copilot").tag(LoginMethod?.some(.copilot))
            Text("BYOK").tag(LoginMethod?.some(.byok))
        }
        Toggle("导出时包含已使用的 API Key、OAuth 授权和节点链接", isOn: $includeKey)
        if includeKey {
            Text("持有文件或链接的人可以读取其中的凭证。").font(.footnote)
        }
        Button("导出配置文件") { exportSettings() }
            .disabled(includeKey && !PortableSettingsExport.allowsMutation(in: store))
            .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                          defaultFilename: "AAUV.aauv") { result in
                showExportResult(result)
            }
        Button("生成配置链接") { startSettingsExport(.link) }
            .disabled(includeKey && !PortableSettingsExport.allowsMutation(in: store))
        if preparingExport {
            ProgressView("正在准备导出…")
            Button("取消", role: .cancel) { invalidateExport() }
        }
        if let exportedLink {
            Button("复制配置链接") {
                do {
                    try exportedGuard?()
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(exportedLink, forType: .string)
                    message = copied ? "已复制配置链接。" : "无法复制配置链接。"
                    #else
                    UIPasteboard.general.string = exportedLink
                    message = "已复制配置链接。"
                    #endif
                } catch {
                    invalidateExport()
                    if !(error is CancellationError) { message = error.localizedDescription }
                }
            }
        }
        Toggle("备份包含应用设置", isOn: $backupIncludesSettings)
        Button("导出备份…") { exportBackup() }
            .disabled(workingBackup || exportingBackup || store.restoringBackup || store.loadError != nil)
            .fileExporter(isPresented: $exportingBackup, item: backupFile,
                          contentTypes: [.aauvBackup], defaultFilename: "AAUV-backup") { result in
                showExportResult(result)
                backupFile = nil
            } onCancellation: {
                backupFile = nil
            }
        Button("恢复备份…") {
            configurationOnly = false
            importing = true
        }
        .disabled(workingBackup || readingConfiguration || store.restoringBackup || store.loadError != nil)
        .sheet(isPresented: $confirmingBackup, onDismiss: {
            if !confirmingBackup { pendingArchive = nil }
        }) {
            if let backup = pendingArchive {
                NavigationStack {
                    Form {
                        Section {
                            Text(backupPreview(backup.archive)).textSelection(.enabled)
                        }
                        Section {
                            backupRestoreActions(backup)
                        }
                    }
                    .navigationTitle("恢复备份？")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消", role: .cancel) {
                                confirmingBackup = false
                                pendingArchive = nil
                            }
                            .keyboardShortcut(.cancelAction)
                        }
                    }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 420)
                #endif
            }
        }
        if workingBackup { ProgressView("正在处理备份…") }
        Text("导出时可在文件选择器中保存到 iCloud Drive。导入会话以新副本添加。")
            .font(.footnote)
        if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
    }

    private func prepareIncoming() {
        guard !incomingImportFinished, let incomingDocument else { return }
        switch incomingDocument {
        case .configuration(let data):
            prepareSettings { data }
        case .configurationFile(let file):
            prepareSettingsFile(file)
        case .backup(let file):
            message = ""
            prepareBackup(file)
        case .attachment:
            break
        }
    }

    private func applyPending() {
        guard PortableSettingsExport.allowsMutation(in: store) else { return }
        let feedback: String
        do {
            if let node = pendingNode {
                try ProxyNodes.add(node)
            }
            if let settings = pendingSettings {
                try store.applyConfiguration(settings, sharedImportID: sharedImportID)
                incomingImportFinished = incomingDocument != nil
            }
            var notices = ["已导入。"]
            if pendingNode != nil || pendingSettings?.nodeLinks?.isEmpty == false {
                notices.append("节点已保存，可在单节点代理中选择连接。")
            }
            if let settings = pendingSettings, try settings.loginCredentials().oauthCount > 0 {
                notices.append("OAuth 凭证已保存到钥匙串，尚待服务端验证。")
            }
            if !CopilotClient.available,
               pendingSettings?.loginMethod == .copilot || pendingSettings?.credentials?.copilot != nil {
                notices.append(CopilotClient.unavailableMessage)
            }
            if pendingNode != nil || pendingSettings != nil {
                importLink = ""
                exportedLink = nil
            }
            feedback = notices.joined(separator: " ")
        } catch { feedback = error.localizedDescription }
        configurationMessage = feedback
        pendingSettings = nil
        pendingNode = nil
    }

    private func restoreBackup(_ backup: PreparedBackup, instructions: Bool, settings: Bool) {
        guard !workingBackup, PortableSettingsExport.allowsMutation(in: store) else { return }
        confirmingBackup = false
        pendingArchive = nil
        workingBackup = true
        message = ""
        Task { @MainActor in
            defer { workingBackup = false }
            do {
                try await store.importBackup(backup, restoreInstructions: instructions, restoreSettings: settings,
                                             sharedImportID: sharedImportID)
                incomingImportFinished = incomingDocument != nil
                message = "备份已恢复。"
                exportedLink = nil
            } catch { message = error.localizedDescription }
        }
    }

    private func backupPreview(_ backup: PortableArchive) -> String {
        var lines = ["添加 \(backup.conversations.count) 个会话副本和 \(backup.bots?.count ?? 0) 个机器人副本。"]
        if backup.instructions != nil { lines.append("可用备份中的共享提示词和技能替换本机版本。") }
        if let settings = backup.settings, let config = try? settings.portableSettings() {
            lines.append("可恢复 \(settings.loginMethod.rawValue) 默认服务、模型 \(config.model.isEmpty ? "未设置" : config.model)、托管工具和上下文设置。")
            if let automaticTitles = config.automaticConversationTitles {
                lines.append(automaticTitles ? "恢复设置后会开启云端模型生成会话标题。" : "恢复设置后会关闭云端模型生成会话标题。")
            }
            if settings.loginMethod == .copilot && !CopilotClient.available {
                lines.append("此设备会保留当前聊天服务，并记住备份中的 Copilot 模型选择。")
            }
            lines.append(settings.defaultBotSelection?.preview(bots: backup.bots ?? []) ?? "保留本机最近机器人选择。")
            lines += settings.appPreferences.preview
        }
        return lines.joined(separator: "\n")
    }

    private func configurationPreview(_ settings: PortableSettings) -> String {
        let credentials = try? settings.loginCredentials()
        let method = settings.loginMethod ?? .byok
        let model = settings.model.isEmpty ? (method == .copilot ? "服务默认模型" : "未设置") : settings.model
        let known = Set(store.bots.map(\.id))
        let bots = settings.bots ?? []
        let updated = bots.filter { known.contains($0.id) }.count
        var lines = ["\(method.rawValue) · \(settings.endpoint)\n模型：\(model)"]
        let selectionBots = store.bots.filter { existing in !bots.contains(where: { $0.id == existing.id }) } + bots
        lines.append(settings.defaultBotSelection?.preview(bots: selectionBots) ?? "保留本机最近机器人选择。")
        lines += settings.appPreferences.preview
        if method == .copilot && !CopilotClient.available {
            lines.append("此设备可保存 Copilot 授权，聊天继续使用当前服务。")
        }
        if !bots.isEmpty { lines.append("新增 \(bots.count - updated) 个机器人，更新 \(updated) 个已有机器人。") }
        if settings.botInstructions != nil { lines.append("共享提示词和技能将替换为配置中的版本。") }
        if let policy = settings.contextPolicy {
            lines.append("上下文调整为 \(policy.hours) 小时，\(policy.threshold) 字触发压缩，每组抽样 \(policy.samples) 条。")
        }
        if let automaticTitles = settings.automaticConversationTitles {
            lines.append(automaticTitles ? "开启云端模型生成会话标题。" : "关闭云端模型生成会话标题。")
        }
        if let nodes = settings.nodeLinks, !nodes.isEmpty { lines.append("合并 \(nodes.count) 个单节点链接。") }
        if let credentials, !credentials.isEmpty {
            lines.append("含 \(credentials.byokCount) 个 API Key 和 \(credentials.oauthCount) 份 OAuth 授权。相同地址或注册的凭证将更新。")
        }
        return lines.joined(separator: "\n\n")
    }

    private func invalidateExport() {
        let previous = exportCoordinator.cancel()
        preparingExport = false
        if previous == .backup && !store.restoringBackup { workingBackup = false }
        exportedLink = nil
        exportedGuard = nil
        document = JSONDocument(data: Data())
        exporting = false
        exportingBackup = false
        backupFile = nil
    }

    private func validateRenderedExport() {
        guard let exportedGuard else { return }
        do { try exportedGuard() } catch { invalidateExport() }
    }

    private func exportSettings() { startSettingsExport(.configurationFile) }

    private func startSettingsExport(_ kind: PortableExportCoordinator.Kind) {
        invalidateExport()
        let coordinator = exportCoordinator
        let ticket = coordinator.begin(kind)
        let target = store
        let method = exportMethod
        let includesCredentials = includeKey
        let snapshot: PortableSettingsExport.Snapshot
        do {
            try PortableSettingsExport.validateAccess(to: target, includeCredentials: includesCredentials)
            snapshot = try PortableSettingsExport.snapshot(store: target, method: method)
        } catch {
            coordinator.finish(ticket)
            message = error.localizedDescription
            return
        }
        preparingExport = true
        let task = Task { @MainActor in
            defer {
                if coordinator.isCurrent(ticket) { preparingExport = false; coordinator.finish(ticket) }
            }
            do {
                let prepared = try await PortableSettingsExport.prepare(snapshot, includeCredentials: includesCredentials) {
                    try coordinator.validate(ticket)
                    try PortableSettingsExport.validateAccess(to: target, includeCredentials: includesCredentials)
                }
                let check: @MainActor @Sendable () throws -> Void = {
                    try prepared.validate()
                    let current = try PortableSettingsExport.snapshot(store: target, method: method)
                    guard try snapshot.samePublicSettings(as: current) else { throw PortableSettingsExport.Failure.changed }
                }
                try check()
                if kind == .configurationFile {
                    document = JSONDocument(data: prepared.data)
                    exporting = true
                } else {
                    exportedLink = try ConfigurationLink.encode(prepared.data)
                    message = includesCredentials ? "链接包含登录或节点凭证，持有链接的人可以读取。压缩编码不提供加密。" : "已生成配置链接。"
                }
                exportedGuard = check
            } catch {
                if coordinator.isCurrent(ticket) {
                    exportedLink = nil; exportedGuard = nil; document = JSONDocument(data: Data()); exporting = false
                    if !(error is CancellationError) { message = error.localizedDescription }
                }
            }
        }
        coordinator.attach(task, to: ticket)
    }

    private func exportBackup() {
        guard !workingBackup, !store.restoringBackup else { return }
        invalidateExport()
        let coordinator = exportCoordinator
        let ticket = coordinator.begin(.backup)
        let snapshot: PortableArchive
        do {
            try PortableSettingsExport.validateAccess(to: store, includeCredentials: false)
            let method = LoginMethod(rawValue: loginMethod) ?? .byok
            let settings = backupIncludesSettings
                ? try PortableSettingsExport.publicBackupSettings(method: method, bots: store.bots) : nil
            snapshot = try store.backupSnapshot(settings: settings)
        } catch {
            coordinator.finish(ticket)
            message = error.localizedDescription
            return
        }
        let attachments = store.attachmentDirectory
        workingBackup = true
        let task = Task { @MainActor in
            defer {
                if coordinator.isCurrent(ticket) { workingBackup = false; coordinator.finish(ticket) }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let result = try BackupFile.create(snapshot: snapshot, attachments: attachments)
                    try Task.checkCancellation()
                    return result
                }
                let file = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try coordinator.validate(ticket)
                try PortableSettingsExport.validateAccess(to: store, includeCredentials: false)
                backupFile = file
                exportingBackup = true
            } catch {
                if coordinator.isCurrent(ticket), !(error is CancellationError) { message = error.localizedDescription }
            }
        }
        coordinator.attach(task, to: ticket)
    }

    private func prepareBackup(_ url: URL) {
        guard !workingBackup, !readingConfiguration, !store.restoringBackup else { return }
        workingBackup = true
        Task { @MainActor in
            defer { workingBackup = false }
            do {
                let backup = try await Task.detached {
                    let backup = try PreparedBackup.read(url)
                    try backup.validate()
                    return backup
                }.value
                pendingArchive = backup
                confirmingBackup = incomingDocument == nil
            } catch { message = error.localizedDescription }
        }
    }

    private func showExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success: message = "已导出。"
        case .failure(let error): message = error.localizedDescription
        }
    }

    private func prepareLink(_ input: String) {
        guard !workingBackup, !readingConfiguration else { return }
        configurationMessage = ""
        do {
            let link = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if ProxyNodes.recognizes(link) {
                let description = try ProxyNodes.inspect(link)
                pendingNodeName = description.name
                pendingNode = link
            } else {
                pendingSettings = try PortableSettings.decode(ConfigurationLink.decode(link))
            }
        } catch { configurationMessage = error.localizedDescription }
    }

    private func prepareSettingsFile(_ url: URL) {
        prepareSettings { try PortableSettings.readFile(url) }
    }

    private func prepareSettings(read: @escaping @Sendable () throws -> Data) {
        guard !readingConfiguration, !workingBackup else { return }
        readingConfiguration = true
        configurationMessage = ""
        Task { @MainActor in
            defer { readingConfiguration = false }
            do {
                pendingSettings = try await Task.detached(priority: .userInitiated) {
                    try PortableSettings.decode(read())
                }.value
            } catch { configurationMessage = error.localizedDescription }
        }
    }
}
