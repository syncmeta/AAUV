import Foundation

@main @MainActor
struct RecentBotSubmissionTests {
    private static var checks: [String] = []

    private static func expect(_ value: Bool, _ name: String) {
        precondition(value, name)
        checks.append(name)
    }

    private static func profiles() throws -> [LocalBot] {
        try [LocalBot(configuration: .init(name: "Submission A", endpoint: "https://submission-a.invalid/v1",
                model: "synthetic-a", loginMethod: .byok, apiProtocol: "responses")),
             LocalBot(configuration: .init(name: "Submission B", endpoint: "https://submission-b.invalid/v1",
                model: "synthetic-b", loginMethod: .byok, apiProtocol: "responses"))].map { try $0.validated() }
    }

    private static func setup(_ root: URL, defaults: UserDefaults) throws -> (ConversationStore, BotSnapshot, BotSnapshot) {
        let store = ConversationStore(file: root.appending(path: "store/conversations.json"))
        expect(store.loadError == nil, "PrivateSQLiteOpened")
        let bots = try profiles()
        try store.saveBots(bots)
        let a = bots[0].snapshot, b = bots[1].snapshot
        DefaultBotSelection.remember(a, bots: store.bots, defaults: defaults)
        return (store, a, b)
    }

    private static func current(_ store: ConversationStore, _ defaults: UserDefaults) -> BotSnapshot {
        DefaultBotSelection.currentBot(bots: store.bots, defaults: defaults)
    }

