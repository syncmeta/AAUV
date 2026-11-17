import Foundation
import AAUVCore
import CryptoKit

struct ContextPolicy: Codable, Equatable, Sendable {
    var threshold = 100000
    var hours = 24
    var samples = 10
    var retained: Int { threshold * 3 / 10 }

    func validated() throws -> Self {
        guard (10000...200000).contains(threshold), (1...168).contains(hours),
              (0...50).contains(samples) else {
            throw ChatClient.ClientError.message("上下文设置超出范围。")
        }
        return self
    }
    static func load() -> Self {
        let defaults = UserDefaults.standard
        let candidate = Self(threshold: defaults.object(forKey: "contextThreshold") as? Int ?? 100000,
                             hours: defaults.object(forKey: "contextHours") as? Int ?? 24,
                             samples: defaults.object(forKey: "contextSamples") as? Int ?? 10)
        return (try? candidate.validated()) ?? Self()
    }
    func save() {
        UserDefaults.standard.set(threshold, forKey: "contextThreshold")
        UserDefaults.standard.set(hours, forKey: "contextHours")
        UserDefaults.standard.set(samples, forKey: "contextSamples")
    }
}

struct ContextCompression: Codable {
    struct Checkpoint: Codable, Sendable {
        let scope: String
        let planKey: String
        let completedBatches: Int
        let summary: String
    }

    let fingerprint: String
    let summary: String
    let compressedSamples: [ContextWindow.Item]
    var historicalSamples: [ContextWindow.Item]
    var throughID: String?
    var throughChars: Int?
    var policy: ContextPolicy?
    var sampleStartID: String?
    var checkpoint: Checkpoint?

    func finalized() -> Self? {
        guard !fingerprint.isEmpty else { return nil }
        var copy = self
        copy.checkpoint = nil
        return copy
    }

    static func saving(_ checkpoint: Checkpoint, over previous: Self?) -> Self {
        var copy = previous ?? Self(fingerprint: "", summary: "", compressedSamples: [], historicalSamples: [])
        copy.checkpoint = checkpoint
        return copy
    }
}

enum ContextWindow {
    struct Item: Codable, Equatable {
        let id: String
        let role: String
        let content: String
        let time: Double?
        let partial: Bool?
        let offset: Int?

        init(_ message: ChatMessage) {
            id = message.id.uuidString
            role = message.role.rawValue
            content = message.content
            time = message.date?.timeIntervalSince1970
            partial = nil
            offset = nil
        }

        var message: ChatMessage {
            ChatMessage(id: UUID(uuidString: id)!, role: ChatMessage.Role(rawValue: role)!,
                        content: content, date: time.map { Date(timeIntervalSince1970: $0) })
        }
    }
    struct Plan: Decodable {
        let recent: [Item]
        let overflow: [Item]
        let earlier: [Item]
        let compressed: [Item]
        let compression_fingerprint: String?
        let through_chars: Int?
        let uses_carry: Bool
        let needs_compression: Bool
    }
    private struct Input: Encodable {
        let now: Double
        let messages: [Item]
        let threshold: Int
        let hours: Int
        let compressed_through: String?
        let through_chars: Int?
        let carry_fingerprint: String?
        let carry_chars: Int
    }
    struct Prepared {
        let messages: [ChatMessage]
        let compression: ContextCompression?
    }

    @MainActor static func checkpointScope(bot: BotSnapshot, target: String) throws -> String {
        let copilotRevision = bot.loginMethod == .copilot
            ? UserDefaults.standard.string(forKey: APIKey.copilotRevisionKey) ?? "" : ""
        let fields = [target, bot.loginMethod.rawValue, bot.endpoint, bot.model, bot.apiProtocol ?? "",
                      bot.chatGPTClientID ?? "", copilotRevision]
        return digest(try JSONEncoder().encode(fields))
    }

    static func plan(_ messages: [ChatMessage], now: Date, policy: ContextPolicy = .init(), throughID: String? = nil,
                     throughChars: Int? = nil, carryFingerprint: String? = nil, carryChars: Int = 0) throws -> Plan {
        _ = try policy.validated()
        let input = try JSONEncoder().encode(Input(now: now.timeIntervalSince1970, messages: messages.map(Item.init),
                                                   threshold: policy.threshold, hours: policy.hours, compressed_through: throughID,
                                                   through_chars: throughChars, carry_fingerprint: carryFingerprint,
                                                   carry_chars: carryChars))
        var error: NSError?
        let json = AauvcorePlanWindow(String(decoding: input, as: UTF8.self), &error)
        if let error { throw error }
        return try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
    }

    static func sample(_ items: [Item], count: Int) throws -> [Item] {
        if count == 0 { return [] }
        let input = try JSONEncoder().encode(items)
        var error: NSError?
        let json = AauvcoreSampleMessagesCount(String(decoding: input, as: UTF8.self), count, &error)
        if let error { throw error }
        return try JSONDecoder().decode([Item].self, from: Data(json.utf8))
    }

