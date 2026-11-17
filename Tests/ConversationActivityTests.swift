import Foundation

@main
struct ConversationActivityTests {
    @MainActor static func main() throws {
        let folder = try PrivateTemporaryDirectory()
        let file = folder.url.appending(path: "local/conversations.json")
        let store = ConversationStore(file: file)
        let first = try store.create()
        let second = try store.create()
        let third = try store.create()
        let old = try store.appendUserMessage("旧消息", files: [], to: first)
        let newest = try store.appendUserMessage("新消息", files: [], to: first)
        expectRejected { _ = try store.beginReply(in: first, to: old) }
        precondition(store.activities.isEmpty)

        let (reply, _, message, attempt) = try store.beginReply(in: first, to: newest)
        precondition(reply.id == attempt.id && message.id == newest && attempt.userMessageID == newest)
        expectRejected { _ = try store.beginReply(in: first, to: newest) }
        precondition(store.conversations.first(where: { $0.id == first })?.replyAttempts?.count == 1)
        expectRejected { _ = try store.beginActivity(.voice, in: first) }
        expectRejected { try store.delete(first) }
        expectRejected { try store.appendUserMessage("另一个窗口重复发送", files: [], to: first) }
        let bot = BotSnapshot(name: "测试", endpoint: "https://example.invalid/v1", model: "fixture", loginMethod: .byok)
        expectRejected { try store.changeBot(bot, in: first, expected: nil) }

        let voice = try store.beginActivity(.voice, in: second)
        expectRejected { _ = try store.beginActivity(.voice, in: third) }
        let anotherMessage = try store.appendUserMessage("独立会话", files: [], to: third)
        let (anotherReply, _, _, _) = try store.beginReply(in: third, to: anotherMessage)
        precondition(store.voiceBusy && store.activities.count == 3)
        store.endActivity(voice)
        store.endActivity(anotherReply)
        store.endActivity(reply)

        let reopened = ConversationStore(file: file)
        let loaded = reopened.conversations.first(where: { $0.id == first })
        precondition(reopened.activities.isEmpty && loaded?.replyAttempts?.last?.userMessageID == newest)

        let (nextReply, _, _, _) = try store.beginReply(in: first, to: newest)
        store.endActivity(reply)
        precondition(store.activities[first] == nextReply)
        var cancellations = 0
        store.setCancellation(for: nextReply) { cancellations += 1 }
        let peer = ConversationStore(file: folder.url.appending(path: "peer/conversations.json"))
        for record in try store.pendingReplica() {
            try peer.applyReplicaPayload(.inline(ReplicaPacket(record: record, files: [:])))
        }
        try peer.reloadReplica()
        try peer.delete(first)
        let deletions = try peer.pendingReplica()
        guard let tombstone = deletions.first(where: { $0.kind == "deleted" && $0.conversation == first.uuidString }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try store.applyReplicaPayload(.inline(ReplicaPacket(record: tombstone, files: [:])))
        try store.reloadReplica()
        try store.reloadReplica()
        precondition(cancellations == 1 && !store.conversations.contains(where: { $0.id == first }))
        store.endActivity(nextReply)
        precondition(store.activities.isEmpty)
        try testRegeneration(in: folder.url)
        try testRetryAfterLegacyReordering(in: folder.url)
        try testTitles(in: folder.url)
        print("Conversation activity, regeneration, title cadence, stale result rejection and title synchronization passed.")
    }

    @MainActor private static func testRetryAfterLegacyReordering(in folder: URL) throws {
        let file = folder.appending(path: "retry-reordered/conversations.json")
        let store = ConversationStore(file: file)
        let id = try store.create()
        let now = Date()
        let earlier = ChatMessage(role: .user, content: "较早提问", date: now.addingTimeInterval(-60))
        let legacy = ChatMessage(role: .assistant, content: "没有关联 ID 的旧回答", date: now.addingTimeInterval(3600))
        try store.append(earlier, to: id)
        try store.append(legacy, to: id)
        let prompt = try store.appendUserMessage("等待继续压缩", files: [], to: id)
        let (activity, _, _, attempt) = try store.beginReply(in: id, to: prompt)
        var failed = attempt
        failed.phase = .failed
        try store.saveAttempt(failed, to: id)
        store.endActivity(activity)

        let reopened = ConversationStore(file: file)
        let conversation = reopened.conversations.first!
        precondition(conversation.messages.map(\.id) == [earlier.id, prompt, legacy.id])
        precondition(conversation.unansweredPrompt?.id == prompt)
        let (retry, _, _, _) = try reopened.beginReply(in: id, to: prompt)
        reopened.endActivity(retry)

        // An answer from another device can arrive while a local attempt remains saved.
        try reopened.append(ChatMessage(role: .assistant, content: "实际回答", replyTo: prompt), to: id)
        precondition(reopened.conversations.first?.unansweredPrompt == nil)
        expectRejected { _ = try reopened.beginReply(in: id, to: prompt) }
    }

    @MainActor private static func testTitles(in folder: URL) throws {
        let file = folder.appending(path: "titles/conversations.json")
        let store = ConversationStore(file: file)
        let id = try store.create()
        func completeTurn(_ number: Int) throws -> ChatMessage {
            let prompt = try store.appendUserMessage("第 \(number) 轮", files: [], to: id)
            let answer = ChatMessage(role: .assistant, content: "回复 \(number)")
            try store.complete(answer, attempt: ReplyAttempt(userMessageID: prompt), in: id)
            return answer
        }
        let first = try completeTurn(1)
        guard let initial = store.prepareTitle(for: id, after: first.id) else { throw CocoaError(.fileReadCorruptFile) }
        precondition(initial.prompt.contains("第 1 轮") && initial.prompt.contains("回复 1"))
        try store.saveGeneratedTitle("第一行\n第二行", for: initial)
        precondition(store.conversations.first?.title == "第 1 轮")
        try store.saveGeneratedTitle("「自动标题」", for: initial)
        precondition(store.conversations.first?.title == "自动标题")

        let second = try completeTurn(2)
        precondition(store.prepareTitle(for: id, after: second.id) == nil)
        let third = try completeTurn(3)
        guard let refresh = store.prepareTitle(for: id, after: third.id) else { throw CocoaError(.fileReadCorruptFile) }
        let fourthPrompt = try store.appendUserMessage("新话题", files: [], to: id)
        precondition(!store.titleRequestIsCurrent(refresh))
        try store.saveGeneratedTitle("旧话题", for: refresh)
        precondition(store.conversations.first?.title == "自动标题")

        try store.complete(ChatMessage(role: .assistant, content: "回复 4"),
                           attempt: ReplyAttempt(userMessageID: fourthPrompt), in: id)
        _ = try completeTurn(5)
        let sixth = try completeTurn(6)
        guard let pending = store.prepareTitle(for: id, after: sixth.id) else { throw CocoaError(.fileReadCorruptFile) }
        try store.rename(id, to: "自动标题")
        precondition(!store.titleRequestIsCurrent(pending))
        try store.saveGeneratedTitle("晚到的自动标题", for: pending)
        precondition(store.conversations.first?.title == "自动标题")
        try store.rename(id, to: "  保留标题  ")
        let reopened = ConversationStore(file: file)
        precondition(reopened.conversations.first?.title == "保留标题")
        precondition(reopened.conversations.first?.automaticTitle == false)
        let peer = ConversationStore(file: folder.appending(path: "titles-peer/conversations.json"))
        try replicate(from: store, to: peer, attachment: Data())
        precondition(peer.conversations.first?.title == "保留标题")
        precondition(peer.conversations.first?.automaticTitle == false)
    }

    @MainActor
    private static func testRegeneration(in folder: URL) throws {
        let file = folder.appending(path: "regeneration/conversations.json")
        let store = ConversationStore(file: file)
        let id = try store.create()
        let now = Date()
        let policy = ContextPolicy()
        let questionTime = now.addingTimeInterval(-Double(policy.hours + 2) * 3600)
        let previous = ChatMessage(role: .user, content: "上一个问题", date: questionTime.addingTimeInterval(-600))
        let bytes = Data([0, 255, 12])
        let attachment = Attachment(name: "原文件.bin", fileName: UUID().uuidString, size: bytes.count)
        try FileManager.default.createDirectory(at: store.attachmentDirectory, withIntermediateDirectories: true)
        try bytes.write(to: store.attachmentURL(attachment))
        let question = ChatMessage(role: .user, content: "重新生成这个问题", date: questionTime, attachments: [attachment])
        let original = ChatMessage(role: .assistant, content: "旧数据格式的原回答", date: questionTime.addingTimeInterval(30))
        let later = ChatMessage(role: .user, content: "后来的提问", date: now.addingTimeInterval(-30))
        for message in [previous, question, original, later] { try store.append(message, to: id) }

        let (activity, conversation, userMessage, attempt) = try store.beginReply(in: id, to: question.id, regenerating: true)
        precondition(attempt.regenerating == true && userMessage.id == question.id)
        expectRejected { _ = try store.beginReply(in: id, to: later.id) }
        let context = conversation.contextForReply(to: userMessage, regenerating: true, now: now, policy: policy)
        let plan = try ContextWindow.plan(context.messages, now: context.windowEnd, policy: policy)
        precondition(plan.recent.map(\.id) == [previous.id, question.id].map(\.uuidString))
        let files = try store.filesForReply(in: conversation, to: userMessage)
        precondition(files.map(\.name) == [attachment.name])
        let reopenedBytes = try Data(contentsOf: files[0].url)
        precondition(reopenedBytes == bytes)

        var interrupted = attempt
        interrupted.phase = .interrupted
        interrupted.partial = "已生成的片段"
        try store.saveAttempt(interrupted, to: id)
        store.endActivity(activity)
        let interruptedStore = ConversationStore(file: file)
        let interruptedConversation = interruptedStore.conversations.first!
        precondition(interruptedConversation.messages.map(\.id) == [previous.id, question.id, original.id, later.id])
        precondition(interruptedConversation.replyAttempts?.last?.partial == "已生成的片段")

        let (retry, _, _, nextAttempt) = try store.beginReply(in: id, to: question.id, regenerating: true)
        let answer = ChatMessage(role: .assistant, content: "新回答", date: now)
        try store.complete(answer, attempt: nextAttempt, in: id)
        store.endActivity(retry)
        let generated = store.conversations.first!
        precondition(generated.turns.first(where: { $0.id == question.id })?.replies.map(\.id) == [original.id, answer.id])
        precondition(generated.unansweredPrompt?.id == later.id && generated.replyAttempts?.isEmpty == true)
        precondition(generated.contextMessages().map(\.id) == [previous.id, question.id, original.id, later.id])

        let (live, _, _, liveAttempt) = try store.beginReply(in: id, to: later.id)
        let newest = ChatMessage(role: .user, content: "另一端同步的新提问", date: now.addingTimeInterval(1))
        try store.append(newest, to: id)
        let liveAnswer = ChatMessage(role: .assistant, content: "给上一条的回答", date: now.addingTimeInterval(2))
        try store.complete(liveAnswer, attempt: liveAttempt, in: id)
        store.endActivity(live)

        let settingsPeer = ConversationStore(file: folder.appending(path: "regeneration-settings/conversations.json"))
        try replicate(from: store, to: settingsPeer, attachment: bytes)
        try store.selectReply(answer.id, for: question.id, in: id)
        let otherBot = BotSnapshot(name: "另一端更换的机器人", endpoint: "https://example.invalid/v1",
                                   model: "fixture", loginMethod: .byok)
        try settingsPeer.changeBot(otherBot, in: id, expected: nil)
        try replicate(from: settingsPeer, to: store, attachment: bytes)
        let selected = store.conversations.first!
        precondition(selected.bot?.name == otherBot.name)
        precondition(selected.unansweredPrompt?.id == newest.id)
        precondition(selected.contextMessages().map(\.id) == [previous.id, question.id, answer.id, later.id, liveAnswer.id, newest.id])
        precondition(selected.contextMessages().first(where: { $0.id == answer.id })?.date == original.date)
        let staleRetry = selected.contextForReply(to: newest, regenerating: false, now: now.addingTimeInterval(172800), policy: policy)
        let stalePlan = try ContextWindow.plan(staleRetry.messages, now: staleRetry.windowEnd, policy: policy)
        precondition(stalePlan.recent.map(\.id) == [newest.id.uuidString])

        let peer = ConversationStore(file: folder.appending(path: "regeneration-peer/conversations.json"))
        try store.requeueReplica()
        try replicate(from: store, to: peer, attachment: bytes)
        let synced = peer.conversations.first!
        precondition(synced.contextMessages().map(\.id) == selected.contextMessages().map(\.id))
        precondition(synced.turns.first(where: { $0.id == question.id })?.replies.map(\.id) == [original.id, answer.id])
        try peer.selectReply(original.id, for: question.id, in: id)
        precondition(peer.conversations.first?.contextMessages().map(\.id).contains(original.id) == true)

        let archived = try JSONEncoder().encode(selected)
        let restored = try JSONDecoder().decode(Conversation.self, from: archived)
        try store.importCopies([restored])
        let copy = store.conversations.first!
        let restoredTurn = copy.turns.first(where: { $0.first.content == question.content })!
        precondition(restoredTurn.id != question.id && restoredTurn.replies.map(\.content) == [original.content, answer.content])
        precondition(copy.contextMessages().map(\.content) == selected.contextMessages().map(\.content))
    }

    @MainActor
    private static func replicate(from source: ConversationStore, to target: ConversationStore, attachment: Data) throws {
        for record in try source.pendingReplica().reversed() {
            let files = try source.replicaAttachments(record).reduce(into: [String: Data]()) { files, file in
                files[file.fileName] = attachment
            }
            try target.applyReplicaPayload(.inline(ReplicaPacket(record: record, files: files)))
        }
        try target.reloadReplica()
    }

    private static func expectRejected(_ action: () throws -> Void) {
        do {
            try action()
            fatalError("Expected conflicting conversation action to fail")
        } catch is ChatClient.ClientError {
            return
        } catch {
            fatalError("Unexpected fixture error: \(error.localizedDescription)")
        }
    }
}
