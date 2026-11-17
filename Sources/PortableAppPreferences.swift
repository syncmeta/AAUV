import Foundation

/// A local display identity, independent of model-provider accounts.
struct LocalDisplayProfile: Codable, Equatable, Sendable {
    static let storageKey = "localDisplayProfile"
    var name: String
    var avatarSeed: String

    static let placeholder = Self(name: "你", avatarSeed: "?")

    func validated() throws -> Self {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              UUID(uuidString: avatarSeed) != nil else {
            throw ChatClient.ClientError.message(String(localized: "地名最多 80 字，头像标识必须有效。"))
        }
        return Self(name: name, avatarSeed: avatarSeed)
    }

    static func decode(_ data: Data) -> Self? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return try? value.validated()
    }

    static func read(defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: storageKey).flatMap(decode)
    }

    static func prepare(defaults: UserDefaults = .standard) {
        guard read(defaults: defaults) == nil, let data = try? JSONEncoder().encode(random()) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func random() -> Self {
        Self(name: names.randomElement() ?? "你", avatarSeed: UUID().uuidString)
    }

    // The same offline place-name corpus used by PendingBot's profile picker.
    private static let names: [String] = {
        guard let url = Bundle.main.url(forResource: "profile-place-names", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return ["你"] }
        return raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()
}

// Public application preferences only. A node's SHA-256 ID is a reference;
// its URI/credentials remain in the existing opt-in credential export.
struct PortableAppPreferences: Equatable, Sendable {
    var selectedProxyNode: String?
    var proxyRequiresTunnel: Bool?
    var githubCopilotClientID: String?
    var cloudSyncEnabled: Bool?
    var localProfile: LocalDisplayProfile?
    var modelServices: [ModelService]?

    func validated() throws -> Self {
        var result = self
        if let localProfile { result.localProfile = try localProfile.validated() }
        if let modelServices {
            let values = try ModelService.validateBatch(modelServices)
            guard try JSONEncoder().encode(values).count <= 4 * 1024 * 1024 else {
                throw ChatClient.ClientError.message(String(localized: "模型服务列表过大，请减少模型后再导入。"))
            }
            result.modelServices = values
        }
        if let selectedProxyNode {
            guard selectedProxyNode.isEmpty || (selectedProxyNode.utf8.count == 64 && selectedProxyNode.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })) else { throw ChatClient.ClientError.message(String(localized: "配置中的代理节点选择必须是节点 SHA-256 ID。")) }
            result.selectedProxyNode = selectedProxyNode.lowercased()
        }
        if let githubCopilotClientID {
            let value = githubCopilotClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 128, value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                throw ChatClient.ClientError.message(String(localized: "配置中的 GitHub OAuth Client ID 无效。"))
            }
            result.githubCopilotClientID = value
        }
        return result
    }

    static func capture(defaults: UserDefaults = .standard) throws -> Self {
        let services: [ModelService]?
        if let object = defaults.object(forKey: ModelServices.storageKey) {
            guard let data = object as? Data, data.count <= 4 * 1024 * 1024 else {
                throw ChatClient.ClientError.message(String(localized: "已保存的模型服务数据无法读取，请先检查服务列表。"))
            }
            services = try ModelService.validateBatch(JSONDecoder().decode([ModelService].self, from: data))
        } else { services = nil }
        return try Self(selectedProxyNode: defaults.string(forKey: "selectedProxyNode") ?? "",
                 proxyRequiresTunnel: defaults.bool(forKey: "proxyRequiresTunnel"),
                 githubCopilotClientID: defaults.string(forKey: "githubCopilotClientID") ?? "",
                 cloudSyncEnabled: defaults.bool(forKey: "cloudSyncEnabled"),
                 localProfile: LocalDisplayProfile.read(defaults: defaults),
                 modelServices: services).validated()
    }

    // Missing legacy fields preserve the device preference. Validate the whole
    // group before writing any field; the existing import journal owns durable
    // publication/retry and its final defaults.synchronize/retirement boundary.
    func persist(defaults: UserDefaults = .standard) throws {
        let value = try validated()
        let profileData = try value.localProfile.map { try JSONEncoder().encode($0) }
        let serviceData = try value.modelServices.map { try JSONEncoder().encode($0) }
        if let selectedProxyNode = value.selectedProxyNode { defaults.set(selectedProxyNode, forKey: "selectedProxyNode") }
        if let proxyRequiresTunnel = value.proxyRequiresTunnel { defaults.set(proxyRequiresTunnel, forKey: "proxyRequiresTunnel") }
        if let githubCopilotClientID = value.githubCopilotClientID { defaults.set(githubCopilotClientID, forKey: "githubCopilotClientID") }
        if let cloudSyncEnabled = value.cloudSyncEnabled { defaults.set(cloudSyncEnabled, forKey: "cloudSyncEnabled") }
        if let profileData { defaults.set(profileData, forKey: LocalDisplayProfile.storageKey) }
        if let serviceData {
            defaults.set(serviceData, forKey: ModelServices.storageKey)
            defaults.set(UUID().uuidString, forKey: ModelServices.revisionKey)
        }
    }

    var preview: [String] {
        var lines: [String] = []
        if localProfile != nil { lines.append(String(localized: "恢复地名和头像。")) }
        if modelServices != nil { lines.append(String(localized: "恢复已保存的模型服务和模型列表；登录凭证仍按凭证选项处理。")) }
        if let selectedProxyNode {
            lines.append(selectedProxyNode.isEmpty ? String(localized: "代理节点选择：默认节点。") : String(localized: "恢复所选代理节点；如果尚未导入该节点，需另行导入节点凭证。"))
        }
        if let proxyRequiresTunnel {
            lines.append(proxyRequiresTunnel ? String(localized: "请求必须等待代理连接；不会自动连接 VPN。") : String(localized: "请求不再要求代理连接；不会自动断开现有 VPN。"))
        }
        if let githubCopilotClientID {
            lines.append(githubCopilotClientID.isEmpty ? String(localized: "清除 GitHub 登录表单的 App Client ID；已有 OAuth 授权不变。") : String(localized: "恢复 GitHub 登录表单的 App Client ID；已有 OAuth 授权仍使用原 Client ID。"))
        }
        if let cloudSyncEnabled {
            lines.append(cloudSyncEnabled ? String(localized: "开启 iCloud 同步：确认后会按当前系统 iCloud 账户同步会话、附件、机器人、提示词、个人资料及保存的服务和模型列表；登录凭证保留在本机。") : String(localized: "关闭 iCloud 自动同步；保留本机数据。"))
        }
        return lines
    }
}
