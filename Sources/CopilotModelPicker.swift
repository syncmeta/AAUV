import SwiftUI

struct CopilotModelPicker: View {
    let proxy: SingBox
    @Binding var model: String
    @AppStorage(APIKey.copilotRevisionKey) private var credentialRevision = ""
    @State private var models: [CopilotClient.Model]?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(iOS)
            TextField("Copilot 模型（留空仅使用目录声明的默认值）", text: $model)
                .autocorrectionDisabled()
            #else
            TextField("Copilot 模型（留空使用服务默认值）", text: $model)
                .autocorrectionDisabled()
            #endif
            if let models {
                Menu("从模型目录选择") {
                    Button {
                        model = ""
                    } label: {
                        choice("服务默认模型", selected: model.isEmpty)
                    }
                    ForEach(models) { entry in
                        Button {
                            model = entry.id
                        } label: {
                            #if os(iOS)
                            choice(entry.allowed ? entry.name : entry.name + String(localized: "（当前账户或接口不可用）"),
                                   selected: model == entry.id)
                            #else
                            choice(entry.allowed ? entry.name : entry.name + "（受 GitHub 策略限制）",
                                   selected: model == entry.id)
                            #endif
                        }
                        .disabled(!entry.allowed)
                    }
                }
            }
            if task != nil {
                ProgressView("正在读取 Copilot 模型…").controlSize(.small)
                Button("取消读取") { task?.cancel() }
            } else {
                Button(models == nil ? "读取 Copilot 模型目录" : "刷新 Copilot 模型目录", action: refresh)
            }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
        }
        .onChange(of: credentialRevision) {
            task?.cancel()
            models = nil
            failure = nil
        }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private func choice(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }

    private func refresh() {
        guard task == nil else { return }
        let revision = credentialRevision
        let cacheSnapshot = BotSnapshot(name: "GitHub Copilot", endpoint: "https://github.com", model: "", loginMethod: .copilot)
        let cacheTicket = try? ModelServices.capture(ModelService.from(cacheSnapshot), requireExisting: false)
        failure = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let authorization = CopilotSession()
                let result = try await authorization.models(proxy: proxy)
                try authorization.validate()
                if revision == credentialRevision {
                    models = result
                    if let cacheTicket {
                        do {
                            try cacheTicket.validate()
                            _ = try ModelServices.remember(cacheSnapshot, models: result.filter(\.allowed).map {
                                ServiceModel(id: $0.id, name: $0.name)
                            })
                        } catch { /* Cache publication is optional; preserve the usable directory. */ }
                    }
                    if !result.contains(where: \.allowed) {
                        #if os(iOS)
                        failure = String(localized: "GitHub 没有返回可用于当前接口的模型，请检查订阅与模型权限。")
                        #else
                        failure = "GitHub 没有返回可单独选择的模型。仍可使用服务默认模型。"
                        #endif
                    }
                }
            } catch {
                if !Task.isCancelled, revision == credentialRevision { failure = error.localizedDescription }
            }
        }
    }
}
