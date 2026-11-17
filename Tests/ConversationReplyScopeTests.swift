import Foundation

@MainActor private struct ScopeFixture {
    let store: ConversationStore
    let activity: ConversationStore.Activity
    let captured: Conversation
    let attempt: ReplyAttempt
    let scope: ConversationReplyScope

    init(directory: URL) throws {
        store = ConversationStore(file: directory.appending(path: "chats.json"))
        let bot = BotSnapshot(name: "synthetic scope", endpoint: "https://synthetic.invalid/v1", model: "scope-model",
                              loginMethod: .byok, apiProtocol: "responses")
        let id = try store.create(bot: bot)
        let question = try store.appendUserMessage("synthetic question", files: [], to: id)
        let (activity, captured, _, attempt) = try store.beginReply(in: id, to: question)
        self.activity = activity; self.captured = captured; self.attempt = attempt
        scope = try ConversationReplyScope(store: store, activity: activity, conversation: captured, attempt: attempt)
    }
    func replaceBot(instructionsOnly: Bool = false) throws {
        let peer = ConversationStore(file: store.file)
        let current = peer.conversations.first!.bot!
        var replacement = current
        if instructionsOnly { replacement.instructions = .init(prompt: "external prompt") }
        else { replacement.model = "external-model" }
        try peer.changeBot(replacement, in: captured.id, expected: current)
        try store.reloadReplica()
        precondition(store.activities[captured.id] == activity)
    }
}

@main @MainActor struct ConversationReplyScopeTests {
    static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        for field in ["model", "instructions"] {
            let fixture = try ScopeFixture(directory: directory.url.appending(path: "unbound-" + field))
            defer { fixture.store.endActivity(fixture.activity) }
            try fixture.scope.validate()
            try fixture.replaceBot(instructionsOnly: field == "instructions")
            do { try fixture.scope.validate(); preconditionFailure("Compression/no-tools scope accepted a replaced bot") }
            catch is CancellationError {}
        }
        let suite = "com.pendingname.aauv.reply-scope." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalToolPreference.enabledKey)
        let fixture = try ScopeFixture(directory: directory.url.appending(path: "dynamic"))
        defer { fixture.store.endActivity(fixture.activity) }
        let tools = try ConversationLocalTools(store: fixture.store, activity: fixture.activity, conversation: fixture.captured,
                                              attempt: fixture.attempt, method: .byok, defaults: defaults, validateRoute: {})
        try fixture.scope.bindLocalTools(tools)
        let result = try await tools.execution.perform(.init(id: nil, callID: "scope_create_skill", name: "create_skill", namespace: "",
                                                            arguments: #"{"name":"scope-skill","description":"synthetic","body":"synthetic skill body"}"#))
        precondition(result.contains(#""subscribed":true"#))
        precondition(fixture.store.conversations.first!.bot != fixture.captured.bot)
        try fixture.scope.validate() // Own create_skill change must remain valid.
        precondition(fixture.store.conversations.first!.bot?.instructions?.skillEntries?.count == 1)
        try fixture.replaceBot()
        do { try fixture.scope.validate(); preconditionFailure("Dynamic tool scope accepted an external bot replacement") }
        catch is ChatClient.ClientError {}

        let ended = try ScopeFixture(directory: directory.url.appending(path: "ended"))
        ended.store.endActivity(ended.activity)
        do { try ended.scope.validate(); preconditionFailure("An ended activity remained valid") }
        catch is CancellationError {}
        print("ConversationReplyScope rejected peer SQLite bot/model/instruction replacement before tools; accepted its own real create_skill hash-chain update after binding; rejected later external replacement and ended intent. Synthetic data only.")
    }
}
