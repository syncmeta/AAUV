import Foundation

/// Text background captured by a manual action, independent of the original chat's rows.
struct LetterContext: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable {
        let id: UUID
        let role: ChatMessage.Role
        let content: String
        let date: Date?

        var chatMessage: ChatMessage { ChatMessage(id: id, role: role, content: content, date: date) }
    }

    let sourceConversationID: UUID?
    let capturedAt: Date
    let messages: [Message]

    func validate(excluding ids: Set<UUID> = []) throws {
        guard messages.count <= 50_000, Set(messages.map(\.id)).count == messages.count,
              Set(messages.map(\.id)).isDisjoint(with: ids),
              try JSONEncoder().encode(self).count <= 8 * 1024 * 1024 else {
            throw ChatClient.ClientError.message(String(localized: "近期聊天记录过大，请缩小上下文时间范围后重试。"))
        }
    }
}

enum LetterGeneration {
    // This is an application action, not an instruction to adopt a document format.
    static let prompt = "结合前面的聊天，自然地继续和用户说点什么。沿用你们聊天时的语言，可以接着之前的话题，也可以聊聊此刻你想对对方说的话。没有聊天背景时，就自然地开启话题，不编造既往经历。"
    static let backgroundInstructions = "前面的消息来自你与用户最近一次聊天的背景快照，可能与本次生成间隔了一段时间；结合原有时间自然回应。最后的生成提示由用户点击应用中的按钮触发，并非用户额外输入的原话。"

    static func makeConversation(bot: BotSnapshot, conversations: [Conversation],
                                 policy: ContextPolicy, now: Date = Date()) throws -> Conversation {
        let policy = try policy.validated()
        let candidates = conversations.filter { chat in
            guard !chat.isLetter, !chat.messages.isEmpty, let previous = chat.bot else { return false }
            if let id = bot.profileID { return previous.profileID == id }
            // Missing identities never collapse all default/custom bots into one account.
            return previous.profileID == nil && previous == bot
        }
        func lastTime(_ chat: Conversation) -> Date {
            chat.messages.compactMap(\.date).filter { $0 <= now }.max() ?? .distantPast
        }
        var source: Conversation?
        var latest = Date.distantPast
        for chat in candidates {
            let date = lastTime(chat)
            if source == nil || date > latest { source = chat; latest = date }
        }
        let selected: [ChatMessage] = source?.contextMessages().filter { $0.date.map { $0 <= now } ?? true } ?? []
        let start = now.addingTimeInterval(-Double(policy.hours) * 3600)
        // Keep the complete active window, and the same uniform older sample budget.
        // This avoids copying an unbounded archive into every generated item.
        let older: [ChatMessage] = selected.filter { $0.date.map { $0 < start } ?? true }
        let sampled: Set<UUID> = Set(older.shuffled().prefix(policy.samples).map(\.id))
        let background: [ChatMessage] = selected.filter { message in
            message.date.map { $0 >= start } == true || sampled.contains(message.id)
        }
        let trigger = ChatMessage(role: .user, content: prompt, date: now)
        var ids = Set(source?.messages.map(\.id) ?? [])
        ids.insert(trigger.id)
        let history = background.map { message -> LetterContext.Message in
            var id = UUID()
            while !ids.insert(id).inserted { id = UUID() }
            return .init(id: id, role: message.role, content: message.content, date: message.date)
        }
        let snapshot = LetterContext(sourceConversationID: source?.id, capturedAt: now, messages: history)
        try snapshot.validate(excluding: [trigger.id])
        var conversation = Conversation()
        conversation.title = LetterWritingPrompt.conversationTitle(botName: bot.name)
        conversation.purpose = .letter
        conversation.automaticTitle = false
        conversation.bot = bot
        conversation.letterContext = snapshot
        conversation.messages = [trigger]
        // Existing file references remain eligible for explicit local attachment tools,
        // sync, backups and cleanup. They are not eagerly re-uploaded by the new action.
        let retained = Set(background.map(\.id))
        let references = (source?.attachments ?? []) + selected.filter { retained.contains($0.id) }.flatMap { $0.attachments ?? [] }
        var files = Set<String>()
        let unique = references.filter { files.insert($0.fileName).inserted }
        conversation.attachments = unique.isEmpty ? nil : unique
        return conversation
    }
}
