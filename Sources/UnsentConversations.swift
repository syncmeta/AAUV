import Foundation

/// Per-window, in-memory previews. Opening or switching one never touches SQLite.
struct UnsentConversations {
    private var conversations: [UUID: Conversation] = [:]

    subscript(id: UUID) -> Conversation? { conversations[id] }

    mutating func open(bot: BotSnapshot, reusing: Bool = false) -> Conversation {
        if reusing, let existing = conversations.values.first(where: { $0.bot == bot }) { return existing }
        var conversation = Conversation()
        conversation.bot = bot
        conversation.automaticTitle = true
        conversations[conversation.id] = conversation
        return conversation
    }

    mutating func changeBot(_ bot: BotSnapshot, in id: UUID) {
        guard conversations[id] != nil else { return }
        conversations[id]?.bot = bot
    }

    mutating func remove(_ id: UUID) { conversations.removeValue(forKey: id) }
}
