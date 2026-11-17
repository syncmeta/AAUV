import Foundation

@MainActor private final class TraceGate {
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var released = Set<String>()
    func wait(_ key: String) async {
        if released.contains(key) { return }
        await withCheckedContinuation { waiters[key] = $0 }
    }
    func release(_ key: String) { released.insert(key); waiters.removeValue(forKey: key)?.resume() }
}

@main @MainActor struct LocalToolTraceProducerTests {
    private static func check(_ value: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) throws {
        let passed = try value()
        precondition(passed, file: file, line: line)
    }
    private static func rejected(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected stale/invalid metadata rejection") } catch {}
    }
    private static func call(_ name: String, arguments: String = "{}", id: String = UUID().uuidString) -> LocalToolCall {
        .init(id: nil, callID: id, name: name, namespace: "", arguments: arguments)
    }
    static func main() async throws {
        try previewAndResultMapping()
        try await independentCallsAndPersistenceFailure()
        try await realStoreAndScopes()
        try await concurrentContextCalls()
        try await monotonicReplicaTrace()
        try await imageBudgetAndCancellation()
        print("Local tool trace producer passed safe typed outcomes, independent concurrent call IDs, JSON domain errors, metadata-failure no-retry, late cancellation, real SQLite/Core bot/history/attempt guards, latest-run lifecycle, ordered monotonic replica merge, backup copies and serialized image quota/cancellation. Synthetic data only.")
    }

