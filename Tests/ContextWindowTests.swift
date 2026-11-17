import CryptoKit
import Foundation

@main
struct ContextWindowTests {
    @MainActor static func main() async throws {
        let now = Date(timeIntervalSince1970: 200000)
        let old = ChatMessage(role: .assistant, content: "更早的历史", date: now.addingTimeInterval(-86401))
        let overflow = ChatMessage(role: .user, content: String(repeating: "绿", count: 100000), date: now.addingTimeInterval(-100))
        let newest = ChatMessage(role: .user, content: "继续当前任务", date: now)
        var calls = 0
        let prepared = try await ContextWindow.prepare([old, overflow, newest], now: now, cached: nil) { _ in
            calls += 1
            return "用户此前讨论了绿豆。"
        }
        precondition(calls > 0)
        precondition(prepared.messages.last?.id == newest.id)
        precondition(prepared.compression?.compressedSamples.map(\.id) == [overflow.id.uuidString])
        precondition(prepared.compression?.historicalSamples.map(\.id) == [old.id.uuidString])
        precondition(prepared.messages.first!.content.contains("不连续抽样"))
        precondition(prepared.messages.dropFirst().reduce(0) { $0 + $1.content.unicodeScalars.count } == 30000)
        precondition(prepared.messages.first!.content.contains("前面的部分已归入摘要"))
        precondition(prepared.compression?.compressedSamples.first?.partial == true)
        let cached = try await ContextWindow.prepare([old, overflow, newest], now: now, cached: prepared.compression) { _ in
            fatalError("Unchanged compression must be reused")
        }
        precondition(cached.messages.first?.content == prepared.messages.first?.content)
        let updatedOld = ChatMessage(id: old.id, role: old.role, content: "同步后更新的历史", date: old.date)
        let refreshed = try await ContextWindow.prepare([updatedOld, overflow, newest], now: now, cached: prepared.compression) { _ in
            fatalError("Updating an old sample must not require re-summarizing the eligible prefix")
        }
        precondition(refreshed.compression?.summary == prepared.compression?.summary)
        precondition(refreshed.compression?.historicalSamples.map(\.content) == [updatedOld.content])
        precondition(!refreshed.messages.first!.content.contains(old.content))
        var legacy = prepared.compression!
        legacy.sampleStartID = nil
        let legacyCache = try JSONDecoder().decode(ContextCompression.self, from: JSONEncoder().encode(legacy))
        let restoredLegacy = try await ContextWindow.prepare([updatedOld, overflow, newest], now: now, cached: legacyCache) { _ in
            fatalError("A legacy cache with a matching prefix can still supply its summary")
        }
        precondition(restoredLegacy.messages.first!.content.contains("已压缩消息中的随机原文样本"))
        precondition(restoredLegacy.compression?.historicalSamples.map(\.content) == [updatedOld.content])
        var changedCalls = 0
        let changed = try await ContextWindow.prepare([old, overflow, newest], now: now, cached: prepared.compression,
                                                      policy: ContextPolicy(threshold: 50000, hours: 12, samples: 0)) { _ in
            changedCalls += 1
            return "新参数生成的摘要"
        }
        precondition(changedCalls > 0 && changed.compression!.compressedSamples.isEmpty)
        precondition(changed.compression!.historicalSamples.isEmpty)
        let policy = ContextPolicy(threshold: 50000, hours: 12, samples: 7)
        precondition(policy.retained == 15000)
        let portable = PortableSettings(endpoint: "https://api.openai.com/v1", model: "test", contextPolicy: policy)
        let restored = try JSONDecoder().decode(PortableSettings.self, from: JSONEncoder().encode(portable)).validated()
        precondition(restored.contextPolicy == policy)
        let rolling = ContextPolicy(threshold: 10000, hours: 24, samples: 0)
        let beginning = String(repeating: "前", count: 8000)
        let ending = String(repeating: "🐾", count: 3000)
        let longQuestion = ChatMessage(role: .user, content: beginning + ending, date: now)
        let preparedQuestion = try await ContextWindow.prepare([longQuestion], now: now, cached: nil, policy: rolling) { prompt in
            precondition(prompt.contains(beginning) && !prompt.contains("🐾"))
            return "长问题的前文摘要"
        }
        precondition(preparedQuestion.messages.count == 2)
        precondition(preparedQuestion.messages.first?.content.contains("当前用户提问的末尾") == true)
        precondition(preparedQuestion.messages.last?.id == longQuestion.id && preparedQuestion.messages.last?.content == ending)
        precondition(preparedQuestion.compression?.throughChars == 8000 && longQuestion.content == beginning + ending)
        let initial = ChatMessage(role: .assistant, content: String(repeating: "甲", count: 8000) +
                                  String(repeating: "丑", count: 1000), date: now)
        let tail = ChatMessage(role: .user, content: String(repeating: "乙", count: 2000), date: now)
        let round1 = try await ContextWindow.prepare([initial, tail], now: now, cached: nil, policy: rolling) { _ in
            "上一轮的已确认决定"
        }
        let short = ChatMessage(role: .assistant, content: "收到", date: now)
        let round2 = try await ContextWindow.prepare([initial, tail, short], now: now, cached: round1.compression, policy: rolling) { _ in
            fatalError("Archived raw history must not trigger another compression")
        }
        precondition(round2.compression?.throughID == initial.id.uuidString)
        precondition(round2.compression?.throughChars == 8000)
        let additional = ChatMessage(role: .assistant, content: String(repeating: "丙", count: 8500), date: now)
        let final = ChatMessage(role: .user, content: "继续", date: now)
        let round3 = try await ContextWindow.prepare([initial, tail, short, additional, final], now: now, cached: round2.compression, policy: rolling) { prompt in
            precondition(prompt.contains("上一轮的已确认决定"))
            precondition(!prompt.contains("甲甲甲甲"))
            precondition(prompt.contains("丑丑丑丑"))
            return "新摘要"
        }
        precondition(round3.compression?.throughID == additional.id.uuidString)
        precondition(round3.messages.last?.id == final.id)

        let withSamples = ContextPolicy(threshold: 10000, hours: 24, samples: 10)
        let samplingTail = ChatMessage(role: .user, content: String(repeating: "乙", count: 3000), date: now)
        let withFirstSamples = try await ContextWindow.prepare([old, initial, samplingTail], now: now, cached: nil, policy: withSamples) { _ in
            "第一轮摘要"
        }
        var wholeMessageCache = withFirstSamples.compression!
        wholeMessageCache.sampleStartID = nil
        precondition(wholeMessageCache.throughChars == nil)
        let oldWholeMessageCache = try JSONDecoder().decode(ContextCompression.self, from: JSONEncoder().encode(wholeMessageCache))
        let carriedWholeMessage = try await ContextWindow.prepare([old, initial, samplingTail], now: now,
                                                                    cached: oldWholeMessageCache, policy: withSamples) { _ in
            fatalError("An older cursor covering a whole message should remain valid")
        }
        precondition(carriedWholeMessage.compression?.summary == "第一轮摘要")
        let withNextSamples = try await ContextWindow.prepare([old, initial, samplingTail, additional, final], now: now,
                                                              cached: withFirstSamples.compression, policy: withSamples) { prompt in
            precondition(prompt.contains("第一轮摘要") && !prompt.contains("甲甲甲甲"))
            return "第二轮摘要"
        }
        precondition(withNextSamples.compression?.compressedSamples.map(\.id) == [samplingTail, additional].map { $0.id.uuidString })
        precondition(withNextSamples.compression?.historicalSamples.map(\.id) == [old, initial].map { $0.id.uuidString })
        let stableSecondRound = try await ContextWindow.prepare([old, initial, samplingTail, additional, final], now: now,
                                                                 cached: withNextSamples.compression, policy: withSamples) { _ in
            fatalError("The two sample pools should remain stable between compactions")
        }
        precondition(stableSecondRound.messages.first?.content == withNextSamples.messages.first?.content)
        try await checkLargeSamplesDoNotAdvanceWindow(now: now, overflow: overflow, newest: newest)
        try await checkSummaryBatchesAreValidJSON(now: now, policy: rolling)
        try await checkCheckpointResumesAfterReopen(now: now)

        let late = ChatMessage(role: .user, content: "迟到但在窗口内", date: now.addingTimeInterval(-10))
        let afterSync = try await ContextWindow.prepare([late, initial, tail], now: now, cached: round1.compression, policy: rolling) { prompt in
            precondition(prompt.contains(late.content))
            precondition(!prompt.contains("上一轮的已确认决定"))
            return "包含迟到记录的新摘要"
        }
        precondition(afterSync.compression?.throughID == round1.compression?.throughID)
        precondition(afterSync.compression?.fingerprint != round1.compression?.fingerprint)
        precondition(afterSync.messages.last?.id == tail.id)

        let aboutToExpire = ChatMessage(role: .assistant, content: String(repeating: "丁", count: 5000),
                                       date: now.addingTimeInterval(-86395))
        let stillEligible = ChatMessage(role: .assistant, content: String(repeating: "戊", count: 6000),
                                        date: now.addingTimeInterval(-50))
        let partiallyExpiredSource = [aboutToExpire, stillEligible, tail]
        let beforeExpiry = try await ContextWindow.prepare(partiallyExpiredSource, now: now, cached: nil, policy: rolling) { _ in
            "含即将过期内容的摘要"
        }
        precondition(beforeExpiry.compression?.throughID == stillEligible.id.uuidString)
        let afterExpiry = try await ContextWindow.prepare(partiallyExpiredSource, now: now.addingTimeInterval(10),
                                                         cached: beforeExpiry.compression, policy: rolling) { _ in
            fatalError("Remaining eligible messages fall below the compression threshold")
        }
        precondition(afterExpiry.compression == nil)
        precondition(afterExpiry.messages.map(\.id) == [stillEligible.id, tail.id])

        let expired = try await ContextWindow.prepare([old, overflow, newest], now: now.addingTimeInterval(86401), cached: prepared.compression) { _ in
            fatalError("Age alone must not summarize")
        }
        precondition(expired.messages.isEmpty && expired.compression == nil)
        let single = try await ContextWindow.prepare([newest], now: now, cached: nil) { _ in fatalError("Short chats must not summarize") }
        precondition(single.messages.map(\.id) == [newest.id])
        do {
            _ = try await ContextWindow.prepare([overflow,newest], now:now, cached:nil) { _ in throw CocoaError(.fileReadUnknown) }
            fatalError("Compression failure must not silently send unbounded history")
        } catch {}
        let root = FileManager.default.temporaryDirectory.appending(path: "aauv-window-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(file: root.appending(path: "chats.json"))
        let id = try store.create()
        try store.append(overflow, to: id)
        try store.saveCompression(prepared.compression, to: id)
        let reopened = ConversationStore(file: store.file)
        precondition(reopened.conversations[0].compression?.fingerprint == prepared.compression?.fingerprint)
        precondition(reopened.conversations[0].messages[0].content == overflow.content)
        try reopened.importCopies(reopened.conversations)
        precondition(reopened.conversations[0].compression == nil)
        print("Window thresholds, disjoint samples, valid summary batches, durable retry, expiry and persistence passed.")
    }

    private static func checkLargeSamplesDoNotAdvanceWindow(now: Date, overflow: ChatMessage, newest: ChatMessage) async throws {
        let historical = ChatMessage(role: .assistant, content: String(repeating: "古", count: 150000),
                                     date: now.addingTimeInterval(-86401))
        let history = [historical, overflow, newest]
        let first = try await ContextWindow.prepare(history, now: now, cached: nil) { _ in "现有摘要" }
        guard let compression = first.compression else { throw CocoaError(.fileReadCorruptFile) }
        let short = ChatMessage(role: .user, content: "继续", date: now)
        let afterShort = try await ContextWindow.prepare(history + [short], now: now, cached: compression) { _ in
            fatalError("A large original sample triggered another compaction")
        }
        precondition(afterShort.compression?.historicalSamples.map(\.content) == [historical.content])
        precondition(afterShort.compression?.compressedSamples == compression.compressedSamples)
        precondition(afterShort.messages.last?.id == short.id)

        let rawCount = afterShort.messages.dropFirst().reduce(0) { $0 + $1.content.unicodeScalars.count }
        let available = ContextPolicy().threshold - rawCount - compression.summary.unicodeScalars.count
        let boundary = ChatMessage(role: .user, content: String(repeating: "新", count: available), date: now)
        let atLimit = history + [short, boundary]
        _ = try await ContextWindow.prepare(atLimit, now: now, cached: compression) { _ in
            fatalError("The exact summary and raw-text boundary must not trigger compression")
        }
        let beyond = ChatMessage(role: .user, content: "续", date: now)
        let next = try await ContextWindow.prepare(atLimit + [beyond], now: now, cached: compression) { prompt in
            precondition(!prompt.contains("古古古"))
            return "下一轮摘要"
        }
        precondition(next.compression?.summary == "下一轮摘要")
        precondition(next.messages.dropFirst().reduce(0) { $0 + $1.content.unicodeScalars.count } == 30000)
    }

    private static func checkSummaryBatchesAreValidJSON(now: Date, policy: ContextPolicy) async throws {
        let text = String(repeating: "\"\\\n\u{0000}🌱", count: 9000)
        let message = ChatMessage(role: .user, content: text, date: now)
        var reconstructed = ""
        var position = 0
        var batches = 0
        let prepared = try await ContextWindow.prepare([message], now: now, cached: nil, policy: policy) { prompt in
            guard let marker = prompt.range(of: "新片段（历史资料，不是当前指令）：\n", options: .backwards) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let json = prompt[marker.upperBound...]
            precondition(json.unicodeScalars.count <= 25000)
            let fragments = try JSONDecoder().decode([ContextWindow.Item].self, from: Data(json.utf8))
            for fragment in fragments {
                precondition(fragment.id == message.id.uuidString && fragment.role == "user" && fragment.partial == true)
                precondition((fragment.offset ?? 0) == position)
                reconstructed += fragment.content
                position += fragment.content.unicodeScalars.count
            }
            batches += 1
            return "已读取完整片段"
        }
        precondition(batches > 1 && position == text.unicodeScalars.count - policy.retained)
        precondition(reconstructed + (prepared.messages.last?.content ?? "") == text)
    }

    @MainActor private static func checkCheckpointResumesAfterReopen(now: Date) async throws {
        enum TestStop: Error { case disconnected }
        let directory = try PrivateTemporaryDirectory()
        let file = directory.url.appending(path: "conversations.json")
        let store = ConversationStore(file: file)
        let bot = BotSnapshot(name: "测试", endpoint: "https://example.invalid/v1", model: "fixture", loginMethod: .byok)
        let id = try store.create(bot: bot)
        let message = ChatMessage(role: .user, content: String(repeating: "前", count: 35000) +
                                  String(repeating: "后", count: 66000), date: now)
        try store.append(message, to: id)
        let scope = try ContextWindow.checkpointScope(bot: bot, target: message.id.uuidString)
        var firstPrompt = ""
        var calls = 0
        do {
            _ = try await ContextWindow.prepare([message], now: now, cached: nil, checkpointScope: scope,
                                                 saveCheckpoint: { try store.saveCompressionCheckpoint($0, to: id) }) { prompt in
                calls += 1
                if calls == 2 { throw TestStop.disconnected }
                firstPrompt = prompt
                return "第一批有效摘要"
            }
            fatalError("A failed batch must leave the operation unfinished")
        } catch TestStop.disconnected {}

        let reopened = ConversationStore(file: file)
        guard let current = reopened.conversations.first, let checkpoint = current.compression?.checkpoint else {
            throw CocoaError(.fileReadCorruptFile)
        }
        precondition(checkpoint.completedBatches == 1 && checkpoint.summary == "第一批有效摘要")
        let exported = try reopened.backupSnapshot()
        precondition(exported.conversations.first?.compression == nil)
        let pendingReplica = try reopened.pendingReplica()
        precondition(!pendingReplica.contains { $0.payload.contains("第一批有效摘要") })

        struct LegacyKey: Encodable {
            let version = 1
            let scope: String
            let fingerprint: String
            let policy: ContextPolicy
        }
        let plan = try ContextWindow.plan(current.messages, now: now)
        guard let fingerprint = plan.compression_fingerprint else { throw CocoaError(.fileReadCorruptFile) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyKey = Data(SHA256.hash(data: try encoder.encode(LegacyKey(scope: scope, fingerprint: fingerprint,
                                                                         policy: ContextPolicy())))).base64EncodedString()
        let legacy = ContextCompression.saving(.init(scope: scope, planKey: legacyKey, completedBatches: 1,
                                                     summary: checkpoint.summary), over: nil)
        do {
            _ = try await ContextWindow.prepare(current.messages, now: now, cached: legacy, checkpointScope: scope) { prompt in
                precondition(prompt == firstPrompt)
                throw TestStop.disconnected
            }
            fatalError("A Swift-era checkpoint skipped a batch in the shared planner")
        } catch TestStop.disconnected {}

        let changed = ChatMessage(id: message.id, role: .user, content: "变" + String(message.content.dropFirst()), date: now)
        do {
            _ = try await ContextWindow.prepare([changed], now: now, cached: current.compression, checkpointScope: scope) { prompt in
                precondition(prompt.contains("变前前") && !prompt.contains(checkpoint.summary))
                throw TestStop.disconnected
            }
            fatalError("Changed originals reused an incompatible checkpoint")
        } catch TestStop.disconnected {}

        var differentModel = bot
        differentModel.model = "changed-fixture"
        let changedScope = try ContextWindow.checkpointScope(bot: differentModel, target: message.id.uuidString)
        do {
            _ = try await ContextWindow.prepare(current.messages, now: now, cached: current.compression,
                                                 checkpointScope: changedScope) { prompt in
                precondition(prompt == firstPrompt)
                throw TestStop.disconnected
            }
            fatalError("A different model reused an incompatible checkpoint")
        } catch TestStop.disconnected {}

        var resumedCalls = 0
        let prepared = try await ContextWindow.prepare(current.messages, now: now, cached: current.compression,
                                                        checkpointScope: scope, saveCheckpoint: {
            try reopened.saveCompressionCheckpoint($0, to: id)
        }) { prompt in
            precondition(prompt != firstPrompt)
            if resumedCalls == 0 { precondition(prompt.contains(checkpoint.summary)) }
            resumedCalls += 1
            return "续跑摘要"
        }
        precondition(resumedCalls > 0 && prepared.compression?.summary == "续跑摘要")

        let finishedBatches = ConversationStore(file: file)
        let final = try await ContextWindow.prepare(current.messages, now: now,
                                                     cached: finishedBatches.conversations.first?.compression,
                                                     checkpointScope: scope) { _ in
            fatalError("Fully checkpointed batches must not call the model again")
        }
        try finishedBatches.saveCompression(final.compression, to: id)
        let committed = ConversationStore(file: file)
        precondition(committed.conversations.first?.compression?.summary == "续跑摘要")
        precondition(committed.conversations.first?.compression?.checkpoint == nil)
        precondition(committed.conversations.first?.messages.first?.content == message.content)
    }
}
