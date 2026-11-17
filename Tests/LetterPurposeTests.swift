import Foundation

@main
struct LetterPurposeTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AAUV-letter-purpose-tests-" + UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        guard !FileManager.default.fileExists(atPath: root.path) else { fatalError("Single-use fixture path already exists") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { fatalError(label) }
            checks.append(label)
        }
        func value(_ store: ConversationStore, _ id: UUID) -> Conversation {
            guard let value = store.conversations.first(where: { $0.id == id }) else { fatalError("Missing fixture record") }
            return value
        }
        func messageBytes(_ value: Conversation) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value.messages)
        }
        func uniqueMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
            let ids = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, UUID()) })
            return messages.map { original in
                var copy = original
                copy.id = ids[original.id]!
                copy.replyTo = original.replyTo.flatMap { ids[$0] }
                return copy
            }
        }
        func revisions(_ store: ConversationStore) throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try store.pendingReplica().map { ($0.name, $0.revision) })
        }
        let file = root.appending(path: "A/conversations.json")
        let store = ConversationStore(file: file)
        try check(store.loadError == nil, "Explicit private SQLite opens")
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        let prompt = ChatMessage(role: .user, content: try LetterWritingPrompt.makeRequest(requirements: "给未来的自己写信"), date: stamp)
        let answer = ChatMessage(role: .assistant, content: "亲爱的自己：\n愿你平安。", date: stamp.addingTimeInterval(1), replyTo: prompt.id)
        var letter = Conversation()
        letter.title = "写信 · 合成机器人"
        letter.purpose = .letter
        letter.automaticTitle = false
        letter.messages = [prompt, answer]
        try store.insert(letter)
        try check(value(store, letter.id).isLetter, "Explicit letter survives insert")
        try store.rename(letter.id, to: "独立信件标题")
        let followup = ChatMessage(role: .user, content: "保留这段附记", date: stamp.addingTimeInterval(2))
        try store.append(followup, to: letter.id)
        try check(value(store, letter.id).purpose == .letter && value(store, letter.id).messages.last?.id == followup.id,
                  "Purpose survives real header update and message append")

        var legacy = Conversation()
        legacy.title = "旧信件"
        legacy.automaticTitle = false
        legacy.messages = uniqueMessages([prompt, answer])
        try store.insert(legacy)
        let removed = ChatMessage(role: .assistant, content: "将删除的合成回答", date: stamp.addingTimeInterval(3), replyTo: legacy.messages.first!.id)
        try store.append(removed, to: legacy.id)
        try store.deleteMessage(removed.id, in: legacy.id)
        let originalMessages = try messageBytes(value(store, legacy.id))
        let historyRevision = value(store, legacy.id).historyRevision
        try check(historyRevision?.isEmpty == false, "Legacy fixture includes real Core deletion revision")
        var excluded: [Conversation] = []
        var sameTitle = Conversation(); sameTitle.title = "写信 · 合成机器人"; sameTitle.automaticTitle = false
        sameTitle.messages = [.init(role: .user, content: "普通聊天，不是起草信件", date: stamp)]
        excluded.append(sameTitle)
        var partialPrefix = Conversation(); partialPrefix.automaticTitle = false
        partialPrefix.messages = [.init(role: .user, content: "请根据下面的用户要求起草一封信。只是引用前句", date: stamp)]
        excluded.append(partialPrefix)
        var autoTitle = Conversation(); autoTitle.automaticTitle = true; autoTitle.messages = uniqueMessages([prompt])
        excluded.append(autoTitle)
        var explicitChat = Conversation(); explicitChat.purpose = .chat; explicitChat.automaticTitle = false; explicitChat.messages = uniqueMessages([prompt])
        excluded.append(explicitChat)
        var emptyRequest = Conversation(); emptyRequest.automaticTitle = false
        emptyRequest.messages = [.init(role: .user, content: LetterWritingPrompt.legacyPreamble, date: stamp)]
        excluded.append(emptyRequest)
        for conversation in excluded { try store.insert(conversation) }
        let normalID = try store.create()
        try check(!value(store, normalID).isLetter, "Normal create remains ordinary chat")
        let activity = try store.beginActivity(.reply, in: legacy.id)
        var localChanges = 0
        store.onLocalChange = { localChanges += 1 }
        try check(try store.migrateLegacyLetters() == 1, "Only exact full legacy preamble with manual title migrates")
        try check(localChanges == 1, "Committed migration publishes one local change")
        try check(value(store, legacy.id).isLetter && value(store, legacy.id).automaticTitle == false, "Legacy header is tagged as letter")
        try check(try messageBytes(value(store, legacy.id)) == originalMessages, "Migration preserves exact message content IDs dates and order")
        try check(value(store, legacy.id).historyRevision == historyRevision, "Migration preserves historyRevision")
        try check(store.activities[legacy.id] == activity, "Metadata migration does not stop current activity")
        store.endActivity(activity)
        try check(excluded.allSatisfy { !value(store, $0.id).isLetter }, "Title-only partial empty automatic and explicit-chat negatives remain chat")
        try store.prepareReplica()
        let beforeNoOp = try revisions(store)
        let changeCount = localChanges
        try check(try store.migrateLegacyLetters() == 0, "Legacy migration is idempotent")
        try check(try revisions(store) == beforeNoOp && localChanges == changeCount, "Repeated migration stages no revision and no notification")
        let reopened = ConversationStore(file: file)
        try check(reopened.loadError == nil && value(reopened, letter.id).isLetter && value(reopened, legacy.id).isLetter,
                  "Real SQLite reopen retains explicit and migrated purpose")
        try check(value(reopened, legacy.id).historyRevision == historyRevision, "SQLite reopen preserves deletion revision through header migration")
        try check(try messageBytes(value(reopened, legacy.id)) == originalMessages, "SQLite reopen preserves migrated message bytes")
        try check(value(reopened, explicitChat.id).purpose == .chat && value(reopened, normalID).purpose == nil,
                  "Optional missing purpose and explicit chat round-trip")

        let records = try store.pendingReplica()
        let letterHeader = records.first { $0.kind == "conversation" && $0.conversation == letter.id.uuidString }!
        let headerObject = try JSONSerialization.jsonObject(with: Data(letterHeader.payload.utf8)) as! [String: Any]
        try check(headerObject["purpose"] as? String == "letter", "Fixed Core SDK replica header preserves unknown purpose field")
        let receiver = ConversationStore(file: root.appending(path: "B/conversations.json"))
        let accepted = try receiver.applyReplicaBatch(records.reversed().map { .success(.inline(ReplicaPacket(record: $0, files: [:]))) })
        for result in accepted { try result.get() }
        try check(value(receiver, letter.id).isLetter && value(receiver, legacy.id).isLetter,
                  "Real replica apply and reload retain letter categories without Cloud")
        try check(value(receiver, explicitChat.id).purpose == .chat && value(receiver, normalID).purpose == nil,
                  "Replica keeps ordinary categories distinct")
        let receiverReopened = ConversationStore(file: receiver.file)
        try check(value(receiverReopened, letter.id).isLetter && value(receiverReopened, legacy.id).isLetter,
                  "Receiver SQLite reopen retains purpose")

        let backup = PortableArchive(conversations: reopened.conversations)
        let backupBytes = try JSONEncoder().encode(backup)
        try backupBytes.write(to: root.appending(path: "synthetic-backup.json"))
        let decoded = try JSONDecoder().decode(PortableArchive.self, from: backupBytes)
        let restored = ConversationStore(file: root.appending(path: "C/conversations.json"))
        _ = try restored.importCopies(decoded.conversations)
        try check(restored.conversations.filter(\.isLetter).count == 2, "Portable archive Codable and real importCopies preserve letter category")
        try check(Set(restored.conversations.map(\.id)).isDisjoint(with: Set(reopened.conversations.map(\.id))),
                  "Backup restore retains existing new-identity semantics")
        let restoredReopened = ConversationStore(file: restored.file)
        try check(restoredReopened.conversations.filter(\.isLetter).count == 2, "Backup SQLite reopen retains letter categories")
        let result: [String: Any] = ["allChecksPassed": true, "checks": checks, "checkCount": checks.count,
                                   "scope": "Synthetic native real SQLite, fixed existing SDK, Codable, local replica and backup copies; no Cloud, HTTP, GUI, credentials or provider request."]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appending(path: "result.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
