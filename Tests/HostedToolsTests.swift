import Foundation

@main
struct HostedToolsTests {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let endpoint = URL(string: CommandLine.arguments[1]) else { throw URLError(.badURL) }
        let configuration = ChatClient.Configuration(baseURL: endpoint, model: "fixture", key: "fixture-key",
                                                    hostedTools: ["web_search", "code_interpreter"])
        var progress: [Set<HostedTool>] = []
        var streamed = ""
        let text = try await ChatClient.reply(to: [.init(role: .user, content: "测试")],
                                              configuration: configuration, proxy: nil,
                                              onDelta: { streamed += $0 }, onTools: { progress.append($0) })
        precondition(streamed == "完成" && text == streamed)
        precondition(progress == [[.webSearch], [.webSearch, .codeInterpreter], [.codeInterpreter], []])
        let summary = try await ChatClient.reply(to: [.init(role: .user, content: "静默调用")],
                                                 configuration: configuration, proxy: nil)
        precondition(summary == "完成")

        let interrupted = ChatClient.Configuration(baseURL: endpoint, model: "fixture-interrupted",
                                                    key: configuration.key, hostedTools: configuration.hostedTools)
        var partial = ""
        do {
            _ = try await ChatClient.reply(to: [.init(role: .user, content: "模拟中断")],
                                           configuration: interrupted, proxy: nil, onDelta: { partial += $0 })
            fatalError("A partial stream must not be saved as a completed response")
        } catch ChatClient.ClientError.stream(let code) {
            precondition(partial == "完成" && code == "stream_ended_without_completion")
            precondition(ChatClient.ClientError.stream(code).localizedDescription.contains("可以重新请求"))
        }
        let failing = ChatClient.Configuration(baseURL: endpoint, model: "fixture-structured-error",
                                                key: configuration.key, hostedTools: configuration.hostedTools)
        partial = ""
        do {
            _ = try await ChatClient.reply(to: [.init(role: .user, content: "模拟明确失败")],
                                           configuration: failing, proxy: nil, onDelta: { partial += $0 })
            fatalError("A structured failure was treated as a completed response")
        } catch ChatClient.ClientError.service(let diagnostic, let detail) {
            precondition(partial == "完成" && diagnostic.status == 200 && diagnostic.shape == "response.failed")
            precondition(diagnostic.code == "subscription_sharing_unsupported_capability" && diagnostic.parameter == "tools[0]")
            precondition(diagnostic.requestID == "req_fixture_response" && detail == nil)
        }
        try checkChatGPTDiagnosticsAndPause()
        try await refuseGeneratedFilesAfterCredentialChange(from: endpoint)
        try await preserveCompletedReplyWhileDownloading(from: endpoint)
        print("Hosted tool progress, structured failures, per-account pause and reply persistence passed.")
    }

    private enum CredentialChanged: Error { case rejected }

    @MainActor
    private static func refuseGeneratedFilesAfterCredentialChange(from endpoint: URL) async throws {
        let configuration = ChatClient.Configuration(baseURL: endpoint, model: "fixture-generated", key: "fixture-key",
                                                    hostedTools: ["web_search", "code_interpreter"])
        var checks = 0
        var completed = false
        var downloads: ChatClient.GeneratedFiles?
        let text = try await ChatClient.reply(
            to: [.init(role: .user, content: "模拟回复后更换授权")], configuration: configuration, proxy: nil,
            validateCredential: {
                checks += 1
                if checks > 1 { throw CredentialChanged.rejected }
            },
            onReplyReady: { reply in completed = reply.text == "完成" && reply.fileCount == 2 },
            onGeneratedFiles: { downloads = $0 }
        )
        precondition(text == "完成" && completed && checks == 2)
        precondition(downloads?.files.isEmpty == true && downloads?.unavailable == 2)
    }

    @MainActor
    private static func checkChatGPTDiagnosticsAndPause() throws {
        let response = HTTPURLResponse(url: ChatGPTPlanSession.endpoint, statusCode: 429, httpVersion: nil,
                                       headerFields: ["x-request-id": "req_fixture_limit"])!
        let body = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Echo fixture-key"}}"#.utf8)
        let error = ChatClient.serviceError(response, body: body, key: "fixture-key", chatGPTPlan: true)
        guard case .service(let diagnostic, let detail) = error else { fatalError("Missing service diagnostic") }
        precondition(diagnostic.usageLimited && diagnostic.status == 429 && diagnostic.shape == "error")
        precondition(diagnostic.requestID == "req_fixture_limit" && detail == "Echo •••")
        precondition(error.localizedDescription.contains("订阅用量受限"))
        let encoded = try JSONEncoder().encode(diagnostic)
        let restored = try JSONDecoder().decode(ChatClient.ServiceDiagnostic.self, from: encoded)
        precondition(restored.usageLimited && !String(decoding: encoded, as: UTF8.self).contains("fixture-key"))
        let folder = try PrivateTemporaryDirectory()
        let file = folder.url.appending(path: "chats.json")
        let store = ConversationStore(file: file)
        let chat = try store.create()
        let prompt = ChatMessage(role: .user, content: "fixture")
        try store.append(prompt, to: chat)
        let attempt = ReplyAttempt(userMessageID: prompt.id, phase: .interrupted, partial: "已收到的片段", diagnostic: diagnostic)
        try store.saveAttempt(attempt, to: chat)
        let reopened = ConversationStore(file: file).conversations.first?.replyAttempts?.last
        precondition(reopened?.diagnostic?.requestID == diagnostic.requestID && reopened?.partial == attempt.partial)

        let suite = "AAUV-usage-fixture-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        defer { defaults.removePersistentDomain(forName: suite) }
        ChatGPTPlanSession.setUsagePaused(true, for: "affected", defaults: defaults)
        try ChatGPTPlanSession.requireUsageAvailable("other", defaults: defaults)
        do {
            try ChatGPTPlanSession.requireUsageAvailable("affected", defaults: defaults)
            fatalError("A paused account could send another request")
        } catch is ChatClient.ClientError {}
        ChatGPTPlanSession.setUsagePaused(false, for: "affected", defaults: defaults)
        try ChatGPTPlanSession.requireUsageAvailable("affected", defaults: defaults)
    }

    @MainActor
    private static func preserveCompletedReplyWhileDownloading(from endpoint: URL) async throws {
        let folder = try PrivateTemporaryDirectory()
        let file = folder.url.appending(path: "chats.json")
        let store = ConversationStore(file: file)
        let id = try store.create()
        let prompt = ChatMessage(role: .user, content: "生成两个文件")
        try store.append(prompt, to: id)
        let (activity, _, _, attempt) = try store.beginReply(in: id, to: prompt.id)
        defer { store.endActivity(activity) }
        let answerID = UUID()
        let configuration = ChatClient.Configuration(baseURL: endpoint, model: "fixture-generated", key: "fixture-key",
                                                    hostedTools: ["web_search", "code_interpreter"])
        let request = Task { @MainActor in
            try await ChatClient.reply(
                to: [prompt], configuration: configuration, proxy: nil,
                onReplyReady: { reply in
                    try store.complete(ChatMessage(id: answerID, role: .assistant, content: reply.text,
                                                    unavailableAttachments: reply.fileCount), attempt: attempt, in: id)
                },
                onGeneratedFiles: { try store.saveReplyAttachments($0, to: answerID, in: id) }
            )
        }
        defer { request.cancel() }
        let waitingURL = endpoint.appending(path: "fixture-download")
        var downloading = false
        for _ in 0..<100 {
            let (status, _) = try await URLSession.shared.data(from: waitingURL)
            if status == Data("1".utf8) { downloading = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(downloading)
        let reopened = ConversationStore(file: file).conversations.first!
        precondition(reopened.messages.last?.id == answerID && reopened.messages.last?.content == "完成")
        precondition(reopened.messages.last?.unavailableAttachments == 2 && reopened.replyAttempts?.isEmpty == true)
        request.cancel()
        let text = try await request.value
        let saved = ConversationStore(file: file)
        let chat = saved.conversations.first!
        precondition(text == "完成" && chat.messages.count == 2 && chat.unansweredPrompt == nil)
        let answer = chat.messages.last!
        precondition(answer.id == answerID && answer.content == text && answer.unavailableAttachments == 1)
        guard let attachment = answer.attachments?.first else { throw CocoaError(.fileReadNoSuchFile) }
        let bytes = try Data(contentsOf: saved.attachmentURL(attachment))
        precondition(attachment.name == "complete.bin" && bytes == Data([0, 255, 12]))
    }
}