    private static func previewAndResultMapping() throws {
        let raw = #"budget OR \"last price\" https://user:password@example.invalid/path?access_token=URL_SECRET#secret Authorization: Bearer AUTH_SECRET Authorization: Basic BASIC_SECRET "access_token":"QUOTED_SECRET" access_token=ACCESS_SECRET sk-SYNTHETICSECRET ghp_SYNTHETICSECRET github_pat_SYNTHETICSECRET eyJabcdefgh.abcd.efgh"#
        let safe = LocalToolTraceObserver.queryPreview(raw)!
        try check(safe.text.contains("budget OR"))
        for value in ["https", "example", "URL_SECRET", "AUTH_SECRET", "BASIC_SECRET", "QUOTED_SECRET", "ACCESS_SECRET", "SYNTHETICSECRET", "eyJabcdefgh"] {
            try check(!safe.text.contains(value))
        }
        for unsafe in ["Bearer\u{0}CONTROL_SECRET", "Bearer\u{00A0}CONTROL_SECRET", "Bearer\u{2003}CONTROL_SECRET", "Authorization\u{0}: Bearer CONTROL_SECRET", "https://example.invalid/value\u{0}CONTROL_SECRET"] {
            try check(!LocalToolTraceObserver.queryPreview(unsafe)!.text.contains("CONTROL_SECRET"))
        }
        for unsafe in ["预算https://example.invalid/CHINESE_SECRET", "预算Bearer CHINESE_SECRET", "abcdefghijklmnop.abcdefghijklmnop.abcdefghijklmnop"] {
            let preview = LocalToolTraceObserver.queryPreview(unsafe)!
            try check(!preview.text.contains("CHINESE_SECRET") && !preview.text.contains("abcdefghijklmnop"))
            _ = try LocalToolTrace.Event(id: UUID(), function: .searchChatHistory, state: .running, query: preview.text).validated()
        }
        try check(LocalToolTraceObserver.queryPreview(String(repeating: "x", count: 1025)) == nil)
        let clippedWords = LocalToolTraceObserver.queryPreview(String(repeating: "a ", count: 129))!
        try check(clippedWords.truncated && clippedWords.text.last != " " && LocalToolTraceObserver.queryPreview(clippedWords.text)!.text == clippedWords.text)
        let long = LocalToolTraceObserver.queryPreview(String(repeating: "文", count: 300) + " https://example.invalid/SECRET")!
        try check(long.truncated && long.text.unicodeScalars.count == 256 && !long.text.contains("SECRET"))
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["query": raw, "extra": "RAW_ARGUMENT_SECRET"]), as: UTF8.self)
        let start = LocalToolTraceObserver.running(call: call("search_chat_history", arguments: arguments), function: .searchChatHistory)
        _ = try start.validated()
        let success = LocalToolTraceObserver.completed(start, result: .init(output: #"{"results":[{"content":"SEARCH_SNIPPET_SECRET"},{"content":"SECOND_SECRET"}],"hint":"RAW_HINT"}"#))
        try check(success.state == .succeeded && success.quantity == 2)
        let failure = LocalToolTraceObserver.completed(start, result: .init(output: #"{"error":"provider https://secret.invalid/?key=RAW_ERROR_SECRET"}"#))
        try check(failure.state == .failed && failure.failure == .toolFailed)
        let events: [LocalToolTrace.Event] = [success, .init(id: UUID(), function: .readAttachment, state: .failed, failure: .unavailable)]
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for value in ["RAW_ARGUMENT_SECRET", "SEARCH_SNIPPET_SECRET", "RAW_HINT", "RAW_ERROR_SECRET"] { try check(!encoded.contains(value)) }
        let read = LocalToolTraceObserver.running(call: call("read_attachment"), function: .readAttachment)
        let observed = LocalToolTraceObserver.completed(read, result: .init(output: #"{"answer":"A😀中","attachment_id":"RAW_FILE_ID","model_slug":"RAW_ROUTE"}"#))
        try check(observed.state == .succeeded && observed.quantity == 4)
        let image = LocalToolTraceObserver.running(call: call("send_images"), function: .sendImages)
        try check(LocalToolTraceObserver.completed(image, result: .init(output: #"{"ok":true,"sent":5}"#)).state == .failed)
        let partial = LocalToolTraceObserver.completed(image, result: .init(output: "{}", images: .init(prepared: 2, unavailable: 1, cancelled: true)))
        try check(partial.state == .partial && partial.quantity == 2 && partial.failure == nil)
        _ = try partial.validated()
    }

    private static func independentCallsAndPersistenceFailure() async throws {
        let gate = TraceGate()
        var events: [LocalToolTrace.Event] = []
        var firstID: UUID?, secondID: UUID?
        let first = Task {
            try await LocalToolTraceObserver.perform(call: call("read_attachment", id: "same-name-a"), persist: { events.append($0) }, scopeIsCurrent: { true }) {
                firstID = events.last!.id
                await gate.wait("first")
                return .init(output: #"{"answer":"FIRST😀"}"#)
            }
        }
        let second = Task {
            try await LocalToolTraceObserver.perform(call: call("read_attachment", id: "same-name-b"), persist: { events.append($0) }, scopeIsCurrent: { true }) {
                secondID = events.last!.id
                await gate.wait("second")
                return .init(output: #"{"answer":"B"}"#)
            }
        }
        for _ in 0..<10 { await Task.yield() }
        try check(events.count == 2 && events.allSatisfy { $0.state == .running } && events[0].id != events[1].id)
        try check(firstID != nil && secondID != nil && firstID != secondID)
        gate.release("second"); _ = try await second.value
        gate.release("first"); _ = try await first.value
        try check(events[2].id == secondID && events[2].quantity == 1 && events[3].id == firstID && events[3].quantity == 7)
        var businessCount = 0
        let unchanged = try await LocalToolTraceObserver.perform(call: call("search_chat_history"), persist: { _ in throw CocoaError(.fileWriteUnknown) }, scopeIsCurrent: { true }) {
            businessCount += 1
            return .init(output: #"{"results":[]}"#)
        }
        try check(businessCount == 1 && unchanged == #"{"results":[]}"#)
        var cancelledEvents: [LocalToolTrace.Event] = []
        let late = Task {
            try await LocalToolTraceObserver.perform(call: call("delegate_to_specialist"), persist: { cancelledEvents.append($0) }, scopeIsCurrent: { true }) {
                await gate.wait("late")
                return .init(output: #"{"answer":"confirmed"}"#)
            }
        }
        for _ in 0..<10 { await Task.yield() }
        late.cancel(); gate.release("late"); _ = try await late.value
        try check(cancelledEvents.last?.state == .succeeded && cancelledEvents.last?.quantity == 9)
        let cancelled = Task {
            try await LocalToolTraceObserver.perform(call: call("read_attachment"), persist: { cancelledEvents.append($0) }, scopeIsCurrent: { true }) {
                try await Task.sleep(for: .seconds(10)); return .init(output: "{}")
            }
        }
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation was swallowed") } catch is CancellationError {}
        try check(cancelledEvents.last?.state == .interrupted && cancelledEvents.last?.failure == nil)
    }

    @MainActor private struct Fixture {
        let directory: PrivateTemporaryDirectory
        let store: ConversationStore
        let defaults: UserDefaults
        let suite: String
        let id: UUID
        let message: ChatMessage
        let activity: ConversationStore.Activity
        let conversation: Conversation
        let attempt: ReplyAttempt
        init() throws {
            directory = try PrivateTemporaryDirectory()
            store = ConversationStore(file: directory.url.appending(path: "chats.json"))
            suite = "com.pendingname.aauv.tool-trace-producer." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            let bot = BotSnapshot(name: "synthetic", endpoint: "https://synthetic.invalid/v1", model: "synthetic", loginMethod: .byok, apiProtocol: "responses")
            id = try store.create(bot: bot)
            message = ChatMessage(role: .user, content: "needle SYNTHETIC_QUESTION")
            try store.append(message, to: id)
            (activity, conversation, _, attempt) = try store.beginReply(in: id, to: message.id)
        }
        func context(cloud: LocalCloudTools? = nil, image: ConversationLocalTools.ImagePerformer? = nil,
                     record: (@MainActor @Sendable (LocalToolTrace.Event) throws -> Void)? = nil) throws -> ConversationLocalTools {
            try ConversationLocalTools(store: store, activity: activity, conversation: conversation, attempt: attempt, method: .byok,
                                       defaults: defaults, validateRoute: {}, cloudTools: cloud, recordBreadcrumb: record,
                                       imagePerformer: image ?? { arguments, proxy, scope, limits in
                try await LocalImageTools.perform(arguments: arguments, proxy: proxy, validateScope: scope, limits: limits)
            })
        }
        func trace() -> LocalToolTrace? { store.conversations.first { $0.id == id }?.messages.first { $0.id == message.id }?.localToolTrace }
        func record(_ entry: LocalToolTrace.Event) throws {
            try store.recordLocalToolBreadcrumb(entry, conversationID: id, userMessageID: message.id, requestID: attempt.id,
                                                expectedBot: conversation.bot, historyRevision: conversation.historyRevision)
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    private static func realStoreAndScopes() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let context = try f.context()
        f.defaults.set("legitimate-other-provider-refresh", forKey: APIKey.revisionKey)
        try context.validate()
        var changes = 0
        f.store.onLocalChange = { changes += 1 }
        _ = try await context.execution.perform(call("search_chat_history", arguments: #"{"query":"needle"}"#))
        try check(f.trace()?.entries.count == 1 && f.trace()?.entries[0].state == .succeeded && f.trace()?.entries[0].quantity == 1)
        _ = try await context.execution.perform(call("create_skill", arguments: #"{"name":"trace-skill","description":"SKILL_DESCRIPTION_SECRET","body":"SKILL_BODY_SECRET"}"#))
        _ = try await context.execution.perform(call("search_chat_history", arguments: #"{"query":"needle"}"#))
        _ = try await context.execution.perform(call("create_skill", arguments: #"{"name":"INVALID NAME","body":"private"}"#))
        let trace = f.trace()!
        try check(trace.entries.count == 4 && trace.entries[1].state == .succeeded && trace.entries[1].skillName == "trace-skill")
        try check(trace.entries[2].state == .succeeded && trace.entries[3].state == .failed && trace.entries[3].failure == .invalidInput)
        let encoded = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        try check(!encoded.contains("SKILL_BODY_SECRET") && !encoded.contains("SKILL_DESCRIPTION_SECRET") && !encoded.contains("synthetic.invalid"))
        let peer = ConversationStore(file: f.store.file)
        try peer.rename(f.id, to: "peer title must survive")
        let running = LocalToolTrace.Event(id: UUID(), function: .readAttachment, state: .running)
        try f.record(running)
        let reopened = ConversationStore(file: f.store.file)
        try check(reopened.conversations.first?.title == "peer title must survive")
        try check(reopened.conversations.first?.messages.first?.localToolTrace?.entries.count == 5)
        var failed = f.attempt; failed.phase = .failed
        let beforeTerminal = changes
        try f.store.saveAttempt(failed, to: f.id)
        try check(changes == beforeTerminal + 1)
        try check(f.trace()?.entries.last?.state == .interrupted && f.trace()?.entries[0].state == .succeeded)

        // A different device's running trace has no local durable attempt. A
        // normal header update must preserve it rather than guessing failure.
        let foreignID = try f.store.create(bot: f.conversation.bot)
        var remote = ChatMessage(role: .user, content: "REMOTE_RUNNING_USER")
        remote.localToolTrace = LocalToolTrace(requestID: UUID(), runRevision: "0000000000000000001", entries: [.init(id: UUID(), sequence: 0, function: .readAttachment, state: .running)])
        let remoteRecord = ReplicaRecord(name: "m-" + remote.id.uuidString, kind: "message", conversation: foreignID.uuidString,
                                         revision: "9000000000000000000", payload: String(decoding: try JSONEncoder().encode(remote), as: UTF8.self))
        try f.store.applyReplicaPayload(.inline(.init(record: remoteRecord, files: [:])))
        try f.store.reloadReplica()
        try f.store.rename(foreignID, to: "remote trace kept")
        try check(f.store.conversations.first { $0.id == foreignID }?.messages.first?.localToolTrace?.entries.first?.state == .running)
        let backup = try BackupFile.create(snapshot: f.store.backupSnapshot(settings: nil), attachments: f.store.attachmentDirectory)
        let prepared = try PreparedBackup.read(backup.url)
        let restored = ConversationStore(file: f.directory.url.appending(path: "restored/chats.json"))
        try await restored.importBackup(prepared, restoreInstructions: false, restoreSettings: false)
        let restoredUser = restored.conversations.flatMap(\.messages).first { $0.content == f.message.content }!
        try check(restoredUser.id != f.message.id && restoredUser.localToolTrace?.requestID == f.attempt.id)
        try check(restoredUser.localToolTrace?.entries.first?.state == .succeeded)
        let restoredRemote = restored.conversations.flatMap(\.messages).first { $0.content == remote.content }!
        try check(restoredRemote.localToolTrace?.entries.first?.state == .interrupted)
        let synced = ConversationStore(file: f.directory.url.appending(path: "synced/chats.json"))
        for record in try f.store.pendingReplica().reversed() {
            try synced.applyReplicaPayload(.inline(.init(record: record, files: [:])))
        }
        try synced.reloadReplica()
        try check(synced.conversations.flatMap(\.messages).first { $0.id == f.message.id }?.localToolTrace == f.trace())
        f.store.endActivity(f.activity)
        let (newActivity, _, _, newAttempt) = try f.store.beginReply(in: f.id, to: f.message.id, regenerating: true)
        try check(f.trace()?.entries.isEmpty == true && f.trace()?.requestID == newAttempt.id && f.trace()!.runRevision > trace.runRevision)
        f.store.endActivity(newActivity)
        rejected { try f.record(.init(id: UUID(), function: .searchChatHistory, state: .running)) }

        let b = try Fixture(); defer { b.cleanup() }
        let stale = try b.context()
        let peerB = ConversationStore(file: b.store.file)
        var replacement = b.conversation.bot!; replacement.model = "other-model"
        try peerB.changeBot(replacement, in: b.id, expected: b.conversation.bot)
        rejected { try b.record(.init(id: UUID(), function: .searchChatHistory, state: .running)) }
        do { _ = try await stale.execution.perform(call("create_skill", arguments: #"{"name":"must-not-create","body":"no"}"#)); preconditionFailure("Changed durable bot allowed stale business") } catch {}
        let h = try Fixture(); defer { h.cleanup() }
        let peerH = ConversationStore(file: h.store.file)
        let extra = ChatMessage(role: .assistant, content: "unrelated history item", replyTo: h.message.id)
        try peerH.append(extra, to: h.id)
        try peerH.deleteMessage(extra.id, in: h.id)
        rejected { try h.record(.init(id: UUID(), function: .searchChatHistory, state: .running)) }
        let m = try Fixture(); defer { m.cleanup() }
        var writes = 0
        let metadataFailure = try m.context(record: { _ in writes += 1; throw CocoaError(.fileWriteUnknown) })
        _ = try await metadataFailure.execution.perform(call("create_skill", arguments: #"{"name":"metadata-fails-once","body":"one business operation"}"#))
        let library = try m.store.readInstructions()
        try check(writes == 2 && library.skillEntries?.filter { $0.name == "metadata-fails-once" }.count == 1 && m.trace()?.entries.isEmpty == true)
    }

    private static func concurrentContextCalls() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let gate = TraceGate()
        let attachment = Attachment(name: "SYNTHETIC_FILE_NAME", fileName: UUID().uuidString, size: 1)
        let url = f.directory.url.appending(path: "synthetic.bin")
        try Data([1]).write(to: url)
        weak var current: ConversationLocalTools?
        let cloud = LocalCloudTools(attachments: [attachment], prepareAttachment: { value in
            .init(name: value.name, mediaType: "application/octet-stream", url: url, size: value.size)
        }, cloud: { prompt, _, _ in
            await gate.wait(prompt)
            return prompt == "first" ? "FIRST😀" : "B"
        }, validateScope: {
            guard let current else { throw LocalCloudTools.ScopeError.staleScope }
            try current.validate()
        })
        let context = try f.context(cloud: cloud)
        current = context
        func arguments(_ question: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["attachment_id": attachment.id.uuidString, "question": question]), as: UTF8.self)
        }
        let firstArgs = try arguments("first"), secondArgs = try arguments("second")
        let first = Task { try await context.execution.perform(call("read_attachment", arguments: firstArgs)) }
        for _ in 0..<20 { await Task.yield() }
        try check(f.trace()?.entries.count == 1)
        let firstID = f.trace()!.entries[0].id
        let second = Task { try await context.execution.perform(call("read_attachment", arguments: secondArgs)) }
        for _ in 0..<20 { await Task.yield() }
        try check(f.trace()?.entries.count == 2)
        let secondID = f.trace()!.entries[1].id
        try check(firstID != secondID)
        gate.release("second"); _ = try await second.value
        gate.release("first"); _ = try await first.value
        let entries = f.trace()!.entries
        try check(entries.first { $0.id == firstID }?.quantity == 7 && entries.first { $0.id == secondID }?.quantity == 1)
        try check(entries.allSatisfy { $0.state == .succeeded } && entries.map(\.sequence) == [0,1])
        let encoded = String(decoding: try JSONEncoder().encode(f.trace()), as: UTF8.self)
        try check(!encoded.contains(attachment.name) && !encoded.contains("FIRST") && !encoded.contains("synthetic.bin"))
    }

    private static func monotonicReplicaTrace() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = ChatMessage(role: .assistant, content: "original", replyTo: f.message.id)
        let alternate = ChatMessage(role: .assistant, content: "alternate", replyTo: f.message.id, isAlternative: true)
        try f.store.append(original, to: f.id); try f.store.append(alternate, to: f.id)
        let running = LocalToolTrace.Event(id: UUID(), function: .readAttachment, state: .running)
        try f.record(running)
        let peer = ConversationStore(file: f.directory.url.appending(path: "monotonic-peer/chats.json"))
        for record in try f.store.pendingReplica() { try peer.applyReplicaPayload(.inline(.init(record: record, files: [:]))) }
        try peer.reloadReplica()
        var succeeded = running; succeeded.state = .succeeded; succeeded.quantity = 7
        try f.record(succeeded)
        func latest(_ store: ConversationStore) throws -> ReplicaRecord {
            try store.pendingReplica().first { $0.name == "m-" + f.message.id.uuidString }!
        }
        let oldTerminal = try latest(f.store)
        try peer.selectReply(alternate.id, for: f.message.id, in: f.id)
        let newerBody = try latest(peer)
        try check(newerBody.revision > oldTerminal.revision)
        try f.store.applyReplicaPayload(.inline(.init(record: newerBody, files: [:])))
        try f.store.reloadReplica()
        try check(f.trace()?.entries.first?.state == .succeeded)
        try check(f.store.conversations.first { $0.id == f.id }?.messages.first { $0.id == f.message.id }?.selectedReplyID == alternate.id)

        let staleFile = Attachment(name: "old-body-file.bin", fileName: UUID().uuidString, size: 1)
        var payload = try JSONSerialization.jsonObject(with: Data(oldTerminal.payload.utf8)) as! [String: Any]
        payload["attachments"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([staleFile]))
        let oldWithFiles = ReplicaRecord(name: oldTerminal.name, kind: oldTerminal.kind, conversation: oldTerminal.conversation,
                                         revision: oldTerminal.revision, payload: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        var changes = 0; peer.onLocalChange = { changes += 1 }
        try peer.applyReplicaPayload(.inline(.init(record: oldWithFiles, files: [staleFile.fileName: Data([9])])))
        let merged = peer.conversations.first { $0.id == f.id }!.messages.first { $0.id == f.message.id }!
        try check(merged.selectedReplyID == alternate.id && merged.localToolTrace?.entries.first?.state == .succeeded)
        try check(!FileManager.default.fileExists(atPath: peer.attachmentDirectory.appending(path: staleFile.fileName).path) && changes > 0)
        let firstChanges = changes
        try peer.applyReplicaPayload(.inline(.init(record: oldWithFiles, files: [staleFile.fileName: Data([9])])))
        try check(changes == firstChanges)

        var failed = f.attempt; failed.phase = .failed; try f.store.saveAttempt(failed, to: f.id)
        f.store.endActivity(f.activity)
        let (activity, _, _, next) = try f.store.beginReply(in: f.id, to: f.message.id, regenerating: true)
        defer { f.store.endActivity(activity) }
        let reset = f.trace()!
        try check(reset.requestID == next.id && reset.entries.isEmpty)
        try peer.applyReplicaPayload(.inline(.init(record: try latest(f.store), files: [:])))
        try peer.reloadReplica()
        let forgedNewerBody = ReplicaRecord(name: oldTerminal.name, kind: oldTerminal.kind, conversation: oldTerminal.conversation,
                                            revision: "9000000000000000000", payload: oldTerminal.payload)
        try peer.applyReplicaPayload(.inline(.init(record: forgedNewerBody, files: [:])))
        try peer.reloadReplica()
        let barrier = peer.conversations.first { $0.id == f.id }!.messages.first { $0.id == f.message.id }!.localToolTrace!
        try check(barrier.requestID == reset.requestID && barrier.runRevision == reset.runRevision && barrier.entries.isEmpty)
    }

    private static func imageBudgetAndCancellation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let gate = TraceGate()
        var entered = 0
        var limits: [Int] = []
        var byteLimits: [Int] = []
        let cloud = LocalCloudTools(attachments: [], prepareAttachment: { _ in throw CancellationError() }, cloud: { _,_,_ in "unused" }, validateScope: {})
        let image: ConversationLocalTools.ImagePerformer = { arguments, proxy, scope, remaining in
            entered += 1; limits.append(remaining.imageCount); byteLimits.append(remaining.totalBytes)
            await gate.wait("image")
            return try await LocalImageTools.perform(arguments: arguments, proxy: proxy, validateScope: scope, limits: remaining)
        }
        let context = try f.context(cloud: cloud, image: image)
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["images": Array(repeating: png, count: 4)]), as: UTF8.self)
        let first = Task { try await context.execution.perform(call("send_images", arguments: arguments)) }
        for _ in 0..<10 { await Task.yield() }
        let waiting = Task { try await context.execution.perform(call("send_images", arguments: arguments)) }
        for _ in 0..<10 { await Task.yield() }
        try check(entered == 1)
        // A queued image call must not serialize unrelated search tools.
        _ = try await context.execution.perform(call("search_chat_history", arguments: #"{"query":"needle"}"#))
        waiting.cancel()
        do { _ = try await waiting.value; preconditionFailure("Queued cancellation was swallowed") } catch is CancellationError {}
        try check(entered == 1)
        gate.release("image"); _ = try await first.value
        _ = try await context.execution.perform(call("send_images", arguments: arguments))
        let files = context.drainGenerated().files
        try check(limits == [5,1] && files.count == 4)
        try check(byteLimits[0] - byteLimits[1] == files.reduce(0) { $0 + $1.data.count })
        let entries = f.trace()!.entries
        try check(entries.filter { $0.function == .sendImages && $0.state == .succeeded }.count == 1)
        try check(entries.contains { $0.function == .sendImages && $0.state == .interrupted })
        try check(entries.contains { $0.function == .sendImages && $0.state == .failed })

        let active = try Fixture(); defer { active.cleanup() }
        var activeCalls = 0
        let activeContext = try active.context(cloud: cloud, image: { arguments, proxy, scope, remaining in
            activeCalls += 1
            if activeCalls == 1 { try await Task.sleep(for: .seconds(10)) }
            return try await LocalImageTools.perform(arguments: arguments, proxy: proxy, validateScope: scope, limits: remaining)
        })
        let one = String(decoding: try JSONSerialization.data(withJSONObject: ["images": [png]]), as: UTF8.self)
        let owner = Task { try await activeContext.execution.perform(call("send_images", arguments: one)) }
        for _ in 0..<10 { await Task.yield() }
        try check(activeCalls == 1)
        owner.cancel()
        do { _ = try await owner.value; preconditionFailure("Active image cancellation was swallowed") } catch is CancellationError {}
        _ = try await activeContext.execution.perform(call("send_images", arguments: one))
        try check(activeCalls == 2 && activeContext.drainGenerated().files.count == 1)

        let partial = try Fixture(); defer { partial.cleanup() }
        let partialContext = try partial.context(cloud: cloud)
        let mixed = String(decoding: try JSONSerialization.data(withJSONObject: ["images": [png, "data:image/png;base64,invalid"]]), as: UTF8.self)
        _ = try await partialContext.execution.perform(call("send_images", arguments: mixed))
        let acquired = partialContext.drainGenerated()
        try check(acquired.files.count == 1 && acquired.unavailable == 1)
        try check(partial.trace()?.entries.last?.state == .partial && partial.trace()?.entries.last?.quantity == 1)
    }
}
