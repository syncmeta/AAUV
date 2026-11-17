import Foundation

// Manual audio cancellation may still flush a final transcript. A deleted or
// replaced conversation must never receive that old call's pending transcript.
@MainActor final class ConversationVoiceScope {
    private let store: ConversationStore
    private let activity: ConversationStore.Activity
    private let bot: BotSnapshot?
    private let historyRevision: String?

    init(store: ConversationStore, activity: ConversationStore.Activity, conversation: Conversation) throws {
        self.store = store
        self.activity = activity
        bot = conversation.bot
        historyRevision = conversation.historyRevision
        guard activity.kind == .voice, activity.conversationID == conversation.id else { throw CancellationError() }
        try validate()
    }

    var isCurrent: Bool {
        guard !store.configurationUnavailable, store.activities[activity.conversationID] == activity,
              let current = store.conversations.first(where: { $0.id == activity.conversationID }) else { return false }
        return current.bot == bot && current.historyRevision == historyRevision
    }

    func validate() throws { if !isCurrent { throw CancellationError() } }
}

// The reply's conversation binding survives async capture, compression and
// provider requests. Once tools own the bot hash chain, their dynamic guard
// accepts our own create_skill update while rejecting an external replacement.
@MainActor final class ConversationReplyScope {
    private let store: ConversationStore
    private let activity: ConversationStore.Activity
    private let attemptID: UUID
    private let messageID: UUID
    private let originalBot: BotSnapshot?
    private let originalLetterContext: LetterContext?
    private var localTools: ConversationLocalTools?

    init(store: ConversationStore, activity: ConversationStore.Activity,
         conversation: Conversation, attempt: ReplyAttempt) throws {
        guard activity.kind == .reply, activity.conversationID == conversation.id,
              activity.id == attempt.id else { throw CancellationError() }
        self.store = store
        self.activity = activity
        attemptID = attempt.id
        messageID = attempt.userMessageID
        originalBot = conversation.bot
        originalLetterContext = conversation.letterContext
        try validate()
    }

    // The caller constructs this Context for the same captured Activity/attempt.
    // Association is one-way and occurs before the first local side effect.
    func bindLocalTools(_ tools: ConversationLocalTools) throws {
        guard localTools == nil else { throw CancellationError() }
        try validate()
        try tools.validate()
        localTools = tools
    }

    func validate() throws {
        guard !store.configurationUnavailable,
              store.activities[activity.conversationID] == activity,
              let current = store.conversations.first(where: { $0.id == activity.conversationID }),
              current.letterContext == originalLetterContext,
              current.messages.contains(where: { $0.id == messageID && $0.role == .user }),
              current.replyAttempts?.contains(where: {
                  $0.id == attemptID && $0.userMessageID == messageID &&
                      [.preparing, .submitted].contains($0.phase)
              }) == true else { throw CancellationError() }
        if let localTools { try localTools.validate() }
        else if current.bot != originalBot { throw CancellationError() }
    }
}
