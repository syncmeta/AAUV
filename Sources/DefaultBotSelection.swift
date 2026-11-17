import Foundation

/// Optional in portable settings: absent means preserve the local choice.
/// Profile selections follow the current saved profile; custom selections retain
/// their independent snapshot. No credential values belong in this type.
struct DefaultBotSelection: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case providerDefault = "defaults", profile, custom }
    var mode: Mode
    var profileID: UUID?
    var snapshot: BotSnapshot?
    // Only the import journal needs a resolved profile snapshot. Do not duplicate
    // a large profile's prompts in configuration links or persistent vault data.
    private(set) var resolvedProfile: BotSnapshot? = nil

    enum CodingKeys: String, CodingKey { case mode, profileID, snapshot }

    static var providerDefault: Self { .init(mode: .providerDefault) }
    static func profile(_ id: UUID) -> Self { .init(mode: .profile, profileID: id) }
    static func custom(_ bot: BotSnapshot) -> Self { .init(mode: .custom, snapshot: bot) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.profileID == rhs.profileID && lhs.snapshot == rhs.snapshot
    }

    enum SelectionError: LocalizedError {
        case invalid, missingProfile, unboundChatGPT, unresolvedProfile
        var errorDescription: String? {
            switch self {
            case .invalid: return "配置中的最近机器人选择无效。"
            case .missingProfile: return "配置选择的机器人不存在或已被删除。请重新选择机器人后导出配置。"
            case .unboundChatGPT: return "所选 ChatGPT 机器人没有原账户注册。请先确认要使用的账户，再导出或导入选择。"
            case .unresolvedProfile: return "暂时无法恢复所选机器人。请重新导入包含该机器人的配置。"
            }
        }
    }

    func validated() throws -> Self {
        switch mode {
        case .providerDefault:
            guard profileID == nil, snapshot == nil else { throw SelectionError.invalid }
        case .profile:
            guard profileID != nil, snapshot == nil else { throw SelectionError.invalid }
        case .custom:
            guard profileID == nil, var value = snapshot, value.profileID == nil else { throw SelectionError.invalid }
            // A nil protocol meant Chat Completions for historical independent
            // snapshots. Preserve that behavior rather than migrating protocols.
            if value.loginMethod == .byok, value.apiProtocol == nil { value.apiProtocol = "chat_completions" }
            value = try LocalBot(configuration: value).validated().configuration
            try Self.requireBoundChatGPT(value)
            return .custom(value)
        }
        return self
    }

    func resolvingProfiles(_ bots: [LocalBot]) throws -> Self {
        var value = try validated()
        if mode == .profile {
            guard let target = bots.first(where: { $0.id == profileID }) else { throw SelectionError.missingProfile }
            try Self.requireBoundChatGPT(target.snapshot)
            value.resolvedProfile = target.snapshot
        }
        return value
    }

    func remappingProfile(_ ids: [UUID: UUID]) throws -> Self {
        let value = try validated()
        guard mode == .profile else { return value }
        guard let original = profileID, let copied = ids[original] else { throw SelectionError.missingProfile }
        return .profile(copied)
    }

    var snapshotForPublication: BotSnapshot? {
        mode == .profile ? resolvedProfile : snapshot
    }

    private static func requireBoundChatGPT(_ bot: BotSnapshot) throws {
        if bot.loginMethod == .chatgpt, bot.chatGPTClientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw SelectionError.unboundChatGPT
        }
    }

    @MainActor static func capture(bots: [LocalBot], defaults: UserDefaults = .standard) throws -> Self {
        guard let bot = storedSnapshot(in: defaults) else { return .providerDefault }
        if let id = bot.profileID {
            // Existing local stale profiles already fall back to provider defaults.
            guard bots.contains(where: { $0.id == id }) else { return .providerDefault }
            return try Self.profile(id).resolvingProfiles(bots)
        }
        return try Self.custom(bot).validated()
    }

    @MainActor static func currentBot(bots: [LocalBot], defaults: UserDefaults = .standard) -> BotSnapshot {
        if let bot = storedSnapshot(in: defaults) {
            if let id = bot.profileID {
                if let current = bots.first(where: { $0.id == id }) { return current.snapshot }
            } else { return bot }
        }
        return BotSnapshot.activeDefaults(defaults: defaults)
    }

    @MainActor static func savingUserMessage<Result>(with bot: BotSnapshot, bots: [LocalBot],
                                                     defaults: UserDefaults = .standard,
                                                     save: () throws -> Result) rethrows -> Result {
        let result = try save()
        remember(bot, bots: bots, defaults: defaults)
        return result
    }

    @MainActor static func savingMessage<Result>(_ message: ChatMessage, with bot: BotSnapshot,
                                                 bots: [LocalBot], defaults: UserDefaults = .standard,
                                                 save: () throws -> Result) rethrows -> Result {
        if message.role == .user {
            return try savingUserMessage(with: bot, bots: bots, defaults: defaults, save: save)
        }
        return try save()
    }

    @MainActor static func remember(_ bot: BotSnapshot, bots: [LocalBot], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(bot) else { return }
        defaults.set(data, forKey: "recentBot")
        publishForNewShares(currentBot(bots: bots, defaults: defaults), defaults: defaults)
    }

    @MainActor func persist(snapshot resolved: BotSnapshot?, defaults: UserDefaults = .standard) throws {
        let value = try validated()
        let selected: BotSnapshot
        switch value.mode {
        case .providerDefault:
            defaults.removeObject(forKey: "recentBot")
            selected = BotSnapshot.activeDefaults(defaults: defaults)
        case .profile:
            guard let resolved, resolved.profileID == profileID else { throw SelectionError.unresolvedProfile }
            try Self.requireBoundChatGPT(resolved)
            defaults.set(try JSONEncoder().encode(resolved), forKey: "recentBot")
            selected = resolved
        case .custom:
            guard let snapshot = value.snapshot else { throw SelectionError.invalid }
            defaults.set(try JSONEncoder().encode(snapshot), forKey: "recentBot")
            selected = snapshot
        }
        Self.publishForNewShares(selected, defaults: defaults)
    }

    @MainActor private static func storedSnapshot(in defaults: UserDefaults) -> BotSnapshot? {
        defaults.data(forKey: "recentBot").flatMap { try? JSONDecoder().decode(BotSnapshot.self, from: $0) }
    }

    @MainActor private static func publishForNewShares(_ bot: BotSnapshot, defaults: UserDefaults) {
        #if os(iOS)
        // Changing the inbox's default affects future captures only. Every
        // already queued item retains its own entrance-time snapshot.
        if defaults === UserDefaults.standard { bot.publishToShareInbox() }
        #endif
    }

    func preview(bots: [LocalBot]) -> String {
        switch mode {
        case .providerDefault: return "新对话与文件打开：使用默认服务。"
        case .profile:
            if let bot = bots.first(where: { $0.id == profileID }) {
                return "新对话与文件打开：最近机器人「\(bot.configuration.name)」· \(bot.configuration.model)。"
            }
            return "新对话与文件打开：指定的机器人目前不存在，导入前需要该机器人配置。"
        case .custom:
            return "新对话与文件打开：自定义机器人「\(snapshot?.name ?? "")」· \(snapshot?.model ?? "")。"
        }
    }

    /// Included by the existing credential exporter even if an independent
    /// selected snapshot is absent from every saved profile and conversation.
    func credentialSnapshots(bots: [LocalBot]) -> [BotSnapshot] {
        switch mode {
        case .providerDefault: return []
        case .profile: return bots.first(where: { $0.id == profileID }).map { [$0.snapshot] } ?? []
        case .custom: return snapshot.map { [$0] } ?? []
        }
    }
}
