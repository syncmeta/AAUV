import Foundation

/// Manual application action only: all records, files and summaries are synthetic.
/// This fixture never constructs a provider session, Cloud container or login flow.
@main @MainActor
struct AutomaticLetterTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let policy = ContextPolicy(threshold: 100_000, hours: 24, samples: 3)

    static func main() throws {
        let directory = try PrivateTemporaryDirectory()
        try sourceSelectionAndLineage()
        snapshotValidation()
        try nilIdentityAndEmptyHistory()
        try retryAndRegeneration(directory.url.appending(path: "retry"))
        try persistenceAndScope(directory.url.appending(path: "persistence"))
        try attachmentRetention(directory.url.appending(path: "attachments"))
        print("AutomaticLetterTests passed identity/latest-chat/selected-lineage and bounded older sampling; natural empty-history trigger; immutable dated snapshot across retries, regeneration, SQLite/Codable/local-replica/backup copies; header attachment keepalive without eager upload; snapshot replacement invalidates reply and tool scopes. Synthetic local data only; no provider, Cloud, Keychain or GUI.")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        let passed = try condition()
        precondition(passed, label)
    }

    private static func bot(profileID: UUID? = UUID()) -> BotSnapshot {
        BotSnapshot(name: "synthetic bot", endpoint: "https://synthetic.invalid/v1", model: "synthetic-model",
                    loginMethod: .byok, apiProtocol: "responses", profileID: profileID)
    }

    private static func chat(_ bot: BotSnapshot, content: String, age: TimeInterval) -> Conversation {
        var value = Conversation()
        value.bot = bot
        value.messages = [.init(role: .user, content: content, date: now.addingTimeInterval(-age))]
        return value
    }

    private static func conversation(_ store: ConversationStore, _ id: UUID) -> Conversation {
        guard let value = store.conversations.first(where: { $0.id == id }) else { preconditionFailure("Missing synthetic conversation") }
        return value
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func rejected(_ label: String, _ action: () throws -> Void) {
        do { try action() } catch { return }
        preconditionFailure(label)
    }

    private static func snapshotValidation() {
        let id = UUID()
        let message = LetterContext.Message(id: id, role: .user, content: "synthetic", date: now)
        let duplicate = LetterContext(sourceConversationID: nil, capturedAt: now, messages: [message, message])
        rejected("Duplicate context IDs must fail before model context preparation") { try duplicate.validate() }
        let collision = LetterContext(sourceConversationID: nil, capturedAt: now, messages: [message])
        rejected("Context IDs must not collide with actual conversation rows") { try collision.validate(excluding: [id]) }
        let huge = LetterContext.Message(id: UUID(), role: .user, content: String(repeating: "x", count: 8 * 1024 * 1024), date: now)
        let oversized = LetterContext(sourceConversationID: nil, capturedAt: now, messages: [huge])
        rejected("Oversized snapshots must fail before persistence or model access") { try oversized.validate() }
    }

    private static func sourceSelectionAndLineage() throws {
        let target = bot()
        var oldConfiguration = target
        oldConfiguration.name = "earlier bot name"
        oldConfiguration.model = "earlier-model"
        var source = Conversation()
        source.bot = oldConfiguration // A stable profile ID survives configuration edits.
        let older = (0..<8).map { index in
            ChatMessage(role: .user, content: "older-\(index)", date: now.addingTimeInterval(-172_800 - Double(index)))
        }
        var prompt = ChatMessage(role: .user, content: "recent question", date: now.addingTimeInterval(-3_600))
        let original = ChatMessage(role: .assistant, content: "unselected original", date: now.addingTimeInterval(-1_800), replyTo: prompt.id)
        let selected = ChatMessage(role: .assistant, content: "chosen alternative", date: now.addingTimeInterval(-1_200),
                                   replyTo: prompt.id, isAlternative: true)
        prompt.selectedReplyID = selected.id
        prompt.localToolTrace = .init(requestID: UUID(), runRevision: "1000000000000000001", entries: [])
        let future = ChatMessage(role: .user, content: "future-dated not yet eligible", date: now.addingTimeInterval(3_600))
        source.messages = older + [prompt, original, selected, future]
        source.compression = .init(fingerprint: "synthetic-old-cache", summary: "must not be copied", compressedSamples: [], historicalSamples: [])
        source.replyAttempts = [.init(userMessageID: prompt.id, phase: .failed, partial: "old failed request")]
        source.selectedReplies = [prompt.id.uuidString: selected.id]
        source.historyRevision = "synthetic-source-revision"
        let sourceBefore = try encoded(source)
        let olderSameBot = chat(target, content: "older same-bot chat", age: 14_400)
        let foreign = chat(bot(), content: "foreign bot is newer", age: 1)
        var previousLetter = chat(target, content: "never recurse into a prior letter", age: 1)
        previousLetter.purpose = .letter
        var noBot = chat(target, content: "unbound conversation", age: 1)
        noBot.bot = nil
        let letter = try LetterGeneration.makeConversation(bot: target,
            conversations: [foreign, olderSameBot, previousLetter, source, noBot], policy: policy, now: now)
        let snapshot = letter.letterContext!
        try require(snapshot.sourceConversationID == source.id && snapshot.capturedAt == now,
                    "Choose the latest eligible same-profile ordinary chat, not a letter or a newer foreign bot")
        try require(letter.isLetter && letter.automaticTitle == false && letter.bot == target,
                    "The action creates a letter bound to the requested current bot snapshot")
        try require(letter.messages.count == 1 && letter.messages[0].role == .user && letter.messages[0].content == LetterGeneration.prompt,
                    "History is header context, not copied persistent message rows")
        try require(!LetterWritingPrompt.isLegacyRequest(letter.messages[0].content) &&
                    !letter.messages[0].content.contains("信件正文"), "The trigger does not impose the old letter document format")
        let active = source.contextMessages().filter { ($0.date ?? .distantPast) >= now.addingTimeInterval(-86_400) && ($0.date ?? .distantFuture) <= now }
        let snapshotActive = snapshot.messages.filter { ($0.date ?? .distantPast) >= now.addingTimeInterval(-86_400) }
        try require(snapshotActive.map(\.content) == active.map(\.content) && snapshotActive.map(\.role) == active.map(\.role) &&
                    snapshotActive.map(\.date) == active.map(\.date), "Keep the complete current window, selected reply lineage and its existing dates")
        let sampled = snapshot.messages.filter { ($0.date ?? .distantPast) < now.addingTimeInterval(-86_400) }
        let pool = Dictionary(uniqueKeysWithValues: older.map { ($0.content, $0.date) })
        try require(sampled.count == policy.samples && Set(sampled.map(\.content)).count == sampled.count &&
                    sampled.allSatisfy { pool.keys.contains($0.content) && pool[$0.content]! == $0.date },
                    "Older background is a unique policy-sized subset with original dates; do not assert particular random IDs or distribution")
        try require(!snapshot.messages.contains { [original.content, future.content, foreign.messages[0].content, previousLetter.messages[0].content].contains($0.content) },
                    "Unselected answers, future messages, foreign bots and previous letters are absent")
        let sourceIDs = Set(source.messages.map(\.id))
        try require(Set(snapshot.messages.map(\.id)).count == snapshot.messages.count &&
                    Set(snapshot.messages.map(\.id)).isDisjoint(with: sourceIDs.union(letter.messages.map(\.id))),
                    "Snapshot IDs are newly allocated, unique and disjoint from source and trigger IDs")
        try snapshot.validate(excluding: Set(letter.messages.map(\.id)))
        try require(snapshot.messages.map(\.chatMessage).allSatisfy { $0.attachments == nil && $0.replyTo == nil && $0.localToolTrace == nil },
                    "Typed snapshot copies only role/content/date with fresh IDs, not source files, reply links or trace")
        try require(letter.compression == nil && letter.replyAttempts == nil && letter.selectedReplies == nil &&
                    letter.historyRevision == nil && (try encoded(source)) == sourceBefore,
                    "Do not inherit source caches/attempts/revisions or mutate source data")
    }

    private static func nilIdentityAndEmptyHistory() throws {
        let target = bot(profileID: nil)
        let matching = chat(target, content: "same entire nil-ID bot", age: 3_600)
        var differentBot = target
        differentBot.model = "other-model"
        let different = chat(differentBot, content: "nil IDs do not merge bots", age: 1)
        var identifiedBot = target
        identifiedBot.profileID = UUID()
        let identified = chat(identifiedBot, content: "identified bot does not match nil", age: 1)
        let letter = try LetterGeneration.makeConversation(bot: target, conversations: [different, identified, matching], policy: policy, now: now)
        try require(letter.letterContext?.sourceConversationID == matching.id && letter.letterContext?.messages.map(\.content) == matching.messages.map(\.content),
                    "Missing IDs use strict full BotSnapshot equality")
        let empty = try LetterGeneration.makeConversation(bot: target, conversations: [different, identified], policy: policy, now: now)
        try require(empty.letterContext?.sourceConversationID == nil && empty.letterContext?.messages.isEmpty == true &&
                    empty.messages.count == 1 && empty.messages[0].content == LetterGeneration.prompt,
                    "No matching history still creates a single natural trigger with no invented prior conversation")
        let emptyChat = chat(target, content: "", age: 0)
        var reallyEmpty = emptyChat; reallyEmpty.messages = []
        let noRows = try LetterGeneration.makeConversation(bot: target, conversations: [reallyEmpty], policy: policy, now: now)
        try require(noRows.letterContext?.sourceConversationID == nil, "An empty chat is not historical background")
    }

    private static func retryAndRegeneration(_ directory: URL) throws {
        let target = bot()
        let source = chat(target, content: "original background", age: 3_600)
        let letter = try LetterGeneration.makeConversation(bot: target, conversations: [source], policy: policy, now: now)
        let store = ConversationStore(file: directory.appending(path: "chats.json"))
        try store.insert(source)
        try store.insert(letter)
        let trigger = letter.messages[0]
        let (activity, _, _, attempt) = try store.beginReply(in: letter.id, to: trigger.id)
        var interrupted = attempt; interrupted.phase = .interrupted
        try store.saveAttempt(interrupted, to: letter.id)
        store.endActivity(activity)
        // Editing the source later must not recapture the letter's background.
        try store.append(.init(role: .user, content: "later source edit must not leak", date: now.addingTimeInterval(10)), to: source.id)
        let (retryActivity, retry, retryPrompt, retryAttempt) = try store.beginReply(in: letter.id, to: trigger.id)
        let retryNow = now.addingTimeInterval(3 * 86_400)
        let retried = retry.contextForReply(to: retryPrompt, regenerating: false, now: retryNow, policy: policy)
        try require(retry.letterContext == letter.letterContext && Array(retried.messages.dropLast()).map(\.id) == letter.letterContext!.messages.map(\.id) &&
                    Array(retried.messages.dropLast()).map(\.date) == letter.letterContext!.messages.map(\.date),
                    "Retry retains exactly the captured background IDs/dates despite source edits and elapsed time")
        try require(retried.messages.last?.date == retryNow && conversation(store, letter.id).messages[0].date == now,
                    "An aged trigger can enter the request window without rewriting its stored timestamp")
        try store.complete(.init(role: .assistant, content: "synthetic saved response", date: now.addingTimeInterval(1)), attempt: retryAttempt, in: letter.id)
        store.endActivity(retryActivity)
        let (regenActivity, regenerated, regenPrompt, _) = try store.beginReply(in: letter.id, to: trigger.id, regenerating: true)
        let regeneration = regenerated.contextForReply(to: regenPrompt, regenerating: true, now: retryNow, policy: policy)
        try require(regenerated.letterContext == letter.letterContext && regeneration.windowEnd == now &&
                    regeneration.messages.map(\.id) == letter.letterContext!.messages.map(\.id) + [trigger.id] &&
                    Array(regeneration.messages.dropLast()).map(\.date) == letter.letterContext!.messages.map(\.date),
                    "Regeneration uses the same snapshot and original request clock, without its own saved answer")
        store.endActivity(regenActivity)
    }

    private static func persistenceAndScope(_ directory: URL) throws {
        let target = bot()
        var source = chat(target, content: "dated history", age: 3_600)
        source.messages.insert(.init(role: .user, content: "unknown historical time", date: nil), at: 0)
        let letter = try LetterGeneration.makeConversation(bot: target, conversations: [source], policy: policy, now: now)
        let store = ConversationStore(file: directory.appending(path: "A/chats.json"))
        try store.insert(letter)
        let reopened = ConversationStore(file: store.file)
        try require(reopened.loadError == nil && conversation(reopened, letter.id).letterContext == letter.letterContext,
                    "Real SQLite reopens the entire optional typed snapshot, including nil dates")
        let decoded = try JSONDecoder().decode(Conversation.self, from: encoded(letter))
        try require(decoded.letterContext == letter.letterContext && decoded.messages.count == 1, "Codable preserves snapshot header without materializing source rows")
        try store.prepareReplica()
        let records = try store.pendingReplica().filter { $0.conversation == letter.id.uuidString }
        let receiver = ConversationStore(file: directory.appending(path: "B/chats.json"))
        for result in try receiver.applyReplicaBatch(records.reversed().map { .success(.inline(ReplicaPacket(record: $0, files: [:]))) }) { try result.get() }
        try require(conversation(receiver, letter.id).letterContext == letter.letterContext && conversation(receiver, letter.id).messages.count == 1,
                    "Local replica packet/apply/reload retains snapshot in header with only the trigger as a real row")
        let archive = PortableArchive(conversations: [conversation(receiver, letter.id)])
        let backup = try JSONDecoder().decode(PortableArchive.self, from: encoded(archive))
        let restored = ConversationStore(file: directory.appending(path: "C/chats.json"))
        _ = try restored.importCopies(backup.conversations)
        let copy = restored.conversations[0]
        try require(copy.id != letter.id && copy.messages[0].id != letter.messages[0].id && copy.letterContext == letter.letterContext,
                    "Backup copies get new conversation/real-row IDs while retaining immutable background snapshot provenance")
        let restoredReopened = ConversationStore(file: restored.file)
        try require(restoredReopened.conversations[0].letterContext == letter.letterContext, "Backup copy SQLite reopen preserves snapshot")

        let (activity, captured, _, attempt) = try store.beginReply(in: letter.id, to: letter.messages[0].id)
        defer { store.endActivity(activity) }
        let scope = try ConversationReplyScope(store: store, activity: activity, conversation: captured, attempt: attempt)
        let suite = "com.pendingname.aauv.automatic-letter-fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalToolPreference.enabledKey)
        let tools = try ConversationLocalTools(store: store, activity: activity, conversation: captured,
                                              attempt: attempt, method: .byok, defaults: defaults, validateRoute: {})
        try scope.bindLocalTools(tools)
        try scope.validate(); try tools.validate()
        var replacement = conversation(store, letter.id)
        replacement.letterContext = LetterContext(sourceConversationID: source.id, capturedAt: now.addingTimeInterval(1),
                                                   messages: letter.letterContext!.messages)
        replacement.messages = []
        // Real Core header mutation simulates a later snapshot arriving. No remote
        // request, guessed revision, private setter or test-only production hook.
        try store.requireDatabase().update(letter.id.uuidString, header: String(decoding: encoded(replacement), as: UTF8.self), message: "")
        try store.reloadReplica()
        let refreshed = conversation(store, letter.id)
        try require(store.activities[letter.id] == activity && refreshed.bot == captured.bot &&
                    refreshed.historyRevision == captured.historyRevision && refreshed.messages.map(\.id) == captured.messages.map(\.id) &&
                    refreshed.replyAttempts?.contains { $0.id == attempt.id && $0.phase == .preparing } == true &&
                    refreshed.letterContext == replacement.letterContext && refreshed.letterContext != captured.letterContext,
                    "Snapshot replacement alone changes the binding; activity, bot and live attempt remain current")
        do { try scope.validate(); preconditionFailure("ReplyScope accepted a replaced letter snapshot") }
        catch is CancellationError {}
        do { try tools.validate(); preconditionFailure("LocalTools accepted a replaced letter snapshot") }
        catch is ChatClient.ClientError {}
    }

    private static func attachmentRetention(_ directory: URL) throws {
        let store = ConversationStore(file: directory.appending(path: "chats.json"))
        let target = bot()
        let bytes = Data("synthetic retained attachment".utf8)
        let attachment = Attachment(name: "background.txt", fileName: UUID().uuidString, size: bytes.count)
        try FileManager.default.createDirectory(at: store.attachmentDirectory, withIntermediateDirectories: true)
        let file = try store.attachmentURL(attachment)
        try bytes.write(to: file)
        var source = chat(target, content: "question with background file", age: 3_600)
        source.messages[0].attachments = [attachment]
        try store.insert(source)
        let letter = try LetterGeneration.makeConversation(bot: target, conversations: store.conversations, policy: policy, now: now)
        try require(letter.attachments?.map(\.fileName) == [attachment.fileName] && letter.messages[0].attachments == nil,
                    "Background file references use the known header, not trigger attachments")
        try require(ConversationLocalTools.attachmentManifest(letter.allAttachments).contains(attachment.id.uuidString.lowercased()),
                    "Retained header references are visible to the existing attachment-tool manifest")
        try store.insert(letter)
        try store.deleteMessage(source.messages[0].id, in: source.id)
        try require(FileManager.default.fileExists(atPath: file.path) && (try Data(contentsOf: file)) == bytes,
                    "Real deletion cleanup keeps background bytes referenced by the new letter header")
        try require(try store.filesForReply(in: letter, to: letter.messages[0]).isEmpty,
                    "The new action does not eagerly re-upload historical header attachments")
        var explicit = letter.messages[0]; explicit.attachments = [attachment]
        try require(try store.filesForReply(in: letter, to: explicit).count == 1,
                    "Explicit current-message attachments remain eligible for the ordinary request path")
    }
}
