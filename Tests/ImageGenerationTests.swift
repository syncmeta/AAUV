import Foundation
import ImageIO

@main
struct ImageGenerationTests {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let endpoint = URL(string: CommandLine.arguments[1]) else { throw URLError(.badURL) }
        try checkImageLimitsAndPortableConfiguration()
        try await generateAndReplicate(endpoint: endpoint, model: "fixture-image-only", expectedFiles: 1, expectedMissing: 0)
        try await generateAndReplicate(endpoint: endpoint, model: "fixture-mixed-images", expectedFiles: 2, expectedMissing: 2)
        try await rejectIncompleteImage(endpoint)
        try await keepCompletedReplyAfterCredentialChange(endpoint)
        print("Cloud image generation preserved image-only replies, PNG bytes, progress, invalid-image diagnostics, local replica attachments, cancellation boundaries and portable tool settings.")
    }

    @MainActor private static func checkImageLimitsAndPortableConfiguration() throws {
        let bytes = Data(base64Encoded: png)!
        let encoded = try JSONSerialization.data(withJSONObject: [["type": "image_generation_call", "result": png]])
        let images = try JSONDecoder().decode([ResponseGeneratedImages.OutputItem].self, from: encoded)
        precondition(ResponseGeneratedImages.decode(images, maximumBytes: bytes.count).files.first?.data == bytes)
        precondition(ResponseGeneratedImages.decode(images, maximumBytes: bytes.count - 1).unavailable == 1)
        precondition(ResponseGeneratedImages.decode(images, maximumBytes: bytes.count, maximumCount: 0).unavailable == 1)
        let many = ResponseGeneratedImages.decode(Array(repeating: images[0], count: 33), maximumBytes: bytes.count * 33)
        precondition(many.files.count == 32 && many.unavailable == 1)
        let two = ResponseGeneratedImages.decode([images[0], images[0]], maximumBytes: bytes.count)
        precondition(two.files.count == 1 && two.unavailable == 1)
        let failedData = try JSONSerialization.data(withJSONObject: [["type": "image_generation_call", "result": png, "status": "failed"]])
        let failed = try JSONDecoder().decode([ResponseGeneratedImages.OutputItem].self, from: failedData)
        precondition(ResponseGeneratedImages.decode(failed, maximumBytes: bytes.count).unavailable == 1)
        precondition(HostedTool.supported(["image_generation"], by: .chatgpt).isEmpty)
        precondition(HostedTool.supported(["image_generation"], by: .copilot).isEmpty)
        let settings = try PortableSettings(endpoint: "https://example.invalid/v1", model: "fixture", loginMethod: .byok,
                                            apiProtocol: "responses", hostedTools: ["image_generation"]).validated()
        let link = try ConfigurationLink.encode(JSONEncoder().encode(settings))
        let restored = try PortableSettings.decode(ConfigurationLink.decode(link))
        precondition(restored.hostedTools == ["image_generation"])
        let bot = try LocalBot(configuration: .init(name: "Image fixture", endpoint: settings.endpoint, model: settings.model,
                                                   loginMethod: .byok, apiProtocol: "responses",
                                                   hostedTools: settings.hostedTools)).validated()
        precondition(bot.configuration.hostedTools == ["image_generation"])
    }

    @MainActor private static func generateAndReplicate(endpoint: URL, model: String, expectedFiles: Int, expectedMissing: Int) async throws {
        let directory = try PrivateTemporaryDirectory()
        let file = directory.url.appending(path: "local/conversations.json")
        let store = ConversationStore(file: file)
        let bot = BotSnapshot(name: "Image fixture", endpoint: endpoint.absoluteString, model: model,
                              loginMethod: .byok, apiProtocol: "responses", hostedTools: ["image_generation"])
        let id = try store.create(bot: bot)
        let prompt = ChatMessage(role: .user, content: "Generate an image")
        try store.append(prompt, to: id)
        let (activity, _, _, attempt) = try store.beginReply(in: id, to: prompt.id)
        defer { store.endActivity(activity) }
        let answerID = UUID()
        var progress: [Set<HostedTool>] = []
        let text = try await ChatClient.reply(
            to: [prompt], configuration: configuration(endpoint, model), proxy: nil,
            onTools: { progress.append($0) },
            onReplyReady: { reply in
                precondition(reply.fileCount == expectedFiles + expectedMissing)
                try store.complete(.init(id: answerID, role: .assistant,
                                         content: reply.text.isEmpty ? "Generated image" : reply.text,
                                         unavailableAttachments: reply.fileCount), attempt: attempt, in: id)
            },
            onGeneratedFiles: { try store.saveReplyAttachments($0, to: answerID, in: id) }
        )
        precondition(progress == [[.imageGeneration], []])
        precondition(text == (model == "fixture-image-only" ? "" : "Picture and file"))
        let reopened = ConversationStore(file: file)
        let answer = reopened.conversations.first!.messages.last!
        precondition(answer.id == answerID && answer.attachments?.count == expectedFiles)
        precondition((answer.unavailableAttachments ?? 0) == expectedMissing)
        let attachment = answer.attachments!.first!
        let imageBytes = try Data(contentsOf: reopened.attachmentURL(attachment))
        precondition(attachment.name == "generated-image-1.png" && imageBytes == Data(base64Encoded: png))
        let source = CGImageSourceCreateWithData(imageBytes as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        precondition(image?.width == 1 && image?.height == 1)

        try store.prepareReplica()
        let remote = ConversationStore(file: directory.url.appending(path: "remote/conversations.json"))
        for record in try store.pendingReplica() {
            let hasAttachments = try !store.replicaAttachments(record).isEmpty
            let asset = try ReplicaAsset.create(record: record, attachments: store.attachmentDirectory,
                                                hasAttachments: hasAttachments)
            try remote.applyReplicaPayload(ReplicaPayload.read(asset.url))
        }
        try remote.reloadReplica()
        let remoteAttachment = remote.conversations.first!.messages.last!.attachments!.first!
        let remoteBytes = try Data(contentsOf: remote.attachmentURL(remoteAttachment))
        precondition(remoteAttachment.id == attachment.id && remoteBytes == imageBytes)

        store.endActivity(activity)
        let sourceURL = try reopened.attachmentURL(attachment)
        let reattached = try await Task.detached { try DraftAttachment(sourceURL, suggestedName: attachment.name) }.value
        let followupID = try store.appendUserMessage("Edit this picture", files: [reattached], to: id)
        let updated = store.conversations.first!
        let followup = updated.messages.first { $0.id == followupID }!
        let requestFiles = try store.filesForReply(in: updated, to: followup)
        precondition(requestFiles.first?.name == attachment.name && requestFiles.first?.mediaType == "image/png")
        let copiedBytes = try Data(contentsOf: requestFiles.first!.url)
        precondition(copiedBytes == imageBytes && followup.attachments?.first?.id != attachment.id)
    }

    @MainActor private static func rejectIncompleteImage(_ endpoint: URL) async throws {
        var saved = false
        do {
            _ = try await ChatClient.reply(to: [.init(role: .user, content: "Generate")],
                                           configuration: configuration(endpoint, "fixture-incomplete-image"), proxy: nil,
                                           onReplyReady: { _ in saved = true }, onGeneratedFiles: { _ in saved = true })
            fatalError("An incomplete image was persisted")
        } catch ChatClient.ClientError.stream(let code) {
            precondition(code == "stream_ended_without_completion" && !saved)
        }
    }

    private enum CredentialChanged: Error { case rejected }

    @MainActor private static func keepCompletedReplyAfterCredentialChange(_ endpoint: URL) async throws {
        var checks = 0
        var completed = false
        var generated: ChatClient.GeneratedFiles?
        _ = try await ChatClient.reply(to: [.init(role: .user, content: "Generate")],
                                       configuration: configuration(endpoint, "fixture-image-only"), proxy: nil,
                                       validateCredential: {
                                           checks += 1
                                           if checks > 1 { throw CredentialChanged.rejected }
                                       },
                                       onReplyReady: { completed = $0.fileCount == 1 },
                                       onGeneratedFiles: { generated = $0 })
        precondition(completed && generated?.files.isEmpty == true && generated?.unavailable == 1)
    }

    private static func configuration(_ endpoint: URL, _ model: String) -> ChatClient.Configuration {
        .init(baseURL: endpoint, model: model, key: "fixture-key", hostedTools: ["image_generation"])
    }
}