    private static func pendingBytes(_ store: ConversationStore) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.pendingReplica())
    }

    private static func withDefaults(_ suffix: String, run: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "com.pendingname.aauv.recent-submission-tests." + suffix + "." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await run(defaults)
    }

    static func main() async throws {
        // Root's runner supplies a new private directory. No normal store or
        // standard defaults are used by these tests.
        guard let path = ProcessInfo.processInfo.environment["AAUV_RECENT_BOT_TEST_ROOT"] else {
            fatalError("A private test root must be supplied by the scoped runner")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        precondition(root.standardizedFileURL.path == root.resolvingSymlinksInPath().path)
        precondition(FileManager.default.fileExists(atPath: root.path))
        try await withDefaults("preview") { try previewDoesNotRemember(root.appending(path: "preview"), defaults: $0) }
        try await withDefaults("closed-db") { try closedSQLiteDoesNotRemember(root.appending(path: "closed-db"), defaults: $0) }
        try await withDefaults("partial-file") { try partialAttachmentFailureDoesNotRemember(root.appending(path: "partial-file"), defaults: $0) }
        try await withDefaults("submission") { try await submissionsAndCapturedFiles(root.appending(path: "submission"), defaults: $0) }
        try await withDefaults("letter") { try letterCommitsBeforeLateCompletion(root.appending(path: "letter"), defaults: $0) }
        try await withDefaults("letter-failure") { try failedLetterAndVoiceSavesKeepSelection(root.appending(path: "letter-failure"), defaults: $0) }
        let result: [String: Any] = ["status": "passed", "checks": checks,
            "realSQLiteAndShareInboxUsed": true, "modelOrCloudOrNormalDataAccessed": false,
            "lateUIReplyCallbackExecuted": false,
            "boundary": "Shared user/voice save helpers, real letter request insertion, SQLite and durable activity transitions. AAUVApp callback removal and SwiftUI wiring require separate source review; no full GUI or real provider acceptance."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    private static func previewDoesNotRemember(_ root: URL, defaults: UserDefaults) throws {
        let (store, a, b) = try setup(root, defaults: defaults)
        let before = defaults.data(forKey: "recentBot")
        let pending = try pendingBytes(store)
        var previews = UnsentConversations()
        let preview = previews.open(bot: b, reusing: true)
        expect(previews.open(bot: b, reusing: true).id == preview.id, "PreviewReusesOnlyItsUnsentConversation")
        previews.changeBot(a, in: preview.id)
        previews.changeBot(b, in: preview.id)
        expect(previews[preview.id]?.bot == b && current(store, defaults) == a && defaults.data(forKey: "recentBot") == before,
               "OpeningAndChangingUnsentPreviewKeepRecentA")
        let reopened = ConversationStore(file: store.file)
        expect(store.conversations.isEmpty && reopened.loadError == nil && reopened.conversations.isEmpty,
               "PreviewCreatesNoSQLiteConversation")
        expect(try pendingBytes(store) == pending, "PreviewCreatesNoReplicaMutation")
    }

    private static func closedSQLiteDoesNotRemember(_ root: URL, defaults: UserDefaults) throws {
        let (store, a, b) = try setup(root, defaults: defaults)
        let before = defaults.data(forKey: "recentBot")
        let pending = try pendingBytes(store)
        var previews = UnsentConversations()
        let preview = previews.open(bot: b)
        try store.requireDatabase().close()
        var failed = false
        do {
            _ = try DefaultBotSelection.savingUserMessage(with: b, bots: store.bots, defaults: defaults) {
                try store.sendFirstMessage("Must fail against the closed real SQLite handle", files: [], in: preview)
            }
        } catch { failed = true }
        expect(failed && current(store, defaults) == a && defaults.data(forKey: "recentBot") == before,
               "ActualSQLiteFailureDoesNotRememberB")
        let reopened = ConversationStore(file: store.file)
        expect(store.conversations.isEmpty && reopened.loadError == nil && reopened.conversations.isEmpty && previews[preview.id] != nil,
               "ActualSQLiteFailureLeavesNoChatAndRetainsPreview")
        expect(try pendingBytes(reopened) == pending, "ActualSQLiteFailureLeavesNoNewReplicaRows")
    }

    private static func partialAttachmentFailureDoesNotRemember(_ root: URL, defaults: UserDefaults) throws {
        let (store, a, b) = try setup(root, defaults: defaults)
        let before = defaults.data(forKey: "recentBot")
        let pending = try pendingBytes(store)
        let firstSource = root.appending(path: "first.bin"), secondSource = root.appending(path: "second.bin")
        try Data([0, 1, 2, 255]).write(to: firstSource)
        try Data([3, 4, 5, 254]).write(to: secondSource)
        let first = try DraftAttachment(firstSource), missing = try DraftAttachment(secondSource)
        try FileManager.default.removeItem(at: missing.url)
        var previews = UnsentConversations()
        let preview = previews.open(bot: b)
        var failed = false
        do {
            _ = try DefaultBotSelection.savingUserMessage(with: b, bots: store.bots, defaults: defaults) {
                try store.sendFirstMessage("Partial attachment copy must roll back", files: [first, missing], in: preview)
            }
        } catch { failed = true }
        expect(failed && current(store, defaults) == a && defaults.data(forKey: "recentBot") == before,
               "SecondAttachmentCopyFailureDoesNotRememberB")
        let firstDestination = try store.attachmentURL(first.attachment)
        let missingDestination = try store.attachmentURL(missing.attachment)
        expect(!FileManager.default.fileExists(atPath: firstDestination.path) && !FileManager.default.fileExists(atPath: missingDestination.path)
               && FileManager.default.fileExists(atPath: first.url.path), "PartialAttachmentRollbackRemovesDurableCopiesAndKeepsDraftSource")
        let reopened = ConversationStore(file: store.file)
        expect(store.conversations.isEmpty && reopened.loadError == nil && reopened.conversations.isEmpty && previews[preview.id] != nil,
               "PartialAttachmentFailureLeavesNoChatAndRetainsPreview")
        expect(try pendingBytes(reopened) == pending, "PartialAttachmentFailureLeavesNoNewReplicaRows")
    }

    private static func capture(_ source: URL, from store: ConversationStore, defaults: UserDefaults, inbox: ShareInbox) async throws -> Data {
        // This is the same entrance-time snapshot and original capture API as
        // queueIncoming; it deliberately does not consult the eventual reply.
        let data = try JSONEncoder().encode(current(store, defaults).boundForNewChat())
        let failures = try await Task.detached { try inbox.capture([source], botSnapshot: data) }.value
        expect(failures.isEmpty, "OriginalShareInboxCaptureSucceeded")
        return data
    }

    private static func submissionsAndCapturedFiles(_ root: URL, defaults: UserDefaults) async throws {
        let (store, a, b) = try setup(root, defaults: defaults)
        var previews = UnsentConversations()
        let aPreview = previews.open(bot: a)
        _ = try DefaultBotSelection.savingUserMessage(with: a, bots: store.bots, defaults: defaults) {
            try store.sendFirstMessage("Existing A history", files: [], in: aPreview)
        }
        let inbox = ShareInbox(root: root.appending(path: "OpenInbox"))
        let beforeFile = root.appending(path: "before-B.bin"), afterFile = root.appending(path: "after-B.bin")
        let beforeBytes = Data([11, 12, 13]), afterBytes = Data([21, 22, 23, 255])
        try beforeBytes.write(to: beforeFile); try afterBytes.write(to: afterFile)
        let aData = try await capture(beforeFile, from: store, defaults: defaults, inbox: inbox)
        expect(try inbox.pending().count == 1 && inbox.pending()[0].botSnapshot == aData, "OldFileCapturedAAtEntrance")

        let bPreview = previews.open(bot: b)
        let bMessageID = try DefaultBotSelection.savingUserMessage(with: b, bots: store.bots, defaults: defaults) {
            try store.sendFirstMessage("B is saved before any model reply", files: [], in: bPreview)
        }
        let bStored = store.conversations.first { $0.id == bPreview.id }!
        expect(current(store, defaults) == b && bStored.messages.count == 1 && bStored.messages[0].id == bMessageID
               && bStored.messages[0].role == .user && bStored.bot == b, "RealBFirstSaveReturnsItsMessageAndImmediatelyRemembersBWithoutReply")
        let reopenedB = ConversationStore(file: store.file)
        expect(reopenedB.loadError == nil && reopenedB.conversations.first { $0.id == bPreview.id }?.messages.first?.id == bMessageID,
               "BUserMessageAlreadyDurableInIndependentSQLiteReopen")
        let bData = try await capture(afterFile, from: store, defaults: defaults, inbox: inbox)
        let queued = try inbox.pending()
        let oldItem = queued.first { $0.file.lastPathComponent == beforeFile.lastPathComponent }!
        let newItem = queued.first { $0.file.lastPathComponent == afterFile.lastPathComponent }!
        expect(oldItem.botSnapshot == aData && newItem.botSnapshot == bData, "NewFileCapturesBWhileOldQueuedFileKeepsA")

        let (activity, _, _, initial) = try store.beginReply(in: bPreview.id, to: bMessageID)
        var attempt = initial
        attempt.phase = .submitted; attempt.partial = "Synthetic saved partial, without a provider request"
        try store.saveAttempt(attempt, to: bPreview.id)
        await Task.yield()
        expect(current(store, defaults) == b && store.conversations.first { $0.id == bPreview.id }?.replyAttempts?.first?.phase == .submitted,
               "RealDurableWaitingAttemptDoesNotDelayOrUndoBSelection")
        attempt.phase = .interrupted
        try store.saveAttempt(attempt, to: bPreview.id)
        store.endActivity(activity)
        let reopenedInterrupted = ConversationStore(file: store.file)
        expect(current(store, defaults) == b && reopenedInterrupted.loadError == nil
               && reopenedInterrupted.conversations.first { $0.id == bPreview.id }?.replyAttempts?.first?.phase == .interrupted,
               "RealDurableInterruptedAttemptDoesNotUndoBSelection")
        expect(store.conversations.first { $0.id == bPreview.id }!.messages.allSatisfy { $0.role == .user },
               "BSelectionDoesNotRequireAnyAssistantCompletion")

        // Resolve actual queued files through original stage/openFile, with an
        // intentionally different fallback to prove the frozen snapshot wins.
        let oldStaged = try await store.stageFileOpen(oldItem.file, shareID: oldItem.id)
        let oldID = try store.openFile(oldStaged, bot: b, shareID: oldItem.id, capturedBot: oldItem.botSnapshot)
        let oldChat = store.conversations.first { $0.id == oldID }!
        expect(oldChat.bot == a && current(store, defaults) == b, "ActualOldOpenFileKeepsEntranceAWhileCurrentIsB")
        try inbox.consume(oldItem)

        let count = store.conversations.count
        let followUp = try DefaultBotSelection.savingUserMessage(with: a, bots: store.bots, defaults: defaults) {
            try store.appendUserMessage("Later user submission in existing A", files: [], to: aPreview.id)
        }
        let final = ConversationStore(file: store.file)
        expect(current(store, defaults) == a && store.conversations.count == count && final.loadError == nil
               && final.conversations.first { $0.id == aPreview.id }?.messages.last?.id == followUp,
               "ActualExistingAUserAppendSwitchesRecentBackToAWithoutNewChat")
        let pendingAfterA = try ShareInbox(root: inbox.root).pending()
        expect(pendingAfterA.count == 1 && pendingAfterA[0].id == newItem.id && pendingAfterA[0].botSnapshot == bData,
               "RealInboxReopenAfterAStillHasOriginalQueuedBSnapshot")
        let frozenB = pendingAfterA[0]
        let newStaged = try await store.stageFileOpen(frozenB.file, shareID: frozenB.id)
        let newID = try store.openFile(newStaged, bot: a, shareID: frozenB.id, capturedBot: frozenB.botSnapshot)
        let newChat = store.conversations.first { $0.id == newID }!
        expect(newChat.bot == b && current(store, defaults) == a, "ActualQueuedBOpenAfterLaterASubmissionDoesNotRebindOrChangeRecent")
        expect(try Data(contentsOf: store.attachmentURL(newChat.attachments![0])) == afterBytes
               && Data(contentsOf: store.attachmentURL(oldChat.attachments![0])) == beforeBytes,
               "QueuedFilesReachRealPersistentAttachmentStorageWithExactBytes")
        try inbox.consume(frozenB)
        expect(try inbox.pending().isEmpty, "OwnedShareInboxConsumedWithoutReplay")
    }

    private static func letterCommitsBeforeLateCompletion(_ root: URL, defaults: UserDefaults) throws {
        let (store, a, b) = try setup(root, defaults: defaults)
        DefaultBotSelection.remember(b, bots: store.bots, defaults: defaults)
        let letter = try LetterGeneration.makeConversation(bot: a, conversations: store.conversations, policy: .init())
        try DefaultBotSelection.savingUserMessage(with: a, bots: store.bots, defaults: defaults) {
            try store.insert(letter)
        }
        let trigger = letter.messages[0]
        expect(current(store, defaults) == a && letter.isLetter && trigger.role == .user,
               "RealManualLetterRequestSaveImmediatelyRemembersAWithoutModelReply")
        let (activityA, captured, _, attemptA) = try store.beginReply(in: letter.id, to: trigger.id)
        defer { store.endActivity(activityA) }
        let scopeA = try ConversationReplyScope(store: store, activity: activityA, conversation: captured, attempt: attemptA)
        var previews = UnsentConversations()
        let bChat = previews.open(bot: b)
        let bUser = try DefaultBotSelection.savingUserMessage(with: b, bots: store.bots, defaults: defaults) {
            try store.sendFirstMessage("A later ordinary B user request", files: [], in: bChat)
        }
        let (activityB, _, _, _) = try store.beginReply(in: bChat.id, to: bUser)
        defer { store.endActivity(activityB) }
        let selectedB = defaults.data(forKey: "recentBot")
        try scopeA.validate()
        expect(store.activities.count == 2 && current(store, defaults) == b,
               "ActualConcurrentLetterAAndOrdinaryBActivitiesKeepNewUserSelectionB")
        let answer = ChatMessage(role: .assistant, content: "Late synthetic letter A response")
        try store.complete(answer, attempt: attemptA, in: letter.id)
        let reopened = ConversationStore(file: store.file)
        expect(current(store, defaults) == b && defaults.data(forKey: "recentBot") == selectedB
               && reopened.loadError == nil
               && reopened.conversations.first(where: { $0.id == letter.id })?.messages.last?.id == answer.id,
               "RealLateLetterCompletionPersistsAnswerWithoutReorderingRecentB")
        store.endActivity(activityA)
        let (regeneration, _, _, regenerated) = try store.beginReply(in: letter.id, to: trigger.id, regenerating: true)
        defer { store.endActivity(regeneration) }
        try store.complete(.init(role: .assistant, content: "Synthetic regenerated letter A"), attempt: regenerated, in: letter.id)
        expect(current(store, defaults) == b && defaults.data(forKey: "recentBot") == selectedB,
               "RealLetterRegenerationOfOldUserRequestDoesNotReorderRecentB")
    }

    private static func failedLetterAndVoiceSavesKeepSelection(_ root: URL, defaults: UserDefaults) throws {
        let (store, a, b) = try setup(root, defaults: defaults)
        let original = defaults.data(forKey: "recentBot")
        let letter = try LetterGeneration.makeConversation(bot: b, conversations: [], policy: .init())
        let voice = Conversation(title: "Existing voice target", bot: b)
        try store.insert(voice)
        let baseline = try pendingBytes(store)
        try store.requireDatabase().close()
        var failedInsert = false
        do {
            try DefaultBotSelection.savingUserMessage(with: b, bots: store.bots, defaults: defaults) {
                try store.insert(letter)
            }
        } catch { failedInsert = true }
        expect(failedInsert && current(store, defaults) == a && defaults.data(forKey: "recentBot") == original,
               "ActualFailedManualLetterInsertLeavesRecentAUnchanged")
        var failedVoice = false
        let voiceUser = ChatMessage(role: .user, content: "Voice transcript that cannot be stored")
        do {
            try DefaultBotSelection.savingMessage(voiceUser, with: b, bots: store.bots, defaults: defaults) {
                try store.append(voiceUser, to: voice.id)
            }
        } catch { failedVoice = true }
        expect(failedVoice && current(store, defaults) == a && defaults.data(forKey: "recentBot") == original,
               "ActualFailedVoiceUserSaveLeavesRecentAUnchanged")
        let reopened = ConversationStore(file: store.file)
        let reopenedPending = try pendingBytes(reopened)
        expect(reopened.loadError == nil && reopened.conversations.count == 1
               && reopened.conversations[0].id == voice.id && reopened.conversations[0].messages.isEmpty
               && reopenedPending == baseline,
               "FailedLetterAndVoiceSavesLeaveIndependentSQLiteBaselineUnchanged")
    }
}
