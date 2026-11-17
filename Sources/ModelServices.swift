import Foundation
import CryptoKit

struct ServiceModel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String

    init(id: String, name: String? = nil) {
        self.id = id
        self.name = name ?? id
    }

    private enum CodingKeys: String, CodingKey { case id, name }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
    }
}

struct ModelService: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var loginMethod: LoginMethod
    var endpoint: String
    var apiProtocol: String = "responses"
    var chatGPTClientID: String?
    var models: [ServiceModel] = []

    init(name: String, loginMethod: LoginMethod, endpoint: String, apiProtocol: String = "responses",
         chatGPTClientID: String? = nil, models: [ServiceModel] = []) {
        self.name = name; self.loginMethod = loginMethod; self.endpoint = endpoint
        self.apiProtocol = apiProtocol; self.chatGPTClientID = chatGPTClientID; self.models = models
    }

    private enum CodingKeys: String, CodingKey { case name, loginMethod, endpoint, apiProtocol, chatGPTClientID, models }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        loginMethod = try values.decode(LoginMethod.self, forKey: .loginMethod)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        apiProtocol = try values.decodeIfPresent(String.self, forKey: .apiProtocol) ?? "responses"
        chatGPTClientID = try values.decodeIfPresent(String.self, forKey: .chatGPTClientID)
        models = try values.decodeIfPresent([ServiceModel].self, forKey: .models) ?? []
    }

    var id: String {
        let connection: [String]
        switch loginMethod {
        case .byok:
            connection = [loginMethod.rawValue, (try? ChatClient.baseURL(endpoint).absoluteString) ?? endpoint,
                          apiProtocol.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        case .chatgpt:
            connection = [loginMethod.rawValue, "https://api.openai.com/v1", "responses", chatGPTClientID ?? ""]
        case .copilot:
            connection = [loginMethod.rawValue, "https://github.com", "responses", ""]
        }
        let bytes = (try? JSONEncoder().encode(connection)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 80,
              !value.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              endpoint.utf8.count <= 4096 else { throw Self.invalid() }
        let canonicalEndpoint = try ChatClient.baseURL(endpoint).absoluteString
        switch loginMethod {
        case .byok:
            value.endpoint = canonicalEndpoint
            value.apiProtocol = apiProtocol.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["responses", "chat_completions", "anthropic_messages"].contains(value.apiProtocol) else { throw Self.invalid() }
            value.chatGPTClientID = nil
        case .chatgpt:
            guard let client = chatGPTClientID, APIKey.isNativeRegistrationID(client) else { throw Self.invalid() }
            value.endpoint = "https://api.openai.com/v1"
            value.apiProtocol = "responses"
        case .copilot:
            value.endpoint = "https://github.com"
            value.apiProtocol = "responses"
            value.chatGPTClientID = nil
        }
        value.models = try Self.validatedModels(models)
        return value
    }

    static func validateBatch(_ values: [Self]) throws -> [Self] {
        guard values.count <= 128 else { throw invalid() }
        let result = try values.map { try $0.validated() }
        guard Set(result.map(\.id)).count == result.count else { throw invalid() }
        return result
    }

    static func validatedModels(_ values: [ServiceModel]) throws -> [ServiceModel] {
        guard values.count <= 2048 else { throw invalid() }
        var seen = Set<String>()
        return try values.compactMap { original in
            let id = original.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = original.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.utf8.count <= 512, name.count <= 256,
                  !(id + name).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw invalid() }
            guard seen.insert(id).inserted else { return nil }
            return ServiceModel(id: id, name: name.isEmpty ? id : name)
        }
    }

    static func from(_ bot: BotSnapshot) -> Self {
        let label: String
        switch bot.loginMethod {
        case .byok: label = URLComponents(string: bot.endpoint)?.host ?? "BYOK"
        case .chatgpt: label = "ChatGPT" + (bot.chatGPTClientID.map { " · " + $0.suffix(6) } ?? "")
        case .copilot: label = "GitHub Copilot"
        }
        return Self(name: String(label.prefix(80)), loginMethod: bot.loginMethod, endpoint: bot.endpoint,
                    apiProtocol: bot.apiProtocol ?? "responses", chatGPTClientID: bot.chatGPTClientID,
                    models: bot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [ServiceModel(id: bot.model)])
    }

    func botSnapshot(name: String, model: String) -> BotSnapshot {
        BotSnapshot(name: name, endpoint: endpoint, model: model, loginMethod: loginMethod,
                    apiProtocol: apiProtocol, chatGPTClientID: chatGPTClientID)
    }

    private static func invalid() -> ChatClient.ClientError {
        .message(String(localized: "模型服务配置无效。请检查名称、地址、账户和模型列表。"))
    }
}

