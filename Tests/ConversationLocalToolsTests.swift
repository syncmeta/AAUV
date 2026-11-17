import AAUVCore
import Foundation

@main @MainActor
struct ConversationLocalToolsTests {
    private static let historyText = "needle CURRENT_CONVERSATION_ONLY"
    private static let foreignText = "needle OTHER_CONVERSATION_PRIVATE"
    private static let globalPrompt = "GLOBAL_PROMPT_ONCE"
    private static let skillName = "fixture-conversation-skill"
    private static let skillBody = "SKILL_BODY_FIXTURE"
    private static let expectedReply = "已检索\n\n已创建\n\n再次检索\n\n全部完成"

    private static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition, file: file, line: line) }

    static func main() async throws {
        guard CommandLine.arguments.count == 2, let root = URL(string: CommandLine.arguments[1]),
              root.scheme == "http", root.host == "127.0.0.1" else {
            fatalError("This fixture accepts only its loopback HTTP server")
        }
        let suite = "com.pendingname.aauv.conversation-tools-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalToolPreference.enabledKey)
        defaults.set("fixture-tools-revision", forKey: LocalToolPreference.revisionKey)
        defaults.set("fixture-credentials-revision", forKey: APIKey.byokRevisionKey)
        defaults.set("fixture-configuration-revision", forKey: ProxyNodes.revisionKey)
        check(ProxyRoutePreference(defaults: defaults).setRequired(false))
        let directory = try PrivateTemporaryDirectory()
        try await roundTrip(root: root, directory: directory.url, defaults: defaults)
        try await rejectStaleContexts(root: root, directory: directory.url, defaults: defaults)
        try await chatGPTCredentialRotation(root: root, directory: directory.url, defaults: defaults)
        try await rejectConfigurationChangedInWillSend(root: root, directory: directory.url, defaults: defaults)
        print("Conversation local tools traversed ModelSession, ChatClient and SQLite across four loopback HTTP rounds; scoped search, durable skills, opaque continuation, reply recovery, ChatGPT rotation/import epochs and pre-submit scope rejection passed.")
    }

    private static func bot(endpoint: URL) -> BotSnapshot {
        BotSnapshot(name: "Local tools fixture", endpoint: endpoint.absoluteString, model: "fixture-model",
                    loginMethod: .byok, apiProtocol: "responses", hostedTools: [],
                    profileID: UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"))
    }

    private static func readConversation(_ store: ConversationStore, _ id: UUID) throws -> Conversation {
        guard let conversation = store.conversations.first(where: { $0.id == id }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return conversation
    }

    private static func registerBot(in store: ConversationStore, endpoint: URL) throws -> BotSnapshot {
        let configuration = bot(endpoint: endpoint)
        let profile = LocalBot(id: configuration.profileID!, configuration: configuration)
        try store.saveBots([profile])
        guard let saved = store.bots.first(where: { $0.id == profile.id }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return saved.snapshot
    }

    private static func roundTrip(root: URL, directory: URL, defaults: UserDefaults) async throws {
        let file = directory.appending(path: "round-trip/conversations.json")
        let endpoint = root.appending(path: "four-rounds/v1")
        let store = ConversationStore(file: file)
        check(store.loadError == nil)
        try store.saveInstructions(BotInstructions(prompt: globalPrompt))
        let configuredBot = try registerBot(in: store, endpoint: endpoint)
        let currentID = try store.create(bot: configuredBot)
        let otherID = try store.create(bot: configuredBot)
        let earlier = ChatMessage(role: .user, content: historyText, date: Date().addingTimeInterval(-60))
        try store.append(earlier, to: currentID)
        try store.append(ChatMessage(role: .assistant, content: "先前回复", date: Date().addingTimeInterval(-50), replyTo: earlier.id), to: currentID)
        try store.append(ChatMessage(role: .user, content: foreignText), to: otherID)
        let questionID = try store.appendUserMessage("请完成测试工具循环。", files: [], to: currentID)
        let (activity, conversation, _, initialAttempt) = try store.beginReply(in: currentID, to: questionID)
        defer { store.endActivity(activity) }
        var attempt = initialAttempt
        let proxy = SingBox(defaults: defaults)
        let route = try proxy.requestRoute()
        let context = try ConversationLocalTools(store: store, activity: activity, conversation: conversation,
                                                attempt: attempt, method: .byok, defaults: defaults,
                                                validateRoute: route.validate)
        let instructions = try store.readInstructions().requestInstructions
        var credentialReads = 0
        let session = try await ModelSession(bot: conversation.bot!, instructions: instructions, proxy: proxy,
                                            readBYOK: { url, validateRoute in
            check(url == endpoint)
            credentialReads += 1
            try validateRoute()
            return RequestCredentials(key: "local-tools-fixture-key", validate: {
                try validateRoute()
                guard defaults.string(forKey: APIKey.byokRevisionKey) == "fixture-credentials-revision" else {
                    throw ChatClient.ClientError.message("Synthetic credential revision changed")
                }
            })
        })
        var sends = 0
        var deltaWrites = 0
        var readyWrites = 0
        var observedSkillUUIDReencoding = false
        var statuses: [String] = []
        var replyID: UUID?

        func checkpoint() throws {
            try store.saveAttempt(attempt, to: currentID)
            // A second SQLite connection proves these callbacks really commit,
            // including the partial reply needed after a process restart.
            let recovered = ConversationStore(file: file)
            let durable = try readConversation(recovered, currentID)
            let saved = durable.replyAttempts?.first(where: { $0.id == attempt.id })
            check(saved?.phase == .submitted && saved?.partial == attempt.partial)
            if let created = durable.bot?.instructions?.skillEntries?.first(where: { $0.name == skillName }) {
                var error: NSError?
                let snapshot = try store.requireDatabase().snapshot(&error)
                if let error { throw error }
                check(snapshot.contains(created.id.uuidString))
                observedSkillUUIDReencoding = true
            }
        }

        let answer = try await session.reply(
            to: conversation.messages, localExecution: context.execution,
            willSend: {
                sends += 1
                attempt.phase = .submitted
                try checkpoint()
            },
            onDelta: { delta in
                attempt.partial += delta
                deltaWrites += 1
                try checkpoint()
            },
            onLocalTool: { if let name = $0 { statuses.append(name) } },
            onReplyReady: { reply in
                check(reply.text == expectedReply)
                let message = ChatMessage(role: .assistant, content: reply.text)
                try store.complete(message, attempt: attempt, in: currentID)
                replyID = message.id
                readyWrites += 1
            }
        )
        check(answer == expectedReply && attempt.partial == expectedReply)
        check(credentialReads == 1 && sends == 4 && deltaWrites >= 4 && readyWrites == 1)
        check(statuses == ["search_chat_history", "create_skill", "search_chat_history"])
        check(observedSkillUUIDReencoding)
        check(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("sqlite3").path))
        store.endActivity(activity)

        let restarted = ConversationStore(file: file)
        let durable = try readConversation(restarted, currentID)
        check(durable.replyAttempts?.isEmpty == true && restarted.activities.isEmpty)
        let reply = durable.messages.first(where: { $0.id == replyID })
        check(reply?.content == expectedReply && reply?.replyTo == questionID)
        check(try readConversation(restarted, otherID).messages.map(\.content) == [foreignText])
        let library = try restarted.readInstructions()
        let globalSkill = library.skillEntries?.filter { $0.name == skillName } ?? []
        let chatSkill = durable.bot?.instructions?.skillEntries?.filter { $0.name == skillName } ?? []
        check(globalSkill.count == 1 && chatSkill.count == 1)
        check(!globalSkill[0].enabled && chatSkill[0].enabled && globalSkill[0].id == chatSkill[0].id)
        check(library.prompt == globalPrompt && durable.bot?.instructions?.prompt == "")
        let nextInstructions = [library.requestInstructions, durable.bot?.instructions?.requestInstructions ?? ""].joined(separator: "\n\n")
        check(nextInstructions.components(separatedBy: globalPrompt).count - 1 == 1)
        check(nextInstructions.components(separatedBy: skillBody).count - 1 == 1)
        // Skill creation leaves a usable current context, but a completed durable
        // reply invalidates the old request before another local side effect.
        await rejected { try await context.execution.perform(.init(id: nil, callID: "late_create", name: "create_skill", namespace: "",
                                                                    arguments: #"{"name":"late-skill","description":"","body":"no"}"#)) }
        check(try restarted.readInstructions().skillEntries?.count == 1)
    }

    private static func rejectStaleContexts(root: URL, directory: URL, defaults: UserDefaults) async throws {
        for change in ["preferences", "credentials", "configuration", "activity", "bot"] {
            defaults.set(true, forKey: LocalToolPreference.enabledKey)
            defaults.set("fixture-tools-revision", forKey: LocalToolPreference.revisionKey)
            defaults.set("fixture-credentials-revision", forKey: APIKey.byokRevisionKey)
            defaults.set("fixture-configuration-revision", forKey: ProxyNodes.revisionKey)
            let file = directory.appending(path: "guard-\(change)/conversations.json")
            let store = ConversationStore(file: file)
            let original = try registerBot(in: store, endpoint: root.appending(path: "never-requested/v1"))
            let id = try store.create(bot: original)
            let question = try store.appendUserMessage("guard", files: [], to: id)
            let (activity, conversation, _, attempt) = try store.beginReply(in: id, to: question)
            let context = try ConversationLocalTools(store: store, activity: activity, conversation: conversation,
                                                    attempt: attempt, method: .byok, defaults: defaults, validateRoute: {})
            switch change {
            case "preferences": LocalToolPreference.save(false, in: defaults)
            case "credentials": defaults.set("changed", forKey: APIKey.byokRevisionKey)
            case "configuration": defaults.set("changed", forKey: ProxyNodes.revisionKey)
            case "activity": store.endActivity(activity)
            default:
                // A second window/device adapter writes the same SQLite store.
                let peer = ConversationStore(file: file)
                var replacement = original
                replacement.model = "changed-model"
                replacement.profileID = nil
                try peer.changeBot(replacement, in: id, expected: original)
                try store.reloadReplica()
            }
            await rejected {
                try await context.execution.perform(.init(id: nil, callID: "stale_\(change)", name: "create_skill", namespace: "",
                                                           arguments: #"{"name":"must-not-create","description":"","body":"no"}"#))
            }
            check(try store.readInstructions().skillEntries?.isEmpty != false)
            store.endActivity(activity)
        }
    }

    private static func chatGPTCredentialRotation(root: URL, directory: URL, defaults: UserDefaults) async throws {
        defaults.set(true, forKey: LocalToolPreference.enabledKey)
        defaults.set("fixture-configuration-before-import", forKey: ProxyNodes.revisionKey)
        defaults.set("fixture-chatgpt-before-refresh", forKey: APIKey.revisionKey)
        let store = ConversationStore(file: directory.appending(path: "chatgpt-epoch/conversations.json"))
        var original = bot(endpoint: root.appending(path: "never-requested/v1"))
        original.loginMethod = .chatgpt
        original.chatGPTClientID = "oaiapp_synthetic_context_epoch"
        let id = try store.create(bot: original)
        let question = try store.appendUserMessage("synthetic ChatGPT scope", files: [], to: id)
        let (activity, captured, _, attempt) = try store.beginReply(in: id, to: question)
        defer { store.endActivity(activity) }
        // This checks the real Context's bound ChatGPT scope without constructing
        // ModelSession, resolving a token or accessing any Keychain account.
        let context = try ConversationLocalTools(store: store, activity: activity, conversation: captured,
                                                attempt: attempt, method: .chatgpt, defaults: defaults, validateRoute: {})
        defaults.set("fixture-chatgpt-after-refresh", forKey: APIKey.revisionKey)
        try context.validate()
        check(try readConversation(store, id).bot == original)
        defaults.set("fixture-configuration-after-import", forKey: ProxyNodes.revisionKey)
        await rejected {
            try await context.execution.perform(.init(id: nil, callID: "same_cid_after_import", name: "create_skill",
                                                       namespace: "aauv", arguments: #"{"name":"must-not-create","description":"","body":"no"}"#))
        }
        check(try readConversation(store, id).bot == original)
        check(try store.readInstructions().skillEntries?.isEmpty != false)
    }

    private static func rejectConfigurationChangedInWillSend(root: URL, directory: URL, defaults: UserDefaults) async throws {
        defaults.set(true, forKey: LocalToolPreference.enabledKey)
        defaults.set("fixture-configuration-before-submit", forKey: ProxyNodes.revisionKey)
        let store = ConversationStore(file: directory.appending(path: "pre-submit/conversations.json"))
        let original = bot(endpoint: root.appending(path: "never-submitted/v1"))
        let id = try store.create(bot: original)
        let question = try store.appendUserMessage("must not leave this device", files: [], to: id)
        let (activity, captured, _, attempt) = try store.beginReply(in: id, to: question)
        defer { store.endActivity(activity) }
        let proxy = SingBox(defaults: defaults)
        let context = try ConversationLocalTools(store: store, activity: activity, conversation: captured,
                                                attempt: attempt, method: .byok, defaults: defaults,
                                                validateRoute: proxy.requestRoute().validate)
        let session = try await ModelSession(bot: original, instructions: "", proxy: proxy, readBYOK: { _, validate in
            try validate()
            return RequestCredentials(key: "synthetic-never-submitted-key", validate: validate)
        })
        var callbacks = 0
        await rejected {
            try await session.reply(to: captured.messages, localExecution: context.execution, willSend: {
                callbacks += 1
                defaults.set("fixture-configuration-changed-in-callback", forKey: ProxyNodes.revisionKey)
            }, onReplyReady: { _ in preconditionFailure("A stale request received a reply") })
        }
        // The HTTP fixture rejects every route except its original four rounds.
        // A callback ran, but no request may reach the loopback server here.
        check(callbacks == 1)
        check(try readConversation(store, id).messages.filter { $0.role == .assistant }.isEmpty)
    }

    private static func rejected(_ action: @MainActor () async throws -> String) async {
        do { _ = try await action(); fatalError("A stale local context performed a tool") }
        catch is ChatClient.ClientError {}
        catch { fatalError("Expected the local context guard, got \(type(of: error))") }
    }
}
