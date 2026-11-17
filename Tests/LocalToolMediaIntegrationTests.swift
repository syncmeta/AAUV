import Foundation

@MainActor private final class WeakMediaContext {
    weak var value: ConversationLocalTools?
    init(_ value: ConversationLocalTools) { self.value = value }
}

@main @MainActor
struct LocalToolMediaIntegrationTests {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
    private static let fileBytes = Data("FILE_CONTENT_SYNTHETIC_ONLY".utf8)

    private static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(value, file: file, line: line)
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2, let root = URL(string: CommandLine.arguments[1]),
              root.scheme == "http", root.host == "127.0.0.1" else {
            fatalError("This test only accepts its synthetic loopback peer")
        }
        let suite = "com.pendingname.aauv.media-integration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalToolPreference.enabledKey)
        defaults.set("synthetic-tools", forKey: LocalToolPreference.revisionKey)
        defaults.set("synthetic-credentials", forKey: APIKey.revisionKey)
        defaults.set(LoginMethod.byok.rawValue, forKey: "loginMethod")
        check(ProxyRoutePreference(defaults: defaults).setRequired(false))
        let directory = try PrivateTemporaryDirectory()
        let proxy = SingBox(defaults: defaults)
        try await completeMediaRoundTrip(root: root, directory: directory.url, defaults: defaults, proxy: proxy)
        try await retainCompletedImageOnCancellation(root: root, directory: directory.url, defaults: defaults, proxy: proxy)
        for change in ["preferences", "configuration"] {
            try await rejectChangedImageScope(change, root: root, directory: directory.url, defaults: defaults, proxy: proxy)
        }
        try await releaseConfiguredContext(root: root, directory: directory.url, defaults: defaults, proxy: proxy)
        print("Media tools crossed loopback provider endpoints/protocols without inherited history/instructions/tools; scoped attachment IDs, dataURL images on one durable assistant reply, cancellation retention, stale-scope rejection and Context release passed.")
    }

    private static func bot(_ endpoint: URL, model: String = "media-parent", api: String = "responses") -> BotSnapshot {
        .init(name: "Media fixture", endpoint: endpoint.absoluteString, model: model, loginMethod: .byok,
              apiProtocol: api, hostedTools: api == "responses" ? ["web_search"] : [])
    }

    private static func session(_ bot: BotSnapshot, instructions: String, key: String, proxy: SingBox) async throws -> ModelSession {
        try await ModelSession(bot: bot, instructions: instructions, proxy: proxy, readBYOK: { endpoint, validate in
            check(endpoint == URL(string: bot.endpoint))
            try validate()
            return RequestCredentials(key: key, validate: validate)
        })
    }

    private static func conversation(_ store: ConversationStore, _ id: UUID) throws -> Conversation {
        guard let value = store.conversations.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        return value
    }

    private static func configure(_ context: ConversationLocalTools, session: ModelSession,
                                  store: ConversationStore, bot: BotSnapshot, defaults: UserDefaults,
                                  proxy: SingBox, root: URL) {
        let delegation = LocalModelDelegation(store: store, current: bot, defaults: defaults)
        context.configureCloud(session: session, proxy: nil, delegation: delegation, makeDelegateSession: { target in
            check(target.endpoint == root.appending(path: "other/v1").absoluteString)
            check(target.apiProtocol == "chat_completions" && target.model == "media-child")
            return try await self.session(target, instructions: "TARGET_PROFILE_PRIVATE_SHOULD_NOT_SEND", key: "media-child-key", proxy: proxy)
        })
    }

    private static func completeMediaRoundTrip(root: URL, directory: URL, defaults: UserDefaults, proxy: SingBox) async throws {
        let store = ConversationStore(file: directory.appending(path: "round-trip/chats.json"))
        let parentBot = bot(root.appending(path: "parent/v1"))
        let child = LocalBot(configuration: bot(root.appending(path: "other/v1"), model: "media-child", api: "chat_completions"))
        try store.saveBots([child])
        let id = try store.create(bot: parentBot)
        let foreignID = try store.create(bot: parentBot)
        let source = try store.saveGeneratedFile(.init(name: "fixture-source.txt", data: fileBytes))
        let foreign = try store.saveGeneratedFile(.init(name: "FOREIGN_PRIVATE_NAME.txt", data: Data("FOREIGN_PRIVATE_BYTES".utf8)))
        try store.append(ChatMessage(role: .user, content: "PARENT_HISTORY_PRIVATE", attachments: [source]), to: id)
        try store.append(ChatMessage(role: .assistant, content: "PARENT_OLD_REPLY_PRIVATE"), to: id)
        try store.append(ChatMessage(role: .user, content: "FOREIGN_PRIVATE_HISTORY", attachments: [foreign]), to: foreignID)
        let question = try store.appendUserMessage("PARENT_CURRENT_MAIN", files: [], to: id)
        let (activity, captured, _, originalAttempt) = try store.beginReply(in: id, to: question)
        defer { store.endActivity(activity) }
        var attempt = originalAttempt
        let context = try ConversationLocalTools(store: store, activity: activity, conversation: captured, attempt: attempt,
                                                method: .byok, defaults: defaults, validateRoute: proxy.requestRoute().validate)
        let manifest = ConversationLocalTools.attachmentManifest(captured.allAttachments)
        check(manifest.contains(source.id.uuidString.lowercased()) && !manifest.contains(foreign.id.uuidString.lowercased()))
        check(!manifest.contains("FOREIGN_PRIVATE_NAME") && !manifest.contains(store.attachmentDirectory.path))
        let delegation = LocalModelDelegation(store: store, current: parentBot, defaults: defaults)
        let parent = try await session(parentBot, instructions: "PARENT_SYSTEM_PRIVATE\n" + manifest + "\n" + delegation.manifest,
                                       key: "media-parent-key", proxy: proxy)
        configure(context, session: parent, store: store, bot: parentBot, defaults: defaults, proxy: proxy, root: root)
        let foreignCall = LocalToolCall(id: nil, callID: "foreign_probe", name: "read_attachment", namespace: "",
                                       arguments: "{\"attachment_id\":\"\(foreign.id.uuidString)\",\"question\":\"foreign\"}")
        let rejected = try await context.execution.perform(foreignCall)
        check(rejected.contains("attachment_not_found") && !rejected.contains("FOREIGN_PRIVATE"))
        var replyID: UUID?
        var deliveries = 0
        let text = try await parent.reply(to: captured.messages, localExecution: context.execution,
                                         willSend: { attempt.phase = .submitted; try store.saveAttempt(attempt, to: id) },
                                         onReplyReady: { reply in
            check(reply.fileCount == 1)
            let message = ChatMessage(role: .assistant, content: reply.text, unavailableAttachments: reply.fileCount)
            try store.complete(message, attempt: attempt, in: id)
            replyID = message.id
            deliveries += 1
        }, onGeneratedFiles: { generated in
            check(generated.files.count == 1 && generated.unavailable == 0 && replyID != nil)
            try store.saveReplyAttachments(generated, to: replyID!, in: id)
        })
        check(text == "MEDIA_TOOLS_START\n\nMEDIA_TOOLS_COMPLETE" && deliveries == 1)
        let reopened = ConversationStore(file: store.file)
        let durable = try conversation(reopened, id)
        let answer = durable.messages.first(where: { $0.id == replyID })!
        check(answer.replyTo == question && answer.attachments?.count == 1 && answer.unavailableAttachments == nil)
        check(durable.messages.filter { $0.replyTo == question }.count == 1 && durable.replyAttempts?.isEmpty == true)
        let attachment = answer.attachments![0]
        check(attachment.name == "sent-image-1.png")
        check(try Data(contentsOf: reopened.attachmentURL(attachment)) == png)
        check(try conversation(reopened, foreignID).messages.map(\.content) == ["FOREIGN_PRIVATE_HISTORY"])
        let overridden = try await parent.reply(to: [.init(role: .user, content: "OVERRIDE_STANDALONE_ONLY")],
                                                forSummary: true, modelOverride: "media-override")
        check(overridden == "OVERRIDE_ONLY_ANSWER")
    }

    private static func imageCall(_ id: String) -> LocalToolCall {
        let arguments = "{\"images\":[\"data:image/png;base64,\(png.base64EncodedString())\"]}"
        return .init(id: "fc_" + id, callID: id, name: "send_images", namespace: "", arguments: arguments)
    }

    private static func retainCompletedImageOnCancellation(root: URL, directory: URL, defaults: UserDefaults, proxy: SingBox) async throws {
        let store = ConversationStore(file: directory.appending(path: "cancel/chats.json"))
        let parentBot = bot(root.appending(path: "parent/v1"))
        let id = try store.create(bot: parentBot)
        let question = try store.appendUserMessage("synthetic cancellation", files: [], to: id)
        let (activity, captured, _, attempt) = try store.beginReply(in: id, to: question)
        defer { store.endActivity(activity) }
        let context = try ConversationLocalTools(store: store, activity: activity, conversation: captured, attempt: attempt,
                                                method: .byok, defaults: defaults, validateRoute: proxy.requestRoute().validate)
        let parent = try await session(parentBot, instructions: "PRIVATE", key: "media-parent-key", proxy: proxy)
        configure(context, session: parent, store: store, bot: parentBot, defaults: defaults, proxy: proxy, root: root)
        let base = context.execution
        var performed = 0
        let execution = LocalToolExecution(names: base.names, namespace: base.namespace, validate: base.validate,
                                           drainGenerated: base.drainGenerated, perform: { call in
            let result = try await base.perform(call)
            performed += 1
            withUnsafeCurrentTask { $0?.cancel() } // User stops after one completed image call.
            return result
        })
        var sends = 0
        var replyID: UUID?
        var saved = 0
        let task = Task {
            try await ResponseToolLoop.run(execution: execution, send: { _ in
                sends += 1
                check(sends == 1)
                return .init(reply: .init(text: ""), outputJSON: Data("[]".utf8),
                             calls: [imageCall("cancel_image_one"), imageCall("must_not_run")])
            }, onReplyReady: { reply in
                let message = ChatMessage(role: .assistant, content: "retained image", unavailableAttachments: reply.fileCount)
                try store.complete(message, attempt: attempt, in: id)
                replyID = message.id
            }, onGeneratedFiles: { generated in
                check(generated.files.count == 1 && replyID != nil)
                try store.saveReplyAttachments(generated, to: replyID!, in: id)
                saved += 1
            })
        }
        do { _ = try await task.value; preconditionFailure("Cancellation unexpectedly continued the tool loop.") }
        catch is CancellationError {}
        check(performed == 1 && sends == 1 && saved == 1)
        let answer = try conversation(store, id).messages.first(where: { $0.id == replyID })!
        check(answer.replyTo == question && answer.attachments?.count == 1)
    }

    private static func rejectChangedImageScope(_ change: String, root: URL, directory: URL, defaults: UserDefaults, proxy: SingBox) async throws {
        let store = ConversationStore(file: directory.appending(path: "stale-\(change)/chats.json"))
        let parentBot = bot(root.appending(path: "parent/v1"))
        let id = try store.create(bot: parentBot)
        let question = try store.appendUserMessage("synthetic stale scope", files: [], to: id)
        let (activity, captured, _, attempt) = try store.beginReply(in: id, to: question)
        defer { store.endActivity(activity) }
        let context = try ConversationLocalTools(store: store, activity: activity, conversation: captured, attempt: attempt,
                                                method: .byok, defaults: defaults, validateRoute: proxy.requestRoute().validate)
        let parent = try await session(parentBot, instructions: "PRIVATE", key: "media-parent-key", proxy: proxy)
        configure(context, session: parent, store: store, bot: parentBot, defaults: defaults, proxy: proxy, root: root)
        let base = context.execution
        let execution = LocalToolExecution(names: base.names, namespace: base.namespace, validate: base.validate,
                                           drainGenerated: base.drainGenerated, perform: { call in
            let result = try await base.perform(call)
            // Invalidate the original host scope before drain/delivery.
            if change == "configuration" { defaults.set(UUID().uuidString, forKey: ProxyNodes.revisionKey) }
            else { LocalToolPreference.save(false, in: defaults) }
            return result
        })
        defer { LocalToolPreference.save(true, in: defaults) }
        var delivered = false
        do {
            _ = try await ResponseToolLoop.run(execution: execution, send: { _ in
                .init(reply: .init(text: ""), outputJSON: Data("[]".utf8), calls: [imageCall("stale_image")])
            }, onReplyReady: { _ in delivered = true }, onGeneratedFiles: { _ in delivered = true })
            preconditionFailure("A changed scope received prepared media.")
        } catch {}
        let durable = try conversation(store, id)
        check(!delivered && durable.messages.filter { $0.role == .assistant }.isEmpty)
    }

    private static func releaseConfiguredContext(root: URL, directory: URL, defaults: UserDefaults, proxy: SingBox) async throws {
        let store = ConversationStore(file: directory.appending(path: "lifetime/chats.json"))
        let parentBot = bot(root.appending(path: "parent/v1"))
        let id = try store.create(bot: parentBot)
        let question = try store.appendUserMessage("synthetic lifecycle", files: [], to: id)
        let (activity, captured, _, attempt) = try store.beginReply(in: id, to: question)
        defer { store.endActivity(activity) }
        let parent = try await session(parentBot, instructions: "PRIVATE", key: "media-parent-key", proxy: proxy)
        var context: ConversationLocalTools? = try ConversationLocalTools(store: store, activity: activity, conversation: captured,
                                                                          attempt: attempt, method: .byok, defaults: defaults,
                                                                          validateRoute: proxy.requestRoute().validate)
        let released = WeakMediaContext(context!)
        configure(context!, session: parent, store: store, bot: parentBot, defaults: defaults, proxy: proxy, root: root)
        context = nil
        check(released.value == nil)
    }
}
