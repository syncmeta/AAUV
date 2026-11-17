import AAUVCore
import Foundation

@main
struct LargeInlineAttachmentTests {
    @MainActor static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        let file = directory.url.appending(path: "附件.fixture-unknown")
        let size = 17 * 1024 * 1024 + 1
        try Data([255, 21, 0]).write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seek(toOffset: UInt64(size - 3))
        try writer.write(contentsOf: Data([0, 42, 254]))
        try writer.close()
        let item = RequestAttachment(name: file.lastPathComponent, mediaType: "application/octet-stream", url: file, size: size)
        let image = directory.url.appending(path: "image.png")
        try Data([137, 80, 78, 71]).write(to: image)
        let png = RequestAttachment(name: image.lastPathComponent, mediaType: "image/png", url: image, size: 4)

        // Validate the actual ChatGPT plan request without ever using a real account or network.
        let part = InlineRequestBody.File(attachment: item)
        let planInput: [String: Any] = [
            "base_url": "https://api.openai.com/v1", "protocol": "responses", "credential_kind": "chatgpt_plan",
            "model": "fixture", "messages": [["role": "user", "content": "测试"]], "files": [part.fields]
        ]
        var error: NSError?
        let planJSON = AauvcoreBuildRequest(String(decoding: try JSONSerialization.data(withJSONObject: planInput), as: UTF8.self), &error)
        if let error { throw error }
        let plan = try JSONSerialization.jsonObject(with: Data(planJSON.utf8)) as! [String: Any]
        precondition(plan["url"] as? String == "https://api.openai.com/v1/responses" && plan["streaming"] as? Bool == true)
        let body = try InlineRequestBody(template: JSONSerialization.data(withJSONObject: plan["body"]!), files: [part])
        precondition(body.size > size)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: body.url)) as! [String: Any]
        precondition(payload["store"] as? Bool == false)
        let messages = payload["input"] as! [[String: Any]]
        let content = messages.last!["content"] as! [[String: String]]
        let encoded = content.last!["file_data"]!.split(separator: ",", maxSplits: 1)[1]
        precondition(Data(base64Encoded: String(encoded)) == (try? Data(contentsOf: file)))

        guard CommandLine.arguments.count == 2 else {
            print("ChatGPT plan inline payload preserved 17 MiB and one byte.")
            return
        }
        let root = CommandLine.arguments[1]
        let message = ChatMessage(role: .user, content: "测试")
        func configuration(_ route: String, protocol api: String = "responses") -> ChatClient.Configuration {
            .init(baseURL: URL(string: "\(root)/\(route)/v1")!, model: "fixture", key: "fixture-key", apiProtocol: api)
        }
        var streamed = ""
        let response = try await ChatClient.reply(to: [message], configuration: configuration("responses"), proxy: nil,
                                                  attachments: [.inline(item), .inline(png)], onDelta: { streamed += $0 })
        precondition(response == "received" && streamed == "received")
        let fallback = configuration("fallback")
        let reply = try await ChatClient.withRequestFiles([item, png], configuration: fallback, proxy: nil,
                                                          onCleanupFailure: nil) { attachments in
            try await ChatClient.reply(to: [message], configuration: fallback, proxy: nil, attachments: attachments)
        }
        precondition(reply == "received")
        let old = try await ChatClient.reply(to: [message], configuration: configuration("chat", protocol: "chat_completions"),
                                             proxy: nil, attachments: [.inline(item), .inline(png)])
        precondition(old == "received")
        do {
            _ = try await ChatClient.reply(to: [message], configuration: configuration("reject"), proxy: nil,
                                            attachments: [.inline(item), .inline(png)])
            fatalError("Expected the provider's format rejection")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("Unsupported fixture file") &&
                         !error.localizedDescription.contains("fixture-key"))
        }
        print("17 MiB inline files passed through Responses SSE, BYOK fallback and Chat Completions.")
    }
}
