import Foundation

struct PortableCredentials: Codable, Sendable {
    var byokKeys: [String: String]?
    var chatGPT: [OAuthCredentials]?
    var copilot: OAuthCredentials?
    var preferredChatGPTClientID: String?

    var byokCount: Int { (byokKeys ?? [:]).values.filter { !$0.isEmpty }.count }
    var oauthCount: Int { (chatGPT?.count ?? 0) + (copilot == nil ? 0 : 1) }
    var isEmpty: Bool { byokCount == 0 && oauthCount == 0 }

    func validated() throws -> Self {
        var copy = self
        var keys: [String: String] = [:]
        for (address, key) in byokKeys ?? [:] {
            let endpoint = try ChatClient.baseURL(address).absoluteString
            guard key.utf8.count <= 65_536, !key.contains(where: \.isNewline),
                  keys[endpoint].map({ $0 == key }) ?? true else {
                throw ChatClient.ClientError.message("配置含无效或冲突的 API Key。")
            }
            keys[endpoint] = key
        }
        let plans = chatGPT ?? []
        guard keys.count <= 256, plans.count <= 64 else {
            throw ChatClient.ClientError.message("配置中的登录凭证数量超出限制。")
        }
        var registrations = Set<String>()
        for plan in plans {
            try plan.validateStructure()
            guard plan.flow == .chatgptPlan, let id = plan.clientID, registrations.insert(id).inserted else {
                throw ChatClient.ClientError.message("配置含重复或无效的 ChatGPT 授权。")
            }
        }
        if let preferredChatGPTClientID, !registrations.contains(preferredChatGPTClientID) {
            throw ChatClient.ClientError.message("配置指定的 ChatGPT 授权未随文件提供。")
        }
        if let copilot {
            try copilot.validateStructure()
            guard copilot.flow == .githubCopilot else {
                throw ChatClient.ClientError.message("配置中的 GitHub Copilot 授权无效。")
            }
        }
        copy.byokKeys = keys.isEmpty ? nil : keys
        copy.chatGPT = plans.isEmpty ? nil : plans.map(\.transferable)
        copy.copilot = copilot?.transferable
        return copy
    }

    func merging(_ incoming: Self) throws -> Self {
        var result = self
        let keys = (byokKeys ?? [:]).merging((incoming.byokKeys ?? [:]).filter { !$0.value.isEmpty }) { _, new in new }
        result.byokKeys = keys.isEmpty ? nil : keys
        if let plans = incoming.chatGPT, !plans.isEmpty {
            let changed = Set(plans.compactMap(\.clientID))
            result.chatGPT = (chatGPT ?? []).filter { !changed.contains($0.clientID ?? "") } + plans
        }
        result.copilot = incoming.copilot ?? copilot
        result.preferredChatGPTClientID = incoming.preferredChatGPTClientID ?? preferredChatGPTClientID
        return try result.validated()
    }

    func chatGPTAuthorization(clientID: String? = nil) -> OAuthCredentials? {
        if let id = clientID ?? preferredChatGPTClientID {
            return chatGPT?.first { $0.clientID == id }
        }
        return chatGPT?.first
    }
}

extension PortableSettings {
    func loginCredentials() throws -> PortableCredentials {
        var result = try (credentials ?? PortableCredentials()).validated()
        if (loginMethod ?? .byok) == .byok, let key, !key.isEmpty {
            let address = try ChatClient.baseURL(endpoint).absoluteString
            guard result.byokKeys?[address].map({ $0 == key }) ?? true else {
                throw ChatClient.ClientError.message("同一 Base URL 包含两份不同的 API Key。")
            }
            result.byokKeys = (result.byokKeys ?? [:]).merging([address: key]) { old, _ in old }
        }
        if let oauth {
            if oauth.flow == .chatgptPlan, let id = oauth.clientID {
                if let existing = result.chatGPT?.first(where: { $0.clientID == id }) {
                    guard existing.accessToken == oauth.accessToken, existing.refreshToken == oauth.refreshToken else {
                        throw ChatClient.ClientError.message("同一个 ChatGPT 注册包含两份不同的授权。")
                    }
                } else {
                    result.chatGPT = (result.chatGPT ?? []) + [oauth]
                }
                result.preferredChatGPTClientID = id
            } else if oauth.flow == .githubCopilot {
                if let existing = result.copilot {
                    guard existing.accessToken == oauth.accessToken, existing.refreshToken == oauth.refreshToken else {
                        throw ChatClient.ClientError.message("配置包含两份不同的 GitHub Copilot 授权。")
                    }
                } else {
                    result.copilot = oauth
                }
            }
        }
        return try result.validated()
    }
}
