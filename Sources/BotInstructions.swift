import Foundation

struct BotSkill: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var markdown = ""
    var enabled = false
}

struct BotInstructions: Codable, Equatable, Sendable {
    static let byteLimit = 512 * 1024
    static let skillLimit = 100
    static let aauvConversationStyle = """
    你正在大绿豆（AAUV）里与用户交流。用平等、直接、自然的方式对话。优先回应当前话题，简短的问题简短答，复杂内容可以用 Markdown 分段。

    独立判断对话里的说法。区分已知事实和推测，有理由时坦率地提出异议。需要核实的信息在有相应工具时查证，缺少依据时说明不确定之处。

    按照当前请求实际提供的能力处理文字和附件。信息不全时，说明具体缺少什么。仅在确实需要对方澄清时提问。

    跟随对方使用的语言。无法判断语言时用英语。
    """

    var prompt = ""
    var skills = ""
    var skillEntries: [BotSkill]?

    var requestInstructions: String {
        let namedSkills = (skillEntries ?? []).filter(\.enabled).map { "### \($0.name)\n\($0.markdown)" }
        return ([prompt, skills] + namedSkills).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    func validated() throws -> Self {
        let entries = skillEntries ?? []
        guard entries.count <= Self.skillLimit, Set(entries.map(\.id)).count == entries.count else {
            throw ChatClient.ClientError.message("每份提示词最多保存 100 个技能，且技能记录不能重复。")
        }
        var bytes = prompt.utf8.count + skills.utf8.count
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !entry.name.contains(where: \.isNewline), entry.name.utf8.count <= 240,
                  !entry.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatClient.ClientError.message("请为每个技能填写名称和 Markdown 正文，名称最多 240 字节。")
            }
            bytes += entry.name.utf8.count + entry.markdown.utf8.count
        }
        guard bytes <= Self.byteLimit else {
            throw ChatClient.ClientError.message("提示词和技能文本合计不能超过 512 KB。")
        }
        return self
    }
}

extension ConversationStore {
    private var instructionsFile: URL {
        file.deletingLastPathComponent().appending(path: "bot-instructions.json")
    }

    func readInstructions() throws -> BotInstructions {
        if let stored = try storedInstructions() { return stored }
        return try readLegacyInstructions() ?? BotInstructions()
    }

    func migrateInstructions() throws {
        if try storedInstructions() == nil, let legacy = try readLegacyInstructions(),
           legacy != BotInstructions() {
            let modified = try instructionsFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let date = min(modified ?? Date(), Date())
            let nanoseconds = Int64(max(1, date.timeIntervalSince1970 * 1_000_000_000))
            try requireDatabase().seedInstructions(Self.encodeInstructions(legacy), modified: nanoseconds)
        }
    }

    func saveInstructions(_ instructions: BotInstructions, expected: BotInstructions? = nil) throws {
        if let expected, try readInstructions() != expected {
            throw ChatClient.ClientError.message("提示词和技能已在另一设备更新。请重新打开设置查看最新内容。")
        }
        try requireDatabase().setInstructions(Self.encodeInstructions(instructions))
        onLocalChange?()
    }

    static func encodeInstructions(_ instructions: BotInstructions) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(instructions.validated()), as: UTF8.self)
    }

    private func storedInstructions() throws -> BotInstructions? {
        var error: NSError?
        let text = try requireDatabase().instructions(&error)
        if let error { throw error }
        if text.isEmpty { return nil }
        return try JSONDecoder().decode(BotInstructions.self, from: Data(text.utf8)).validated()
    }

    private func readLegacyInstructions() throws -> BotInstructions? {
        do {
            return try JSONDecoder().decode(BotInstructions.self, from: Data(contentsOf: instructionsFile)).validated()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
