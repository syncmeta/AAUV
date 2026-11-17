import SwiftUI

struct ModelServicesManager: View {
    let store: ConversationStore
    let proxy: SingBox
    var onEditingVisibilityChange: ((UUID, Bool) -> Void)? = nil
    @AppStorage(ModelServices.storageKey) private var storedServices = Data()
    @State private var services: [ModelService] = []
    @State private var problem: String?
    @State private var unavailable = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshingID: String?
    @State private var editor: Editor?
    @State private var editorID = UUID()

    private struct Editor: Identifiable {
        let id = UUID()
        var service: ModelService?
    }

    var body: some View {
        List {
            Section {
                Button("添加 BYOK 服务") { editor = Editor(service: nil) }
                Text("模型列表保存在本机，只在点击刷新时联网。机器人使用已保存的模型列表。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(services) { service in
                Section {
                    Button { editor = Editor(service: service) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(service.name)
                            Text(service.endpoint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("已保存 \(service.models.count) 个模型").font(.footnote)
                    if refreshingID == service.id {
                        ProgressView("正在刷新模型列表…")
                        Button("取消刷新") { refreshTask?.cancel() }
                    } else {
                        Button("刷新模型列表") { refresh(service) }.disabled(refreshTask != nil)
                    }
                    Button("移除服务", role: .destructive) {
                        do { try ModelServices.remove(id: service.id); reload() }
                        catch { problem = error.localizedDescription }
                    }
                }
            }
            if let problem { Text(problem).font(.footnote) }
        }
        .navigationTitle("模型服务")
        .disabled(store.configurationUnavailable || store.loadError != nil || unavailable)
        .onAppear {
            onEditingVisibilityChange?(editorID, true)
            do { try ModelServices.seed(bots: store.bots, conversations: store.conversations) }
            catch { problem = error.localizedDescription }
            reload()
        }
        .onChange(of: storedServices) { reload() }
        .onDisappear { refreshTask?.cancel(); onEditingVisibilityChange?(editorID, false) }
        .sheet(item: $editor) { editor in
            ModelServiceEditor(store: store, existing: editor.service,
                               onEditingVisibilityChange: onEditingVisibilityChange)
        }
    }

    private func reload() {
        do { services = try ModelServices.load(); unavailable = false }
        catch { unavailable = true; problem = error.localizedDescription }
    }

    private func refresh(_ service: ModelService) {
        guard refreshTask == nil, !store.configurationUnavailable, store.loadError == nil, !unavailable else { return }
        problem = nil
        refreshingID = service.id
        refreshTask = Task { @MainActor in
            defer { refreshTask = nil; refreshingID = nil }
            do {
                _ = try await ModelServiceFetcher.refresh(service, proxy: proxy, validateIntent: {
                    guard !store.configurationUnavailable, store.loadError == nil else { throw CancellationError() }
                })
                reload()
            } catch is CancellationError {
                return
            } catch { problem = ModelServiceFetcher.safeMessage(error) }
        }
    }
}

private struct ModelServiceEditor: View {
    let store: ConversationStore
    let existing: ModelService?
    let onEditingVisibilityChange: ((UUID, Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelService
    @State private var rows: [ModelRow]
    @State private var key = ""
    @State private var keyTask: Task<Void, Never>?
    @State private var loadingKey = false
    @State private var keyReadFailed = false
    @State private var keyEdited = false
    @State private var credentialStamp: String?
    @State private var ticket: ModelServices.Ticket?
    @State private var problem: String?
    @State private var editorID = UUID()

    private struct ModelRow: Identifiable {
        let id = UUID()
        var value: ServiceModel
    }

    init(store: ConversationStore, existing: ModelService?, onEditingVisibilityChange: ((UUID, Bool) -> Void)?) {
        self.store = store; self.existing = existing; self.onEditingVisibilityChange = onEditingVisibilityChange
        let service = existing ?? ModelService(name: "", loginMethod: .byok, endpoint: "https://api.openai.com/v1")
        _draft = State(initialValue: service)
        _rows = State(initialValue: service.models.map { ModelRow(value: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务") {
                    TextField("服务名称", text: $draft.name)
                    if draft.loginMethod == .byok {
                        TextField("Base URL", text: $draft.endpoint)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        Picker("API", selection: $draft.apiProtocol) {
                            Text("Responses API").tag("responses")
                            Text("Chat Completions").tag("chat_completions")
                            Text("Anthropic Messages（预留）").tag("anthropic_messages")
                        }
                        SecureField("API Key", text: Binding(get: { key }, set: {
                            keyTask?.cancel(); loadingKey = false; keyEdited = true; key = $0
                        }))
                        .privacySensitive()
                        if loadingKey { ProgressView("正在读取本机钥匙串…") }
                        if keyReadFailed { Button("重新读取钥匙串", action: loadKey) }
                    } else {
                        Text(draft.loginMethod == .chatgpt ? "ChatGPT" : "GitHub Copilot")
                        Text(draft.endpoint).font(.footnote)
                    }
                }
                Section("模型列表") {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading) {
                            TextField("模型 ID", text: $row.value.id).autocorrectionDisabled()
                            TextField("显示名称", text: $row.value.name)
                            Button("移除此模型", role: .destructive) { rows.removeAll { $0.id == row.id } }
                        }
                    }
                    Button("添加模型") { rows.append(ModelRow(value: ServiceModel(id: ""))) }
                }
                if let problem { Text(problem).font(.footnote) }
            }
            .disabled(store.configurationUnavailable || store.loadError != nil)
            .navigationTitle("编辑模型服务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(loadingKey || ticket == nil || (keyReadFailed && !keyEdited) || store.configurationUnavailable || store.loadError != nil)
                }
            }
        }
        .onAppear {
            onEditingVisibilityChange?(editorID, true)
            do { ticket = try ModelServices.capture(draft, requireExisting: existing != nil) }
            catch { problem = error.localizedDescription }
            loadKey()
        }
        .onChange(of: draft.endpoint) { if draft.loginMethod == .byok { loadKey() } }
        .onDisappear { keyTask?.cancel(); key = ""; onEditingVisibilityChange?(editorID, false) }
    }

    private func loadKey() {
        keyTask?.cancel(); key = ""; keyEdited = false; keyReadFailed = false; loadingKey = false
        guard draft.loginMethod == .byok, let url = try? ChatClient.baseURL(draft.endpoint) else { return }
        let revision = UserDefaults.standard.string(forKey: APIKey.byokRevisionKey)
        credentialStamp = revision
        loadingKey = true
        keyTask = Task { @MainActor in
            defer { if !Task.isCancelled { loadingKey = false } }
            do {
                let value = try await APIKey.readInBackground { try APIKey.read(for: url) }
                try Task.checkCancellation()
                guard revision == UserDefaults.standard.string(forKey: APIKey.byokRevisionKey) else {
                    throw ChatClient.ClientError.message(String(localized: "API 凭证已改变，请重新读取后保存。"))
                }
                guard (try? ChatClient.baseURL(draft.endpoint)) == url else { throw CancellationError() }
                key = value
            } catch is CancellationError { return }
            catch { keyReadFailed = true; problem = ModelServiceFetcher.safeMessage(error) }
        }
    }

    private func save() {
        guard !loadingKey, !store.configurationUnavailable, store.loadError == nil, let ticket,
              !keyReadFailed || keyEdited else { return }
        do {
            try ticket.validate()
            try APIKey.checkNoPendingConfigurationImport()
            var service = draft
            service.models = rows.map(\.value)
            service = try service.validated()
            // Validate the complete public write before touching a credential.
            let values = try ModelServices.load()
            var next = values.filter { $0.id != existing?.id }
            next.append(service)
            let data = try JSONEncoder().encode(ModelService.validateBatch(next))
            guard data.count <= 4 * 1024 * 1024 else {
                throw ChatClient.ClientError.message(String(localized: "模型服务配置过大，请减少模型数量。"))
            }
            if service.loginMethod == .byok {
                guard credentialStamp == UserDefaults.standard.string(forKey: APIKey.byokRevisionKey) else {
                    throw ChatClient.ClientError.message(String(localized: "API 凭证已改变，请重新读取后保存。"))
                }
                try APIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: ChatClient.baseURL(service.endpoint))
            }
            try ModelServices.upsert(service, replacing: existing?.id)
            dismiss()
        } catch { problem = ModelServiceFetcher.safeMessage(error) }
    }
}
