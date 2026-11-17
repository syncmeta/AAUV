import Foundation

@main
struct MessageAttachmentTests {
    @MainActor static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        let file = directory.url.appending(path: "conversations.json")
        let firstURL = directory.url.appending(path: "first.txt")
        let secondURL = directory.url.appending(path: "second.bin")
        let firstBytes = Data("附件正文".utf8)
        let secondBytes = Data([0, 255, 1, 42])
        try firstBytes.write(to: firstURL)
        try secondBytes.write(to: secondURL)

        let id: UUID
        do {
            let store = ConversationStore(file: file)
            let staged = try await store.stageFileOpen(firstURL)
            id = try store.openFile(staged, bot: .init(name: "测试", endpoint: "https://example.com/v1",
                                                      model: "fixture", loginMethod: .byok))
            let draft = try DraftAttachment(secondURL)
            try FileManager.default.removeItem(at: secondURL)
            do {
                try store.appendUserMessage("", files: [draft, draft], to: id)
                fatalError("Expected duplicate destination failure")
            } catch {
                precondition(store.conversations[0].messages.isEmpty)
                let destination = try store.attachmentURL(draft.attachment)
                precondition(!FileManager.default.fileExists(atPath: destination.path))
                precondition(FileManager.default.fileExists(atPath: draft.url.path))
            }
            try store.appendUserMessage("", files: [draft], to: id)
        }

        let reopened = ConversationStore(file: file)
        let conversation = reopened.conversations[0]
        let message = conversation.messages[0]
        precondition(conversation.id == id && message.role == .user && !message.content.isEmpty)
        let retry = try reopened.filesForReply(in: conversation, to: message)
        precondition(retry.map(\.name) == ["first.txt", "second.bin"])
        let retryBytes = try retry.map { try Data(contentsOf: $0.url) }
        precondition(retryBytes == [firstBytes, secondBytes])
        try reopened.appendUserMessage("继续", files: [], to: id)
        let continued = reopened.conversations[0]
        let nextFiles = try reopened.filesForReply(in: continued, to: continued.messages[1])
        precondition(nextFiles.map(\.name) == ["first.txt"])

        guard let originalBot = continued.bot else { throw CocoaError(.fileReadCorruptFile) }
        let style = BotInstructions(prompt: BotInstructions.aauvConversationStyle)
        let replacement = LocalBot(configuration: .init(name: "新机器人", endpoint: "https://example.net/v1",
                                                         model: "new-model", loginMethod: .byok, apiProtocol: "responses",
                                                         instructions: style))
        try reopened.saveBots([replacement])
        var notifications = 0
        reopened.onLocalChange = { notifications += 1 }
        try reopened.changeBot(replacement.snapshot, in: id, expected: originalBot)
        let switched = reopened.conversations[0]
        precondition(switched.id == id && switched.title == continued.title &&
                     switched.messages.map(\.id) == continued.messages.map(\.id) && switched.bot == replacement.snapshot)
        try reopened.changeBot(replacement.snapshot, in: id, expected: replacement.snapshot)
        precondition(notifications == 1)
        do {
            try reopened.changeBot(originalBot, in: id, expected: originalBot)
            fatalError("Expected a stale conversation selection to fail")
        } catch {
            precondition(reopened.conversations[0].bot == replacement.snapshot)
        }
        var updated = replacement
        updated.configuration.model = "updated-model"
        try reopened.saveBots([updated])
        do {
            try reopened.changeBot(replacement.snapshot, in: id, expected: replacement.snapshot)
            fatalError("Expected an edited profile selection to fail")
        } catch {
            precondition(reopened.conversations[0].bot == replacement.snapshot)
        }
        try reopened.changeBot(updated.snapshot, in: id, expected: replacement.snapshot)
        let reopenedWithNewBot = ConversationStore(file: file)
        precondition(reopenedWithNewBot.conversations[0].bot == updated.snapshot)

        let backup = try BackupFile.create(snapshot: reopened.backupSnapshot(), attachments: reopened.attachmentDirectory)
        let restoreDirectory = try PrivateTemporaryDirectory()
        let restored = ConversationStore(file: restoreDirectory.url.appending(path: "conversations.json"))
        try await restored.importBackup(PreparedBackup.read(backup.url))
        let restoredConversation = restored.conversations[0]
        precondition(restoredConversation.bot == restored.bots[0].snapshot && restored.bots[0].id != updated.id)
        precondition(restoredConversation.bot?.instructions?.requestInstructions == style.prompt)
        let restoredFiles = try restored.filesForReply(in: restoredConversation, to: restoredConversation.messages[0])
        let restoredBytes = try restoredFiles.map { try Data(contentsOf: $0.url) }
        precondition(restoredFiles.map(\.name) == retry.map(\.name) && restoredBytes == retryBytes)
        let restoredMatches = try await restored.searchHistory("SECOND.BIN", in: restoredConversation.id)
        precondition(restoredMatches.hits.count == 1 && restoredMatches.hits[0].messageID == restoredConversation.messages[0].id &&
                     restoredMatches.hits[0].attachment == "second.bin")
        guard let matchedDate = restoredMatches.hits[0].date, let restoredDate = restoredConversation.messages[0].date else {
            throw CocoaError(.fileReadCorruptFile)
        }
        precondition(abs(matchedDate.timeIntervalSince(restoredDate)) < 0.001)

        let replicaDirectory = try PrivateTemporaryDirectory()
        let replica = ConversationStore(file: replicaDirectory.url.appending(path: "conversations.json"))
        for record in try reopened.pendingReplica() {
            let attachments = try reopened.replicaAttachments(record)
            let asset = try ReplicaAsset.create(record: record, attachments: reopened.attachmentDirectory,
                                                hasAttachments: !attachments.isEmpty)
            try replica.applyReplicaPayload(ReplicaPayload.read(asset.url))
        }
        try replica.reloadReplica()
        let received = replica.conversations[0]
        precondition(received.id == id && received.bot == updated.snapshot)
        let syncedFiles = try replica.filesForReply(in: received, to: received.messages[0])
        let syncedBytes = try syncedFiles.map { try Data(contentsOf: $0.url) }
        precondition(syncedFiles.map(\.name) == retry.map(\.name) && syncedBytes == retryBytes)
        let replicaMatches = try await replica.searchHistory("请查看附件", in: nil)
        precondition(replicaMatches.hits.contains { $0.messageID == received.messages[0].id })
        print("Message attachments, bot changes and history search passed persistence, ZIP restoration and local replica transfer.")
    }
}
