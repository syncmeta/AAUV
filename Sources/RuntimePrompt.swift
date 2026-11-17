import AAUVCore
import Foundation

// Model-only copies preserve the stored text and the context-window character
// budget. Generated summary packets are not presented as user-authored turns.
struct RuntimePrompt {
    let instructions: String
    private let name: String
    private let now: Date
    private let timeZone: TimeZone

    init(botName: String, now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) throws {
        self.name = botName
        self.now = now
        self.timeZone = timeZone
        instructions = try Self.render(botName: botName, now: now, timeZone: timeZone, messages: []).instructions
    }

    func messages(_ messages: [ChatMessage], originals: [ChatMessage]) throws -> [ChatMessage] {
        let originalIDs = Set(originals.map(\.id))
        let input = messages.map { message in
            Item(id: message.id.uuidString, role: message.role.rawValue, content: message.content,
                 time: message.date?.timeIntervalSince1970, original: originalIDs.contains(message.id))
        }
        let rendered = try Self.render(botName: name, now: now, timeZone: timeZone, messages: input).messages
        guard rendered.count == messages.count else { throw Self.invalidResult }
        return try zip(messages, rendered).map { source, item in
            guard item.id == source.id.uuidString, item.role == source.role.rawValue else { throw Self.invalidResult }
            return ChatMessage(id: source.id, role: source.role, content: item.content, date: source.date,
                               attachments: source.attachments, unavailableAttachments: source.unavailableAttachments,
                               citations: source.citations, replyTo: source.replyTo, isAlternative: source.isAlternative,
                               selectedReplyID: source.selectedReplyID, localToolTrace: source.localToolTrace)
        }
    }

    private struct Item: Codable {
        let id: String
        let role: String
        let content: String
        let time: Double?
        let original: Bool
    }

    private struct Input: Encodable {
        let botName: String
        let timeZone: String
        let offsetSeconds: Int
        let now: Double
        let messages: [Item]
    }

    private struct Output: Decodable {
        let instructions: String
        let messages: [Item]
    }

    private static var invalidResult: ChatClient.ClientError {
        .message(String(localized: "无法准备会话的时间信息，请重试。"))
    }

    private static func render(botName: String, now: Date, timeZone: TimeZone, messages: [Item]) throws -> Output {
        let input = Input(botName: botName, timeZone: timeZone.identifier,
                          offsetSeconds: timeZone.secondsFromGMT(for: now), now: now.timeIntervalSince1970,
                          messages: messages)
        let data = try JSONEncoder().encode(input)
        var error: NSError?
        let output = AauvcoreRenderRuntimeContext(String(decoding: data, as: UTF8.self), &error)
        if let error { throw error }
        guard let result = try? JSONDecoder().decode(Output.self, from: Data(output.utf8)) else { throw invalidResult }
        return result
    }
}
