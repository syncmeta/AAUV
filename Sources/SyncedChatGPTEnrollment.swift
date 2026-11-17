import Foundation

// A transient view of existing bot/chat references. This is not a new account
// registry, credential store or sync record, and never changes those references.
enum SyncedChatGPTEnrollment {
    struct Reference: Identifiable, Equatable, Sendable {
        let clientID: String
        let botNames: [String]
        let conversationTitles: [String]
        let botCount: Int
        let conversationCount: Int

        var id: String { clientID }
        var displayName: String? { botNames.first ?? conversationTitles.first }
    }

    private struct Usage {
        var bots: Set<UUID> = []
        var conversations: Set<UUID> = []
        var botNames: Set<String> = []
        var conversationTitles: Set<String> = []
    }

    static func references(bots: [LocalBot], conversations: [Conversation]) -> [Reference] {
        var usage: [String: Usage] = [:]
        func clientID(_ bot: BotSnapshot?) -> String? {
            guard let bot, bot.loginMethod == .chatgpt, let id = bot.chatGPTClientID,
                  APIKey.isNativeRegistrationID(id) else { return nil }
            return id
        }
        func name(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(100))
        }
        for bot in bots {
            guard let id = clientID(bot.configuration) else { continue }
            usage[id, default: Usage()].bots.insert(bot.id)
            if let name = name(bot.configuration.name) { usage[id, default: Usage()].botNames.insert(name) }
        }
        for conversation in conversations {
            guard let id = clientID(conversation.bot) else { continue }
            usage[id, default: Usage()].conversations.insert(conversation.id)
            if let name = name(conversation.title) { usage[id, default: Usage()].conversationTitles.insert(name) }
            if let name = conversation.bot.flatMap({ name($0.name) }) { usage[id, default: Usage()].botNames.insert(name) }
        }
        return usage.map { id, usage in
            Reference(clientID: id, botNames: usage.botNames.sorted(), conversationTitles: usage.conversationTitles.sorted(),
                      botCount: usage.bots.count, conversationCount: usage.conversations.count)
        }.sorted { lhs, rhs in
            let left = lhs.displayName ?? ""
            let right = rhs.displayName ?? ""
            return left == right ? lhs.clientID < rhs.clientID : left < right
        }
    }

    // nil means the local credential snapshot is unknown/loading/failed; it
    // must not be treated as a successfully loaded empty account registry.
    static func missingReferences(_ references: [Reference], knownLocalRegistrations: Set<String>?) -> [Reference]? {
        guard let knownLocalRegistrations else { return nil }
        return references.filter { !knownLocalRegistrations.contains($0.clientID) }
    }

    // Recheck live inputs at the user's click rather than retaining a target
    // from an old view or a failed Keychain read. The caller alone starts OAuth.
    static func requestedClientID(_ id: String, references: [Reference], knownLocalRegistrations: Set<String>?) -> String? {
        guard APIKey.isNativeRegistrationID(id),
              missingReferences(references, knownLocalRegistrations: knownLocalRegistrations)?.contains(where: { $0.clientID == id }) == true
        else { return nil }
        return id
    }
}
