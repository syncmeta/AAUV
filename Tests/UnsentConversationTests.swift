import Foundation

@main
struct UnsentConversationTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aauv-unsent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ConversationStore(file: root.appendingPathComponent("db/conversations.json"))
        precondition(store.loadError == nil)
        let bot = BotSnapshot(name: "Preview A", endpoint: "https://fixture.invalid/v1", model: "cloud-a", loginMethod: .byok)
        var previews = UnsentConversations()
        let a = previews.open(bot: bot, reusing: true)
        precondition(previews.open(bot: bot, reusing: true).id == a.id)
        let b = previews.open(bot: .init(name: "Preview B", endpoint: "https://fixture.invalid/v1", model: "cloud-b", loginMethod: .byok))
        precondition(a.id != b.id && previews[a.id]?.bot == bot && previews[b.id] != nil)
        let initialReplica = try store.pendingReplica()
        precondition(store.conversations.isEmpty && initialReplica.isEmpty)
        precondition(ConversationStore(file: store.file).conversations.isEmpty, "Opening previews must leave no SQLite rows")
        do { _ = try store.sendFirstMessage(" \n ", files: [], in: a); preconditionFailure("Empty send accepted") } catch {}
        precondition(store.conversations.isEmpty && previews[a.id] != nil)
        let source = root.appendingPathComponent("fixture.txt")
        try Data("synthetic attachment".utf8).write(to: source)
        let file = try DraftAttachment(source)
        let missingSource = root.appendingPathComponent("missing.txt")
        try Data("remove after staging".utf8).write(to: missingSource)
        let missing = try DraftAttachment(missingSource)
        try FileManager.default.removeItem(at: missing.url)
        do { _ = try store.sendFirstMessage("with files", files: [file, missing], in: a); preconditionFailure("Missing staged file accepted") } catch {}
        precondition(store.conversations.isEmpty && previews[a.id] != nil, "Failed first send must retain preview, not an empty chat")
        let copiedFile = try store.attachmentURL(file.attachment)
        precondition(!FileManager.default.fileExists(atPath: copiedFile.path))
        precondition(FileManager.default.fileExists(atPath: file.url.path), "Retry source must survive failed send")
        var changes = 0
        store.onLocalChange = { changes += 1 }
        let first = try store.sendFirstMessage("  First\n message  ", files: [], in: a)
        precondition(changes == 1, "First header and message must publish in one commit")
        precondition(store.conversations.count == 1 && store.conversations[0].id == a.id)
        precondition(store.conversations[0].messages.count == 1 && store.conversations[0].messages[0].id == first)
        precondition(store.conversations[0].messages[0].content == "First\n message")
        precondition(store.conversations[0].title == "First message" && store.conversations[0].automaticTitle == true)
        precondition(store.conversations[0].bot == bot && store.conversations[0].unansweredPrompt?.id == first)
        do { _ = try store.sendFirstMessage("duplicate", files: [], in: a); preconditionFailure("Duplicate first commit accepted") } catch {}
        precondition(store.conversations.count == 1 && store.conversations[0].messages.count == 1)
        previews.remove(a.id)
        precondition(previews[a.id] == nil && previews[b.id] != nil)
        precondition(previews.open(bot: bot, reusing: true).id != a.id)
        _ = try store.appendUserMessage("follow-up", files: [], to: a.id)
        precondition(store.conversations[0].messages.count == 2, "Existing append path must still work")
        let attached = try store.sendFirstMessage("", files: [file], in: b)
        let saved = store.conversations.first { $0.id == b.id }!
        precondition(saved.messages.first?.id == attached && saved.messages.first?.content == "请查看附件。")
        precondition(saved.messages.first?.attachments?.map(\.fileName) == [file.attachment.fileName])
        let savedBytes = try Data(contentsOf: store.attachmentURL(file.attachment))
        precondition(savedBytes == Data("synthetic attachment".utf8))
        let reopened = ConversationStore(file: store.file)
        precondition(reopened.conversations.count == 2 && reopened.conversations.first { $0.id == a.id }?.messages.count == 2)
        precondition(reopened.conversations.first { $0.id == b.id }?.bot?.model == "cloud-b")
        let packets = try store.pendingReplica()
        let headers = packets.filter { $0.kind == "conversation" }
        precondition(headers.count == 2 && Set(headers.map(\.conversation)) == Set([a.id.uuidString, b.id.uuidString]))
        print("Unsent previews left SQLite/sync empty; atomic first send, retry-safe partial attachment failure, duplicate guard, title/account identity, existing append, attachment-only send and reopen passed. No model, Cloud or credential operations.")
    }
}
