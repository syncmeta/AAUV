import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let proxy: SingBox
    let store: ConversationStore
    let cloudSync: CloudSync
    var destination: PendingSettingsDestination = .all
    var embedded = false
    var onEditingVisibilityChange: ((UUID, Bool) -> Void)? = nil
    @State private var editorID = UUID()
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.default.rawValue
    #if os(macOS)
    @AppStorage("mac_message_privacy_background") private var backgroundPrivacy = false
    #endif
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = false
    @AppStorage("endpoint") private var endpoint = "https://api.openai.com/v1"
    @AppStorage("model") private var model = ""
    @AppStorage("apiProtocol") private var apiProtocol = "responses"
    @AppStorage(APIKey.revisionKey) private var credentialRevision = ""
    @AppStorage("loginMethod") private var loginMethod = LoginMethod.byok.rawValue
    @AppStorage("contextThreshold") private var contextThreshold = 100000
    @AppStorage("contextHours") private var contextHours = 24
    @AppStorage("contextSamples") private var contextSamples = 10
    @AppStorage(ConversationTitleRequest.enabledKey) private var automaticTitles = false
    @AppStorage(LocalToolPreference.enabledKey) private var localToolsEnabled = true
    @Environment(\.dismiss) private var dismiss
    @State private var draftEndpoint = ""
    @State private var draftModel = ""
    @State private var draftProtocol = "responses"
    @State private var webSearch = false
    @State private var codeInterpreter = false
    @State private var imageGeneration = false
    @State private var instructions = BotInstructions()
    @State private var originalInstructions = BotInstructions()
    @State private var instructionFeedback = ""
    @State private var key = ""
    @State private var keyTask: Task<Void, Never>?
    @State private var loadingKey = false
    @State private var keyReadFailed = false
    @State private var keyEdited = false
    @State private var feedback = ""
    @State private var importing = false
    @State private var proxyError: String?
    @State private var confirmCloudRecovery = false

    var body: some View {
        Group {
            if embedded {
                settingsForm
            } else {
                NavigationStack {
                    settingsForm
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                }
            }
        }
        .confirmationDialog("用本机记录恢复 iCloud 同步？", isPresented: $confirmCloudRecovery) {
            Button("恢复同步") { Task { await cloudSync.restoreFromLocal() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("AAUV 会在原 iCloud 账户下重新上传本机的会话、附件、机器人和提示词。")
        }
        .onAppear {
            onEditingVisibilityChange?(editorID, true)
            do {
                instructions = try store.readInstructions()
                originalInstructions = instructions
            }
            catch { instructionFeedback = error.localizedDescription }
            draftEndpoint = endpoint
            draftModel = model
            draftProtocol = apiProtocol
            loadKey()
        }
        .onChange(of: endpoint) { draftEndpoint = endpoint }
        .onChange(of: model) { draftModel = model }
        .onChange(of: apiProtocol) { draftProtocol = apiProtocol }
        .onChange(of: credentialRevision) { loadKey() }
        .onChange(of: draftEndpoint) { loadKey() }
        .onDisappear {
            keyTask?.cancel()
            onEditingVisibilityChange?(editorID, false)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task { @MainActor in
                do {
                    proxyError = nil
                    let file = try result.get()
                    let scoped = file.startAccessingSecurityScopedResource()
                    defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                    try await proxy.start(with: Data(contentsOf: file))
                } catch is CancellationError {
                    return
                } catch {
                    proxyError = error.localizedDescription
                }
            }
        }
    }

    private var settingsForm: some View {
        Form {
                if shows(.providers) {
                    Group {
                    Section("登录") {
                        ChatGPTLoginSection(proxy: proxy, referencedRegistrations: SyncedChatGPTEnrollment.references(
                            bots: store.bots, conversations: store.conversations
                        ))
                        GitHubCopilotLoginSection(proxy: proxy)
                    }
                    Section("模型服务") {
                        NavigationLink("已保存的服务与模型", value: PendingSettingsSubpage.modelServices)
                    }
                    Section("默认 BYOK 服务") {
                        TextField("Base URL", text: $draftEndpoint)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()
                        TextField("模型名称", text: $draftModel)
                            .autocorrectionDisabled()
                        Picker("API", selection: $draftProtocol) {
                            Text("Responses API").tag("responses")
                            Text("Chat Completions").tag("chat_completions")
                            if draftProtocol == "anthropic_messages" {
                                Text("Anthropic Messages（预留）").tag("anthropic_messages")
                            }
                        }
                        if draftProtocol == "responses" {
                            Toggle("网页搜索", isOn: $webSearch)
                                .disabled(loadingKey)
                            Toggle("云端代码解释器", isOn: $codeInterpreter)
                                .disabled(loadingKey)
                            Toggle("云端生图", isOn: $imageGeneration)
                                .disabled(loadingKey)
                            Text("工具由所选模型服务运行，支持情况取决于服务和模型。").font(.footnote)
                        }
                        SecureField("API Key", text: Binding(
                            get: { key },
                            set: {
                                keyTask?.cancel()
                                loadingKey = false
                                keyEdited = true
                                key = $0
                            }
                        ))
                        if loadingKey { ProgressView("正在读取本机钥匙串…") }
                        if keyReadFailed { Button("重新读取钥匙串", action: loadKey) }
                        Button("保存 API 设置") { save() }
                            .disabled(loadingKey || (keyReadFailed && !keyEdited))
                        if !feedback.isEmpty { Text(feedback).font(.footnote) }
                    }
                }
                .disabled(store.configurationUnavailable)
                }
                if shows(.data) { PortableDataView(store: store) }
                Group {
                    if shows(.cloud) {
                    Section("iCloud") {
                        Toggle("iCloud 自动同步", isOn: $cloudSyncEnabled)
                        Text(cloudSync.status).font(.footnote)
                        if let checked = cloudSync.lastCheckCompletedAt {
                            HStack {
                                Text("上次检查")
                                Text(checked, format: .dateTime.month().day().hour().minute())
                            }.font(.footnote).foregroundStyle(.secondary)
                        }
                        if let received = cloudSync.lastRemoteUpdateAt {
                            HStack {
                                Text("上次接收更新")
                                Text(received, format: .dateTime.month().day().hour().minute())
                            }.font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("同步会话、附件、机器人、提示词、个人资料及保存的服务和模型列表。Key 和登录凭证只保存在本机。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let issue = store.publicPreferencesError {
                            Text(issue).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let repair = cloudSync.attachmentRepairStatus { Text(repair).font(.footnote) }
                        if cloudSync.recoveryRequired {
                            Button("用本机记录恢复 iCloud 同步…") { confirmCloudRecovery = true }
                                .disabled(!cloudSyncEnabled || cloudSync.busy)
                        } else {
                            Button("立即同步") { Task { await cloudSync.syncNow() } }
                                .disabled(!cloudSyncEnabled || cloudSync.busy || cloudSync.waitingToRetry || cloudSync.syncLocked)
                        }
                    }
                    }
                    if shows(.all) {
                    Section("机器人") {
                        NavigationLink("管理机器人") {
                            BotProfilesView(store: store, proxy: proxy, onEditingVisibilityChange: onEditingVisibilityChange)
                        }
                        NavigationLink("模型用量") { ModelUsageView(store: store) }
                    }
                    }
                    if shows(.conversation) {
                    Section("会话") {
                        Toggle("用云端模型生成会话标题", isOn: $automaticTitles)
                        Text("新会话在首轮和每三轮回复后，可用当前模型根据少量近期文本拟标题。此操作会产生额外用量。手动命名后保留该标题。")
                            .font(.footnote)
                    }
                    }
                    if shows(.instructions) {
                    Section("共享提示词与技能") {
                        Toggle("允许机器人使用本机工具", isOn: Binding(
                            get: { localToolsEnabled }, set: { LocalToolPreference.save($0) }
                        ))
                        Text("机器人可检索当前会话历史、保存技能、读取历史附件、委托云端模型和贴图。工具的可用性取决于所选模型服务。")
                            .font(.footnote)
                        InstructionsEditor(instructions: $instructions)
                        Button("保存提示词与技能") {
                            do {
                                try store.saveInstructions(instructions, expected: originalInstructions)
                                originalInstructions = instructions
                                instructionFeedback = "已保存。下次请求生效。"
                            } catch { instructionFeedback = error.localizedDescription }
                        }
                        if !instructionFeedback.isEmpty { Text(instructionFeedback).font(.footnote) }
                    }
                    }
                    if shows(.context) {
                    Section("上下文与压缩") {
                        Text("超过 \(contextThreshold) 字时压缩，保留最近 \(contextThreshold * 3 / 10) 字原文")
                        Slider(value: Binding(get: { Double(contextThreshold) }, set: { contextThreshold = Int($0) }),
                               in: 10000...200000, step: 5000)
                            .accessibilityLabel("压缩字数阈值，保留字数按三成联动")
                        Stepper("时间窗口：\(contextHours) 小时", value: $contextHours, in: 1...168)
                        Stepper("每组随机抽样：\(contextSamples) 条", value: $contextSamples, in: 0...50)
                        Text("两组分别从被压缩原文和更早历史抽取。边界消息按字数切分，原文完整保存在本机。下一轮门槛按摘要和未压缩原文计数。样本和附件额外占用模型上下文。压缩会调用当前云端模型。")
                            .font(.footnote)
                        Button("恢复默认上下文设置") {
                            contextThreshold = 100000; contextHours = 24; contextSamples = 10
                        }
                    }
                    }
                    if shows(.proxy) {
                    ProxyNodeView(proxy: proxy)
                    Section("sing-box") {
                        Text(proxy.status)
                        if let proxyError { Text(proxyError).font(.footnote) }
                        Text(SingBox.instructions).font(.footnote)
                        Button("导入配置并启动…") { importing = true }
                            .disabled(proxy.canStop)
                        Button("停止", role: .destructive) { proxy.stop() }
                            .disabled(!proxy.canStop)
                        Button("使用系统网络") { proxy.reset() }
                            .disabled(proxy.canStop)
                    }
                    }
                }
                .disabled(store.configurationUnavailable)
                if shows(.appearance) { appearanceSection }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(destination.title)
        .navigationDestination(for: PendingSettingsSubpage.self) { page in
            switch page {
            case .modelServices:
                ModelServicesManager(store: store, proxy: proxy,
                                     onEditingVisibilityChange: onEditingVisibilityChange)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
    }

    private func shows(_ section: PendingSettingsDestination) -> Bool {
        destination == .all || destination == section
    }


    @ViewBuilder private var appearanceSection: some View {
        #if os(macOS)
        Section {
            Toggle("切换到后台时遮盖对话", isOn: $backgroundPrivacy)
        } header: { Text("消息隐私") } footer: {
            Text("遮盖聊天正文和输入区；回到前台自动恢复。手动开启的遮盖不会自动关闭。此设置仅保存在本机，不遮盖侧栏预览或独立弹窗，也不防止系统截图。")
        }
        #endif
        Section {
            Picker("外观", selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: { Text("外观") } footer: {
            Text("「跟随系统」随设备的浅色/深色自动切换；也可固定为浅色或深色。")
        }
    }

    private func loadKey() {
        guard shows(.providers) else { return }
        keyTask?.cancel()
        key = ""
        feedback = ""
        webSearch = false
        codeInterpreter = false
        imageGeneration = false
        loadingKey = false
        keyReadFailed = false
        keyEdited = false
        guard let url = try? ChatClient.baseURL(draftEndpoint) else { return }
        loadingKey = true
        keyTask = Task { @MainActor in
            defer { if !Task.isCancelled { loadingKey = false } }
            do {
                let snapshot = try await APIKey.readInBackground {
                    let key = try APIKey.read(for: url)
                    let tools = DefaultHostedTools.byok(at: url.absoluteString, imported: try APIKey.importedConfiguration())
                    return (key, tools)
                }
                try Task.checkCancellation()
                key = snapshot.0
                webSearch = snapshot.1.contains(HostedTool.webSearch.rawValue)
                codeInterpreter = snapshot.1.contains(HostedTool.codeInterpreter.rawValue)
                imageGeneration = snapshot.1.contains(HostedTool.imageGeneration.rawValue)
            } catch is CancellationError {
                return
            } catch {
                keyReadFailed = true
                feedback = error.localizedDescription
            }
        }
    }

    private func save() {
        guard !loadingKey, !store.configurationUnavailable, store.loadError == nil,
              !keyReadFailed || keyEdited else { return }
        do {
            try APIKey.checkNoPendingConfigurationImport()
            let url = try ChatClient.baseURL(draftEndpoint)
            let snapshot = BotSnapshot(name: draftModel, endpoint: url.absoluteString,
                                       model: draftModel, loginMethod: .byok, apiProtocol: draftProtocol)
            var service = try ModelService.from(snapshot).validated()
            let saved = try ModelServices.load()
            if let previous = saved.first(where: { $0.id == service.id }) {
                service.name = previous.name
                service.models = try ModelService.validatedModels(previous.models + service.models)
            }
            let publicData = try JSONEncoder().encode(ModelService.validateBatch(saved.filter { $0.id != service.id } + [service]))
            guard publicData.count <= 4 * 1024 * 1024 else {
                throw ChatClient.ClientError.message(String(localized: "模型服务配置过大，请减少模型数量。"))
            }
            try APIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: url)
            var tools: [String] = []
            if webSearch { tools.append(HostedTool.webSearch.rawValue) }
            if codeInterpreter { tools.append(HostedTool.codeInterpreter.rawValue) }
            if imageGeneration { tools.append(HostedTool.imageGeneration.rawValue) }
            DefaultHostedTools.saveBYOK(tools, at: url.absoluteString)
            endpoint = url.absoluteString
            model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
            apiProtocol = draftProtocol
            loginMethod = LoginMethod.byok.rawValue
            BotSnapshot.resetRecentDefault()
            _ = try ModelServices.remember(snapshot)
            keyReadFailed = false
            feedback = "已保存到本机。"
        } catch { feedback = error.localizedDescription }
    }
}
