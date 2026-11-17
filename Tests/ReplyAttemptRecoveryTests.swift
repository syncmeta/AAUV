import Foundation

@main @MainActor
struct ReplyAttemptRecoveryTests {
    static func main() throws {
        let directory = try PrivateTemporaryDirectory()
        let file = directory.url.appending(path: "conversations.json")
        let original = ConversationStore(file: file)
        let bot = BotSnapshot(name: "Recovery fixture", endpoint: "https://example.invalid/v1", model: "fixture",
                              loginMethod: .byok, apiProtocol: "responses")
        let id = try original.create(bot: bot)
        let prompt = ChatMessage(role: .user, content: "Preserve this question")
        try original.append(prompt, to: id)
        let prior = ReplyAttempt(userMessageID: prompt.id, phase: .submitted, partial: "Saved partial")
        try original.saveAttempt(prior, to: id)

        // A process can exit without executing the task's failure/defer handlers.
        let restarted = ConversationStore(file: file)
        precondition(restarted.activities.isEmpty)
        let (activity, _, _, current) = try restarted.beginReply(in: id, to: prompt.id)
        defer { restarted.endActivity(activity) }
        let attempts = restarted.conversations.first!.replyAttempts!
        precondition(attempts.filter { [.preparing, .submitted].contains($0.phase) }.count == 1,
                     "Restarted reply retained an orphaned active attempt")
        precondition(attempts.first { $0.id == prior.id }?.phase == .interrupted)
        precondition(attempts.first { $0.id == prior.id }?.partial == "Saved partial")
        precondition(attempts.first { $0.id == current.id }?.phase == .preparing && current.id == activity.id)
        do {
            _ = try restarted.beginReply(in: id, to: prompt.id)
            fatalError("A second live activity started")
        } catch is ChatClient.ClientError {}
        let reopened = ConversationStore(file: file).conversations.first!
        precondition(reopened.bot == bot && reopened.messages.map(\.id) == [prompt.id])
        precondition(reopened.replyAttempts?.first { $0.id == prior.id }?.phase == .interrupted)
        print("Retry after process exit interrupted orphaned durable attempts atomically, retained partial text and allowed only the new live reply.")
    }
}