@MainActor
enum ModelServices {
    nonisolated static let storageKey = "savedModelServices"
    nonisolated static let revisionKey = "savedModelServicesRevision"

    static func load(defaults: UserDefaults = .standard) throws -> [ModelService] {
        guard let object = defaults.object(forKey: storageKey) else { return [] }
        guard let data = object as? Data, data.count <= 4 * 1024 * 1024 else { throw invalidStore() }
        do { return try ModelService.validateBatch(JSONDecoder().decode([ModelService].self, from: data)) }
        catch { throw invalidStore() }
    }

    static func replace(_ values: [ModelService], defaults: UserDefaults = .standard) throws {
        let data = try JSONEncoder().encode(ModelService.validateBatch(values))
        guard data.count <= 4 * 1024 * 1024 else { throw invalidStore() }
        defaults.set(data, forKey: storageKey)
        defaults.set(UUID().uuidString, forKey: revisionKey)
    }

    static func upsert(_ service: ModelService, replacing oldID: String? = nil, defaults: UserDefaults = .standard) throws {
        let service = try service.validated()
        var values = try load(defaults: defaults)
        if let oldID {
            guard let index = values.firstIndex(where: { $0.id == oldID }) else { throw changed() }
            guard !values.enumerated().contains(where: { $0.offset != index && $0.element.id == service.id }) else { throw changed() }
            values[index] = service
        } else if let index = values.firstIndex(where: { $0.id == service.id }) {
            values[index] = service
        } else { values.append(service) }
        try replace(values, defaults: defaults)
    }

    static func remove(id: String, defaults: UserDefaults = .standard) throws {
        var values = try load(defaults: defaults)
        values.removeAll { $0.id == id }
        try replace(values, defaults: defaults)
    }

    @discardableResult static func remember(_ snapshot: BotSnapshot, models: [ServiceModel] = [],
                                           defaults: UserDefaults = .standard) throws -> ModelService {
        var incoming = try ModelService.from(snapshot).validated()
        let values = try load(defaults: defaults)
        if let saved = values.first(where: { $0.id == incoming.id }) {
            incoming.name = saved.name
            incoming.models = try ModelService.validatedModels(saved.models + models + incoming.models)
        } else { incoming.models = try ModelService.validatedModels(models + incoming.models) }
        try upsert(incoming, defaults: defaults)
        return incoming
    }

    static func seed(defaults: UserDefaults = .standard, bots: [LocalBot], conversations: [Conversation]) throws {
        _ = try load(defaults: defaults) // Damaged or wrong-typed data must be reported, never overwritten.
        guard defaults.object(forKey: storageKey) == nil else { return }
        let snapshots = [BotSnapshot.activeDefaults(defaults: defaults)] + bots.map(\.snapshot) + conversations.compactMap(\.bot)
        var services: [ModelService] = []
        for snapshot in snapshots {
            guard let service = try? ModelService.from(snapshot).validated() else { continue }
            if let index = services.firstIndex(where: { $0.id == service.id }) {
                services[index].models = try ModelService.validatedModels(services[index].models + service.models)
            } else { services.append(service) }
        }
        try replace(services, defaults: defaults)
    }

    @MainActor struct Ticket {
        fileprivate let data: Data?
        fileprivate let revision: String?
        fileprivate let id: String
        fileprivate let existing: ModelService?
        fileprivate let defaults: UserDefaults

        func validate() throws {
            try Task.checkCancellation()
            guard data == defaults.data(forKey: storageKey), revision == defaults.string(forKey: revisionKey),
                  try load(defaults: defaults).first(where: { $0.id == id }) == existing else { throw changed() }
        }
    }

    static func capture(_ service: ModelService, requireExisting: Bool = true, defaults: UserDefaults = .standard) throws -> Ticket {
        let current = try load(defaults: defaults).first { $0.id == service.id }
        guard !requireExisting || current == service else { throw changed() }
        return Ticket(data: defaults.data(forKey: storageKey), revision: defaults.string(forKey: revisionKey),
                      id: service.id, existing: current, defaults: defaults)
    }

    private static func invalidStore() -> ChatClient.ClientError {
        .message(String(localized: "无法读取已保存的模型服务。原记录未被覆盖。"))
    }
    private static func changed() -> ChatClient.ClientError {
        .message(String(localized: "模型服务已被编辑或移除，请重新打开后重试。"))
    }
}
