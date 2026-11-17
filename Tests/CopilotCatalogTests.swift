import Foundation

@main
struct CopilotCatalogTests {
    private enum Rejected: Error { case routeChanged }

    @MainActor static func main() async throws {
        let catalog = try await CopilotClient.models(token: "gho_catalog_fixture",
                                                      proxyURL: URL(string: "http://127.0.0.1:18888"))
        precondition(catalog.map(\.id) == ["fast", "restricted", "default-name"])
        precondition(catalog.map(\.name) == ["Fast fixture", "Restricted fixture", "default-name"])
        precondition(catalog.map(\.allowed) == [true, false, true])
        do {
            _ = try await CopilotClient.models(token: "gho_denied_fixture", proxyURL: nil)
            fatalError("Unauthenticated runtime returned models")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("未接受当前授权"))
        }
        let empty = try await CopilotClient.models(token: "gho_empty_fixture", proxyURL: nil)
        precondition(empty.isEmpty)

        let scratch = try PrivateTemporaryDirectory()
        let file = scratch.url.appending(path: "profiles/chats.json")
        let store = ConversationStore(file: file)
        let bot = LocalBot(configuration: BotSnapshot(name: "默认模型", endpoint: "https://github.com", model: "",
                                                      loginMethod: .copilot))
        try store.saveBots([bot])
        let reopened = ConversationStore(file: file)
        precondition(reopened.bots.first?.configuration.model == "")
        let reply = try await CopilotClient.reply(to: [.init(role: .user, content: "使用默认模型")],
                                                   model: "", instructions: "", token: "gho_reply_fixture", proxyURL: nil)
        precondition(reply == "默认模型已收到")

        let fileURL = scratch.url.appending(path: "attachment")
        try Data([0, 255]).write(to: fileURL)
        let attachment = RequestAttachment(name: "sample.bin", mediaType: "application/octet-stream", url: fileURL, size: 2)
        let messages: [ChatMessage] = [.init(role: .user, content: "请读取附件")]
        var streamed = ""
        var checks = 0
        let attachedReply = try await CopilotClient.reply(
            to: messages, model: "", instructions: "", token: "gho_reply_fixture", proxyURL: nil, files: [attachment],
            validate: { checks += 1 }, willSend: {
                precondition(checks == 2)
                try FileManager.default.removeItem(at: fileURL)
            }, onDelta: { streamed += $0 }
        )
        precondition(attachedReply == "附件已收到" && streamed == attachedReply)
        do {
            _ = try await CopilotClient.models(token: "gho_blocked_fixture", proxyURL: nil, validateRoute: {
                throw Rejected.routeChanged
            })
            fatalError("Invalidated request reached the runtime")
        } catch Rejected.routeChanged {}

        checks = 0
        do {
            _ = try await CopilotClient.reply(
                to: messages, model: "", instructions: "", token: "gho_reply_fixture", proxyURL: nil,
                validate: {
                    checks += 1
                    if checks == 2 { throw Rejected.routeChanged }
                }, willSend: { fatalError("An invalidated request was marked submitted") }
            )
            fatalError("The route change did not stop the request")
        } catch Rejected.routeChanged {}

        let cancellation = Task {
            try await CopilotClient.reply(
                to: [.init(role: .user, content: "取消回复")], model: "", instructions: "",
                token: "gho_reply_fixture", proxyURL: nil, onDelta: { delta in
                    precondition(delta == "部分回复")
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        do {
            _ = try await cancellation.value
            fatalError("Cancellation returned a completed reply")
        } catch is CancellationError {}
        print("Copilot model catalog, attachment bytes, streaming, cancellation and route validation passed.")
    }
}
