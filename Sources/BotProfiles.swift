import Foundation

struct LocalBot: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var configuration: BotSnapshot

    var snapshot: BotSnapshot {
        var snapshot = configuration
        snapshot.profileID = id
        return snapshot
    }

    func validated() throws -> Self {
        var bot = self
        bot.configuration.profileID = nil
        bot.configuration.name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.configuration.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bot.configuration.name.isEmpty, bot.configuration.name.count <= 80 else {
            throw ChatClient.ClientError.message("请输入机器人名称，最多 80 字。")
        }
        guard !bot.configuration.model.isEmpty || configuration.loginMethod == .copilot,
              bot.configuration.model.utf8.count <= 512 else {
            throw ChatClient.ClientError.message("请输入有效的模型名称。")
        }
        if let instructions = configuration.instructions {
            bot.configuration.instructions = try instructions.validated()
        }
        switch configuration.loginMethod {
        case .byok:
            bot.configuration.endpoint = try ChatClient.baseURL(configuration.endpoint).absoluteString
            let apiProtocol = configuration.apiProtocol ?? "responses"
            guard ["responses", "chat_completions", "anthropic_messages"].contains(apiProtocol) else {
                throw ChatClient.ClientError.message("请选择可用的 API 协议。")
            }
            bot.configuration.apiProtocol = apiProtocol
            bot.configuration.chatGPTClientID = nil
            if apiProtocol != "responses" { bot.configuration.hostedTools = nil }
        case .chatgpt:
            bot.configuration.endpoint = ChatGPTPlanSession.endpoint.absoluteString
            bot.configuration.apiProtocol = "responses"
            bot.configuration.hostedTools = configuration.hostedTools?.filter { $0 == "web_search" }
        case .copilot:
            bot.configuration.endpoint = "https://github.com"
            bot.configuration.chatGPTClientID = nil
            bot.configuration.hostedTools = nil
        }
        if let tools = bot.configuration.hostedTools {
            guard tools.allSatisfy({ HostedTool(rawValue: $0) != nil }) else {
                throw ChatClient.ClientError.message("机器人配置包含未知工具。")
            }
            bot.configuration.hostedTools = Array(Set(tools)).sorted()
        }
        return bot
    }

    static func makeNew(configuration: BotSnapshot, excludingNames: Set<String> = []) -> Self {
        var configuration = configuration
        configuration.name = BotPlaceNames.random(excluding: excludingNames)
        return Self(configuration: configuration)
    }

    static func validateBatch(_ bots: [Self]) throws -> [Self] {
        guard Set(bots.map(\.id)).count == bots.count else {
            throw ChatClient.ClientError.message("机器人列表包含重复记录。")
        }
        return try bots.map { try $0.validated() }
    }
}

extension BotSnapshot {
    @MainActor func boundForNewChat(defaults: UserDefaults = .standard) -> Self {
        guard loginMethod == .chatgpt, chatGPTClientID?.isEmpty != false else { return self }
        var snapshot = self
        snapshot.chatGPTClientID = Self.defaultChatGPTRegistration(defaults: defaults)
        return snapshot
    }

    @MainActor static func resetRecentDefault() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "recentBot"),
           let recent = try? JSONDecoder().decode(Self.self, from: data), recent.profileID != nil { return }
        defaults.removeObject(forKey: "recentBot")
        #if os(iOS)
        activeDefaults().publishToShareInbox()
        #endif
    }

    #if os(iOS)
    @MainActor func publishToShareInbox() {
        guard let inbox = ShareInbox.shared(), let data = try? JSONEncoder().encode(boundForNewChat()) else { return }
        try? inbox.rememberBotSnapshot(data)
    }
    #endif

    @MainActor static func currentChatGPTModel(imported: PortableSettings?) -> String {
        if let stored = UserDefaults.standard.string(forKey: "chatGPTModel"), !stored.isEmpty { return stored }
        if ChatGPTPlanSession.activeRegistration == nil, imported?.loginMethod == .chatgpt {
            return imported?.model ?? ""
        }
        return ""
    }

    @MainActor static func activeDefaults(defaults: UserDefaults = .standard) -> Self {
        let endpoint = defaults.string(forKey: "endpoint") ?? "https://api.openai.com/v1"
        let model = defaults.string(forKey: "model") ?? ""
        let method = LoginMethod(rawValue: defaults.string(forKey: "loginMethod") ?? "") ?? .byok
        let imported = ImportedBotMetadataCache.read(defaults: defaults)
        if method == .chatgpt {
            let active = defaults.string(forKey: ChatGPTPlanSession.selectionKey).flatMap { $0.isEmpty ? nil : $0 }
            let selected = defaults.string(forKey: "chatGPTModel").flatMap { $0.isEmpty ? nil : $0 }
                ?? (active == nil && imported?.loginMethod == .chatgpt ? imported?.model : nil) ?? ""
            return Self(name: selected.isEmpty ? "大绿豆" : selected, endpoint: ChatGPTPlanSession.endpoint.absoluteString,
                        model: selected, loginMethod: method, apiProtocol: "responses",
                        hostedTools: DefaultHostedTools.chatGPT(imported: imported?.configuration, defaults: defaults),
                        chatGPTClientID: defaultChatGPTRegistration(defaults: defaults))
        }
        if method == .copilot {
            let selected = defaults.string(forKey: "githubCopilotModel") ?? ""
            return Self(name: selected.isEmpty ? "GitHub Copilot" : selected, endpoint: "https://github.com",
                        model: selected, loginMethod: method)
        }
        let api = defaults.string(forKey: "apiProtocol") ?? "responses"
        return Self(name: model.isEmpty ? "大绿豆" : model, endpoint: endpoint, model: model, loginMethod: method,
                    apiProtocol: api, hostedTools: api == "responses"
                        ? DefaultHostedTools.byok(at: endpoint, imported: imported?.configuration, defaults: defaults) : nil)
    }

    @MainActor private static func defaultChatGPTRegistration(defaults: UserDefaults) -> String? {
        defaults.string(forKey: ChatGPTPlanSession.selectionKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? ImportedBotMetadataCache.read(defaults: defaults)?.chatGPTClientID
    }
}
