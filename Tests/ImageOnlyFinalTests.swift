import Foundation
import Darwin

@main @MainActor struct ImageOnlyFinalTests {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2, let root = URL(string: CommandLine.arguments[1]), root.host == "127.0.0.1" else { fatalError("Synthetic loopback only") }
        let before = CommandLine.arguments.contains("--before")
        let suite = "com.pendingname.aauv.image-only-final." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalToolPreference.enabledKey)
        precondition(ProxyRoutePreference(defaults: defaults).setRequired(false))
        let directory = try PrivateTemporaryDirectory()
        let modes = before ? ["image"] : ["image", "ordinary", "missing", "cancelled", "incomplete", "stale"]
        for mode in modes {
            defaults.set("synthetic-config-" + mode, forKey: ProxyNodes.revisionKey)
            let store = ConversationStore(file: directory.url.appending(path: mode + "/chats.json"))
            let bot = BotSnapshot(name: "synthetic", endpoint: root.appending(path: mode + "/v1").absoluteString,
                                  model: mode, loginMethod: .byok, apiProtocol: "responses", hostedTools: [])
            let id = try store.create(bot: bot)
            let user = try store.appendUserMessage("synthetic image request", files: [], to: id)
            let (activity, captured, _, attempt) = try store.beginReply(in: id, to: user)
            let proxy = SingBox(defaults: defaults)
            let session = try await ModelSession(bot: bot, instructions: "", proxy: proxy, readBYOK: { _, validate in
                RequestCredentials(key: "synthetic-image-final-key", validate: validate)
            })
            let context = try ConversationLocalTools(store: store, activity: activity, conversation: captured, attempt: attempt,
                                                    method: .byok, defaults: defaults, validateRoute: proxy.requestRoute().validate)
            context.configureCloud(session: session, proxy: nil)
            var replies = 0, files = 0, sends = 0
            var replyID: UUID?
            var failure: Error?
            do {
                let answer = try await session.reply(to: captured.messages, localExecution: context.execution, willSend: {
                    sends += 1
                    if mode == "stale" && sends == 2 { defaults.set("changed", forKey: ProxyNodes.revisionKey) }
                }, onReplyReady: { reply in
                    replies += 1
                    let message = ChatMessage(role: .assistant, content: reply.text.isEmpty ? "image-only" : reply.text,
                                              unavailableAttachments: reply.fileCount)
                    try store.complete(message, attempt: attempt, in: id)
                    replyID = message.id
                }, onGeneratedFiles: { generated in
                    files += generated.files.count
                    try store.saveReplyAttachments(generated, to: replyID!, in: id)
                })
                precondition(answer.isEmpty)
            } catch { failure = error }
            store.endActivity(activity)
            if before {
                if let failure {
                    print("Before reproduction: prepared image + completed empty final failed: \(failure.localizedDescription); delivered replies=\(replies), images=\(files)")
                    exit(1)
                }
                fatalError("The before regression unexpectedly succeeded")
            }
            if mode == "image" {
                precondition(failure == nil && replies == 1 && files == 1 && sends == 2)
                let reopened = ConversationStore(file: store.file)
                let durable = reopened.conversations.first(where: { $0.id == id })!
                let answers = durable.messages.filter { $0.role == .assistant }
                precondition(answers.count == 1 && answers[0].replyTo == user && answers[0].attachments?.count == 1)
                precondition(durable.replyAttempts?.isEmpty == true)
            } else {
                precondition(failure != nil, "Invalid/absent terminal or unprepared images returned success")
                if ["ordinary", "stale"].contains(mode) { precondition(replies == 0 && files == 0) }
            }
        }
        print("Image-only final: actual ModelSession/HTTP/Context/SQLite saved one assistant + image on successful empty final; ordinary empty, missing/cancelled/incomplete terminal and stale scope still failed.")
    }
}
