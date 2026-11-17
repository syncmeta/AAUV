import Foundation

struct UsageCounts: Decodable {
    let input: Int64
    let output: Int64

    private enum CodingKeys: String, CodingKey {
        case input_tokens, output_tokens, prompt_tokens, completion_tokens
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        input = try fields.decodeIfPresent(Int64.self, forKey: .input_tokens)
            ?? fields.decode(Int64.self, forKey: .prompt_tokens)
        output = try fields.decodeIfPresent(Int64.self, forKey: .output_tokens)
            ?? fields.decode(Int64.self, forKey: .completion_tokens)
        guard (0...1_000_000_000).contains(input), (0...1_000_000_000).contains(output) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

struct ModelUsage: Decodable, Identifiable {
    enum Purpose: String, Decodable {
        case reply, compression, title
    }

    let provider: LoginMethod
    let model: String
    let purpose: Purpose
    let requests: Int64
    let input: Int64
    let output: Int64

    var id: String { [provider.rawValue, model, purpose.rawValue].joined(separator: "\u{0}") }
}

extension ConversationStore {
    func recordUsage(_ counts: UsageCounts, provider: LoginMethod, model: String, purpose: ModelUsage.Purpose) throws {
        try requireDatabase().recordUsage(provider.rawValue, model: model, purpose: purpose.rawValue,
                                          input: counts.input, output: counts.output)
    }

    func readUsage() throws -> [ModelUsage] {
        var error: NSError?
        let value = try requireDatabase().usage(&error)
        if let error { throw error }
        return try JSONDecoder().decode([ModelUsage].self, from: Data(value.utf8))
    }
}