    static func prepare(
        _ messages: [ChatMessage], now: Date, cached: ContextCompression?, policy: ContextPolicy = .init(),
        checkpointScope: String? = nil, saveCheckpoint: (@MainActor (ContextCompression.Checkpoint) throws -> Void)? = nil,
        summarize: (String) async throws -> String
    ) async throws -> Prepared {
        var candidate = cached?.finalized().flatMap { $0.policy == policy && $0.fingerprint.hasPrefix("window2:") ? $0 : nil }
        // Samples are supplementary evidence. Their random lengths must not
        // advance the compression threshold for the active history.
        let plan = try Self.plan(messages, now: now, policy: policy, throughID: candidate?.throughID,
                                 throughChars: candidate?.throughChars, carryFingerprint: candidate?.fingerprint,
                                 carryChars: candidate?.summary.unicodeScalars.count ?? 0)
        if plan.uses_carry, var previous = candidate, policy.samples > 0 {
            let start = previous.sampleStartID ?? plan.compressed.first?.id
            let historical = historicalSource(messages, plan: plan, before: start)
            let current = Dictionary(uniqueKeysWithValues: historical.map { ($0.id, $0) })
            if previous.historicalSamples.count != min(policy.samples, historical.count) ||
                previous.historicalSamples.contains(where: { current[$0.id] != $0 }) {
                previous.historicalSamples = try sample(historical, count: policy.samples)
            }
            candidate = previous
        }
        let prior = plan.uses_carry ? candidate : nil
        let compression: ContextCompression
        if !plan.needs_compression {
            guard let prior else { return Prepared(messages: plan.recent.map(\.message), compression: nil) }
            compression = prior
        } else {
            guard let fingerprint = plan.compression_fingerprint, let start = plan.overflow.first?.id else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let (batches, batchFingerprint) = try summaryBatches(plan.overflow)
            let planKey = try checkpointScope.map { scope in
                try checkpointKey(scope: scope, fingerprint: fingerprint, batchFingerprint: batchFingerprint,
                                  previous: prior, policy: policy)
            }
            var summary = prior?.summary ?? ""
            var first = 0
            if let checkpoint = cached?.checkpoint, checkpoint.planKey == planKey, checkpoint.scope == checkpointScope,
               checkpoint.completedBatches > 0, checkpoint.completedBatches <= batches.count,
               AauvcoreIsWindowSummaryValid(checkpoint.summary) {
                first = checkpoint.completedBatches
                summary = checkpoint.summary
            }
            for index in first..<batches.count {
                try Task.checkCancellation()
                summary = try await summarize(AauvcoreBuildWindowSummaryPrompt(summary, batches[index]))
                guard AauvcoreIsWindowSummaryValid(summary) else {
                    throw ChatClient.ClientError.message("历史压缩未返回有效的短摘要，请重试。原始消息仍保留。")
                }
                if let checkpointScope, let planKey, let saveCheckpoint {
                    try await saveCheckpoint(.init(scope: checkpointScope, planKey: planKey,
                                                   completedBatches: index + 1, summary: summary))
                }
            }
            try Task.checkCancellation()
            let historical = policy.samples == 0 ? [] : historicalSource(messages, plan: plan, before: start)
            compression = ContextCompression(
                fingerprint: fingerprint, summary: summary,
                compressedSamples: try sample(plan.overflow, count: policy.samples),
                historicalSamples: try sample(historical, count: policy.samples),
                throughID: plan.overflow.last?.id, throughChars: plan.through_chars, policy: policy, sampleStartID: start
            )
        }
        let packet = try context(for: compression, samples: policy.samples, recent: plan.recent)
        var output = [ChatMessage(role: .user, content: packet, date: now)] + plan.recent.map(\.message)
        if plan.recent.isEmpty {
            output.append(ChatMessage(role: .user, content: "当前窗口内的原文已纳入上述压缩资料。请根据摘要中保留的最后用户请求继续回答；信息不足时请明确指出。", date: now))
        }
        return Prepared(messages: output, compression: compression)
    }

    private static func checkpointKey(scope: String, fingerprint: String, batchFingerprint: String, previous: ContextCompression?,
                                      policy: ContextPolicy) throws -> String {
        struct Key: Encodable {
            let version = 2
            let scope: String
            let fingerprint: String
            let batchFingerprint: String
            let previousFingerprint: String?
            let previousSummary: String?
            let policy: ContextPolicy
        }
        let key = Key(scope: scope, fingerprint: fingerprint, batchFingerprint: batchFingerprint, previousFingerprint: previous?.fingerprint,
                      previousSummary: previous?.summary, policy: policy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(key))
    }

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func historicalSource(_ messages: [ChatMessage], plan: Plan, before start: String?) -> [Item] {
        var ids = Set(plan.earlier.map(\.id))
        if let start, let index = plan.compressed.firstIndex(where: { $0.id == start }) {
            ids.formUnion(plan.compressed[..<index].map(\.id))
        }
        return messages.compactMap { message in
            ids.contains(message.id.uuidString) ? Item(message) : nil
        }
    }

    private static func summaryBatches(_ items: [Item]) throws -> ([String], String) {
        let input = try JSONEncoder().encode(items)
        var error: NSError?
        let encoded = AauvcorePlanWindowSummaryBatches(String(decoding: input, as: UTF8.self), &error)
        if let error { throw error }
        let bytes = Data(encoded.utf8)
        return (try JSONDecoder().decode([String].self, from: bytes), digest(bytes))
    }

    private static func context(for compression: ContextCompression, samples: Int, recent: [Item]) throws -> String {
        struct Packet: Encodable {
            let summary: String
            let compressedSamples: [Item]
            let historicalSamples: [Item]
            let sampleLimit: Int
            let roundScoped: Bool
            let firstOffset: Int
            let currentPromptTail: Bool
        }
        let packet = Packet(summary: compression.summary, compressedSamples: compression.compressedSamples,
                            historicalSamples: compression.historicalSamples, sampleLimit: samples,
                            roundScoped: compression.sampleStartID != nil, firstOffset: recent.first?.offset ?? 0,
                            currentPromptTail: recent.count == 1 && recent.first?.role == "user")
        let input = try JSONEncoder().encode(packet)
        var error: NSError?
        let result = AauvcoreBuildCompressedWindowContext(String(decoding: input, as: UTF8.self), &error)
        if let error { throw error }
        return result
    }
}
