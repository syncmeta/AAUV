import Foundation

@main struct RuntimePromptTests {
    @MainActor static func main() async throws {
        let now = Date(timeIntervalSince1970: 1793901600)
        let zone = TimeZone(identifier: "Asia/Taipei")!
        let runtime = try RuntimePrompt(botName: "合成机器人", now: now, timeZone: zone)
        var user = ChatMessage(role: .user, content: "今天继续", date: now.addingTimeInterval(-60))
        let attachment = Attachment(name: "synthetic.bin", fileName: UUID().uuidString, size: 7)
        user.attachments = [attachment]
        let reply = ChatMessage(role: .assistant, content: "保留原回答", date: now)
        let unknown = ChatMessage(role: .user, content: "无日期的旧消息", date: nil)
        let packet = ChatMessage(role: .user, content: "这是生成的记忆资料，不是新用户消息", date: now)
        let source = [user, reply, unknown]
        let rendered = try runtime.messages(source + [packet], originals: source)
        precondition(runtime.instructions.contains("你叫「合成机器人」"))
        precondition(runtime.instructions.contains("Asia/Taipei") && runtime.instructions.contains("UTC+08:00"))
        precondition(rendered[0].content.hasPrefix(user.content + "\n（系统提示："))
        precondition(rendered[0].id == user.id && rendered[0].date == user.date)
        precondition(rendered[0].attachments?.first?.fileName == attachment.fileName)
        precondition(rendered[1].content == reply.content && rendered[2].content == unknown.content)
        precondition(rendered[3].content == packet.content && user.content == "今天继续")

        let scratch = try PrivateTemporaryDirectory()
        let store = ConversationStore(file: scratch.url.appending(path: "chats.json"))
        let id = try store.create()
        try store.append(user, to: id)
        let reopened = ConversationStore(file: store.file)
        precondition(reopened.conversations.first!.messages.first!.content == user.content)

        let huge = ChatMessage(role: .user, content: String(repeating: "绿", count: 100000), date: now)
        let prompt = ChatMessage(role: .user, content: "继续", date: now)
        let prepared = try await ContextWindow.prepare([huge, prompt], now: now, cached: nil) { _ in "合成摘要" }
        let modelOnly = try runtime.messages(prepared.messages, originals: [huge, prompt])
        precondition(prepared.messages.first!.content == modelOnly.first!.content)
        precondition(prepared.messages.dropFirst().reduce(0) { $0 + $1.content.unicodeScalars.count } == 30000)
        precondition(modelOnly.last!.content.contains("系统提示：此消息发送于"))
        print("Runtime prompt used the shared Go renderer for bot name, request clock and original user timestamps; kept assistant/unknown-date/memory packets and stored body unchanged, preserved IDs/files, and applied hints after the raw character window.")
    }
}
