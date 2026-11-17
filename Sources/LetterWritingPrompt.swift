import Foundation

/// Legacy user-entered drafting format retained for reading/migrating old records.
/// New manual generation uses LetterGeneration without a requirements form.
enum LetterWritingPrompt {
    enum Failure: LocalizedError {
        case emptyRequirements

        var errorDescription: String? {
            String(localized: "请输入写信要求。")
        }
    }

    static func makeRequest(requirements: String) throws -> String {
        let requirements = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirements.isEmpty else { throw Failure.emptyRequirements }
        return legacyPreamble + requirements
    }

    // Exact full prefix emitted by r11–r13. Never infer purpose from a title.
    static let legacyPreamble = """
    请根据下面的用户要求起草一封信。按用户指定的语言、收信人、语气和长度写作；未指定语言时，使用用户要求所用的语言。
    只输出信件正文，可包含合适的称呼和落款。不要添加给用户的解释、额外标题或代码块。
    这是一份供用户阅读、保存或导出的草稿。不要声称信件已经寄出、发送或交付，也不要替用户联系收信人。如果要求中提到发送，仍只起草正文供用户自行处理。

    用户的写信要求：
    """ + "\n"

    static func isLegacyRequest(_ text: String) -> Bool {
        text.hasPrefix(legacyPreamble) && !text.dropFirst(legacyPreamble.count)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func displayedRequirements(_ text: String) -> String {
        isLegacyRequest(text) ? String(text.dropFirst(legacyPreamble.count)) : text
    }

    static func conversationTitle(botName: String) -> String {
        let name = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? String(localized: "写信") : String(localized: "写信") + " · " + name
        return String(title.prefix(80))
    }
}
