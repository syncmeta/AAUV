import SwiftUI

enum PendingBotDestination: Hashable {
    case new
    case existing(UUID)
}

struct BotProfilesView: View {
    let store: ConversationStore
    let proxy: SingBox
    var selection: Binding<PendingBotDestination?>? = nil
    var onChat: ((BotSnapshot) -> Void)? = nil
    var onEditingVisibilityChange: ((UUID, Bool) -> Void)? = nil
    @State private var deleting: LocalBot?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            PendingTabHeaderBar(title: "机器人") {
                if let selection {
                    Button { selection.wrappedValue = .new } label: {
                        PendingHeaderActionIcon(systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建机器人")
                } else {
                    NavigationLink(value: PendingBotDestination.new) {
                        PendingHeaderActionIcon(systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建机器人")
                }
            }
            List {
                if store.bots.isEmpty {
                    PendingEmptyHint(text: "还没有保存的机器人。")
                }
                ForEach(store.bots) { bot in
                    botRow(bot)
                }
                if let failure { Text(failure).foregroundStyle(Theme.Palette.danger) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(for: PendingBotDestination.self) { target in
            editor(target)
        }
        .disabled(store.configurationUnavailable || store.loadError != nil)
        .alert("删除此机器人？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { bot in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard !store.configurationUnavailable, store.loadError == nil else { return }
                do { try store.deleteBot(bot.id) }
                catch { failure = error.localizedDescription }
            }
        } message: { _ in
            Text("现有会话仍可使用已保存的机器人配置。")
        }
    }

    @ViewBuilder private func botRow(_ bot: LocalBot) -> some View {
        Group {
            if let onChat {
                Button { onChat(bot.snapshot) } label: {
                    PendingBotRow(id: bot.id, name: bot.configuration.name, model: bot.configuration.model)
                }.buttonStyle(.plain)
            } else if let selection {
                Button { selection.wrappedValue = .existing(bot.id) } label: {
                    PendingBotRow(id: bot.id, name: bot.configuration.name, model: bot.configuration.model)
                }.buttonStyle(.plain)
            } else {
                NavigationLink(value: PendingBotDestination.existing(bot.id)) {
                    PendingBotRow(id: bot.id, name: bot.configuration.name, model: bot.configuration.model)
                }.buttonStyle(.plain)
            }
        }
        .contextMenu {
            if let selection {
                Button("编辑机器人") { selection.wrappedValue = .existing(bot.id) }
            } else {
                NavigationLink("编辑机器人", value: PendingBotDestination.existing(bot.id))
            }
            Button("删除机器人", role: .destructive) { deleting = bot }
        }
    }

    @ViewBuilder private func editor(_ target: PendingBotDestination) -> some View {
        switch target {
        case .new: BotEditor(store: store, proxy: proxy, onEditingVisibilityChange: onEditingVisibilityChange)
        case .existing(let id):
            if let bot = store.bots.first(where: { $0.id == id }) {
                BotEditor(store: store, proxy: proxy, existing: bot, onEditingVisibilityChange: onEditingVisibilityChange)
            } else { Text("这台机器人已删除。") }
        }
    }

}

struct BotEditor: View {
    let store: ConversationStore
    let proxy: SingBox
    let existing: LocalBot?
    let onSaved: (() -> Void)?
    let onEditingVisibilityChange: ((UUID, Bool) -> Void)?
    @State private var editorID = UUID()
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalBot
    @State private var instructions: BotInstructions
    @State private var webSearch: Bool
    @State private var codeInterpreter: Bool
    @State private var imageGeneration: Bool
    @State private var feedback: String?
    @State private var accountBinding = BotChatGPTBinding()
    @State private var accountTask: Task<Void, Never>?
    @State private var services: [ModelService]
    @State private var selectedServiceID: String
    @State private var serviceFailure: String?
    @State private var managingServices = false
    @AppStorage(ModelServices.revisionKey) private var serviceRevision = ""

    init(store: ConversationStore, proxy: SingBox, existing: LocalBot? = nil, onSaved: (() -> Void)? = nil,
         onEditingVisibilityChange: ((UUID, Bool) -> Void)? = nil) {
        self.store = store
        self.proxy = proxy
        self.existing = existing
        self.onSaved = onSaved
        self.onEditingVisibilityChange = onEditingVisibilityChange
        let savedServices: [ModelService]
        let loadFailure: String?
        do { savedServices = try ModelServices.load(); loadFailure = nil }
        catch { savedServices = []; loadFailure = error.localizedDescription }
        var bot = existing ?? LocalBot.makeNew(configuration: .activeDefaults(),
                                               excludingNames: Set(store.bots.map { $0.configuration.name }))
        let originalService = ModelService.from(bot.configuration)
        var serviceID = existing == nil ? "" : originalService.id
        if existing == nil {
            let available = savedServices.filter { $0.loginMethod != .copilot || CopilotClient.available }
            if let selected = available.first(where: { $0.id == originalService.id }) ?? available.first {
                let model = selected.models.contains(where: { $0.id == bot.configuration.model })
                    ? bot.configuration.model : selected.models.first?.id ?? ""
                var configuration = selected.botSnapshot(name: bot.configuration.name, model: model)
                configuration.instructions = bot.configuration.instructions
                configuration.hostedTools = bot.configuration.hostedTools
                bot.configuration = configuration
                serviceID = selected.id
            } else { bot.configuration.model = "" }
        }
        _draft = State(initialValue: bot)
        _instructions = State(initialValue: bot.configuration.instructions ?? BotInstructions())
        _webSearch = State(initialValue: bot.configuration.hostedTools?.contains("web_search") == true)
        _codeInterpreter = State(initialValue: bot.configuration.hostedTools?.contains("code_interpreter") == true)
        _imageGeneration = State(initialValue: bot.configuration.hostedTools?.contains("image_generation") == true)
        _services = State(initialValue: savedServices)
        _selectedServiceID = State(initialValue: serviceID)
        _serviceFailure = State(initialValue: loadFailure)
    }

    private var method: LoginMethod { draft.configuration.loginMethod }
    private var responsesTools: Bool {
        method == .chatgpt || (method == .byok && draft.configuration.apiProtocol == "responses")
    }
    private var savedService: ModelService? { services.first { $0.id == selectedServiceID } }
    private var selectedService: ModelService? {
        if let savedService { return savedService }
        let current = ModelService.from(draft.configuration)
        return current.id == selectedServiceID ? current : nil
    }
    private var keepsOriginalModel: Bool {
        guard let existing else { return false }
        return ModelService.from(existing.configuration).id == ModelService.from(draft.configuration).id
            && existing.configuration.model == draft.configuration.model
    }
    private var modelAccepted: Bool {
        keepsOriginalModel || savedService?.models.contains(where: { $0.id == draft.configuration.model }) == true
    }
    private var canSave: Bool {
        modelAccepted && accountBinding.canSave(method: method, clientID: draft.configuration.chatGPTClientID)
    }
    private var displayedModel: String {
        savedService?.models.first(where: { $0.id == draft.configuration.model })?.name
            ?? (draft.configuration.model.isEmpty ? String(localized: "尚未选择模型") : draft.configuration.model)
    }

    var body: some View {
        Form {
            Section {
                botCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("机器人") {
                HStack {
                    TextField("名称", text: $draft.configuration.name)
                    Button(action: rerollName) { Label("换一个", systemImage: "shuffle") }
                }
            }
            Section("模型服务") {
                Picker("模型服务", selection: Binding(get: { selectedServiceID }, set: selectService)) {
                    if selectedServiceID.isEmpty { Text("请选择模型服务").tag("") }
                    if !selectedServiceID.isEmpty && savedService == nil {
                        Text("当前服务（未保存在列表中）").tag(selectedServiceID)
                    }
                    ForEach(services) { service in
                        Text(service.name).tag(service.id)
                            .disabled(service.loginMethod == .copilot && !CopilotClient.available && service.id != selectedServiceID)
                    }
                }
                if let serviceFailure { Text(serviceFailure).font(.footnote) }
                if services.isEmpty {
                    Text("还没有保存的模型服务。请先管理服务并保存模型列表。").font(.footnote)
                }
                modelPicker
                Button("管理模型服务") {
                    cancelAccountBinding()
                    managingServices = true
                }
                if method == .byok {
                    LabeledContent("Base URL", value: draft.configuration.endpoint)
                    Text("API Key 使用同一 Base URL 在设置中保存的凭证。").font(.footnote)
                } else if method == .chatgpt {
                    Button("检查所选 ChatGPT 账户", action: inspectSelectedChatGPTAccount)
                    if accountBinding.isReading { ProgressView("正在读取 ChatGPT 账户…") }
                    Text("ChatGPT 账户随所选服务保存，不会自动切换为当前账户。").font(.footnote)
                    if draft.configuration.chatGPTClientID?.isEmpty != false {
                        Text("请在管理模型服务中为所选服务授权。").font(.footnote)
                    }
                } else {
                    Text(CopilotClient.available ? "使用设置中登录的 GitHub Copilot 账户。" : CopilotClient.unavailableMessage)
                        .font(.footnote)
                }
            }
            if responsesTools {
                Section("服务商工具") {
                    Toggle("网页搜索", isOn: $webSearch)
                    if method == .byok {
                        Toggle("云端代码解释器", isOn: $codeInterpreter)
                        Toggle("云端生图", isOn: $imageGeneration)
                    }
                }
            }
            Section("此机器人的提示词与技能") {
                InstructionsEditor(instructions: $instructions)
                Text("新对话使用保存后的配置。已有对话可从会话工具栏应用新版配置。").font(.footnote)
            }
            Section {
                Button("保存机器人") { save() }.disabled(!canSave)
                if let feedback { Text(feedback).font(.footnote) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .disabled(store.configurationUnavailable || store.loadError != nil)
        .navigationTitle(existing == nil ? "新建机器人" : "编辑机器人")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .onAppear { onEditingVisibilityChange?(editorID, true) }
        .onChange(of: serviceRevision) { reloadServices() }
        .onDisappear {
            cancelAccountBinding()
            onEditingVisibilityChange?(editorID, false)
        }
        .sheet(isPresented: $managingServices, onDismiss: reloadServices) {
            NavigationStack {
                ModelServicesManager(store: store, proxy: proxy, onEditingVisibilityChange: onEditingVisibilityChange)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { managingServices = false } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 500)
            #endif
        }
    }

    private var botCard: some View {
        HStack(spacing: 16) {
            PendingChatAvatar(seed: draft.id.uuidString, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.configuration.name.isEmpty ? String(localized: "未命名机器人") : draft.configuration.name)
                    .font(Theme.Fonts.scriptTitle(draft.configuration.name, size: 22))
                    .foregroundStyle(Theme.Palette.ink)
                Text(displayedModel).font(Theme.Fonts.system(size: 14))
                    .foregroundStyle(Theme.Palette.inkMuted)
                if let selectedService {
                    Text(selectedService.name).font(Theme.Fonts.system(size: 12))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous).fill(Theme.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous).strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var modelPicker: some View {
        let models = savedService?.models ?? []
        let current = draft.configuration.model
        Picker("模型", selection: $draft.configuration.model) {
            if current.isEmpty {
                Text(keepsOriginalModel ? String(localized: "当前模型（服务默认）") : String(localized: "请选择模型")).tag("")
            }
            if !current.isEmpty && !models.contains(where: { $0.id == current }) {
                Text("当前模型：\(current)").tag(current)
            }
            ForEach(models) { model in Text(model.name).tag(model.id) }
        }
        .disabled(models.isEmpty)
        if models.isEmpty {
            Text("此服务还没有保存模型列表。请在管理模型服务中添加或获取模型。").font(.footnote)
        } else if !modelAccepted {
            Text("请选择此服务已保存的模型。").font(.footnote)
        }
    }

    private func rerollName() {
        var used = Set(store.bots.map { $0.configuration.name })
        used.insert(draft.configuration.name)
        draft.configuration.name = BotPlaceNames.random(excluding: used)
    }

    private func reloadServices() {
        cancelAccountBinding()
        do { services = try ModelServices.load(); serviceFailure = nil }
        catch { services = []; serviceFailure = error.localizedDescription }
        // A registry edit never silently rewrites an open bot's saved route,
        // selected account, model, instructions or optimistic-save baseline.
    }

    private func cancelAccountBinding() {
        accountBinding.cancel()
        accountTask?.cancel()
        accountTask = nil
    }

    private func selectService(_ id: String) {
        guard id != selectedServiceID, let chosen = services.first(where: { $0.id == id }) else { return }
        do {
            let service = try chosen.validated()
            guard service.loginMethod != .copilot || CopilotClient.available else {
                feedback = CopilotClient.unavailableMessage
                return
            }
            cancelAccountBinding()
            feedback = nil
            let model = service.models.contains(where: { $0.id == draft.configuration.model })
                ? draft.configuration.model : service.models.first?.id ?? ""
            let route = service.botSnapshot(name: draft.configuration.name, model: model)
            draft.configuration.loginMethod = route.loginMethod
            draft.configuration.endpoint = route.endpoint
            draft.configuration.apiProtocol = route.apiProtocol
            draft.configuration.chatGPTClientID = route.chatGPTClientID
            draft.configuration.model = route.model
            selectedServiceID = service.id
        } catch { feedback = error.localizedDescription }
    }

    private func inspectSelectedChatGPTAccount() {
        guard method == .chatgpt else { return }
        guard let clientID = draft.configuration.chatGPTClientID, !clientID.isEmpty else {
            feedback = String(localized: "请在管理模型服务中为所选服务授权。")
            return
        }
        cancelAccountBinding()
        let serviceID = selectedServiceID
        let ticket = accountBinding.begin()
        feedback = nil
        accountTask = Task { @MainActor in
            defer { if accountBinding.isCurrent(ticket) { accountTask = nil } }
            do {
                _ = try await accountBinding.readCurrentAccount(for: ticket, apply: { id in
                    guard method == .chatgpt, selectedServiceID == serviceID,
                          draft.configuration.chatGPTClientID == clientID, id == clientID else { throw CancellationError() }
                    feedback = String(localized: "此机器人的 ChatGPT 账户已就绪。")
                }, read: {
                    try await ChatGPTPlanSession.selectionForRequest(clientID: clientID)
                })
            } catch is CancellationError {
                // Closed/switched editors must not publish a late account read.
            } catch {
                guard accountBinding.isCurrent(ticket), method == .chatgpt,
                      selectedServiceID == serviceID, draft.configuration.chatGPTClientID == clientID else { return }
                feedback = error.localizedDescription
            }
        }
    }

    private func save() {
        guard !store.configurationUnavailable, store.loadError == nil else { return }
        do {
            guard modelAccepted else {
                throw ChatClient.ClientError.message(String(localized: "请选择此服务已保存的模型。"))
            }
            if !keepsOriginalModel {
                let current = try ModelServices.load().first { $0.id == selectedServiceID }
                guard current?.models.contains(where: { $0.id == draft.configuration.model }) == true else {
                    throw ChatClient.ClientError.message(String(localized: "所选服务或模型已变化，请重新选择。"))
                }
            }
            try accountBinding.requireReadyToSave(method: method, clientID: draft.configuration.chatGPTClientID)
            draft.configuration.instructions = instructions == BotInstructions() ? nil : instructions
            var tools: [String] = []
            if responsesTools && webSearch { tools.append("web_search") }
            if responsesTools && method == .byok && codeInterpreter { tools.append("code_interpreter") }
            if responsesTools && method == .byok && imageGeneration { tools.append("image_generation") }
            draft.configuration.hostedTools = tools.isEmpty ? nil : tools
            if method == .byok && draft.configuration.apiProtocol == nil { draft.configuration.apiProtocol = "responses" }
            try store.saveBots([draft], expected: existing)
            if let onSaved { onSaved() } else { dismiss() }
        } catch { feedback = error.localizedDescription }
    }
}
