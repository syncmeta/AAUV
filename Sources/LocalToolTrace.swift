import Foundation

/// Display-only, host-authored history attached to the triggering user message.
/// This type is never a model message or a source of tool arguments.
struct LocalToolTrace: Codable, Equatable, Sendable {
    static let maximumEntries = 64
    static let maximumBytes = 128 * 1024
    let version: Int
    let requestID: UUID
    // Opaque Core Lamport ordering; never minted by Swift or shown to a model.
    let runRevision: String
    var entries: [Entry]

    enum Function: String, Codable, CaseIterable, Sendable {
        case searchChatHistory = "search_chat_history"
        case createSkill = "create_skill"
        case readAttachment = "read_attachment"
        case sendImages = "send_images"
        case delegateToSpecialist = "delegate_to_specialist"
    }

    enum State: String, Codable, CaseIterable, Sendable {
        case running, succeeded, partial, failed, interrupted
    }

    enum Failure: String, Codable, CaseIterable, Sendable {
        case invalidInput = "invalid_input"
        case unavailable, timeout, limit
        case toolFailed = "tool_failed"
    }

    // Deliberately not Codable: an unconfirmed running record is a UI judgment,
    // not a new terminal claim written over the original observation.
    enum DisplayState: Equatable, Sendable {
        case running, succeeded, partial, failed, unconfirmed
    }

    // Input events have no ordering fields: Core assigns runRevision/sequence.
    struct Event: Encodable, Identifiable, Equatable, Sendable {
        let id: UUID
        var function: Function
        var state: State
        var query: String?
        var queryTruncated: Bool?
        var skillName: String?
        var quantity: Int?
        var failure: Failure?

        init(id: UUID, function: Function, state: State, query: String? = nil, queryTruncated: Bool? = nil,
             skillName: String? = nil, quantity: Int? = nil, failure: Failure? = nil) {
            self.id = id; self.function = function; self.state = state
            self.query = query; self.queryTruncated = queryTruncated; self.skillName = skillName
            self.quantity = quantity; self.failure = failure
        }

        func validated() throws -> Self {
            if let query {
                guard function == .searchChatHistory, LocalToolTrace.isSafeQuery(query) else { throw ValidationError.invalid }
            }
            if queryTruncated != nil {
                guard function == .searchChatHistory, query != nil else { throw ValidationError.invalid }
            }
            if let skillName {
                guard function == .createSkill, (1...80).contains(skillName.utf8.count),
                      skillName.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
                    throw ValidationError.invalid
                }
            }
            if let quantity {
                let maximum: Int
                switch function {
                case .searchChatHistory: maximum = 30
                case .sendImages: maximum = 5
                case .readAttachment, .delegateToSpecialist: maximum = 4 * 1024 * 1024
                case .createSkill: throw ValidationError.invalid
                }
                guard (0...maximum).contains(quantity) else { throw ValidationError.invalid }
            }
            if state == .running {
                guard quantity == nil, failure == nil else { throw ValidationError.invalid }
            }
            if state == .partial {
                guard function == .sendImages, let quantity, quantity > 0 else { throw ValidationError.invalid }
            }
            if failure != nil {
                guard state == .failed || state == .interrupted else { throw ValidationError.invalid }
            }
            return self
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, function, state, query, queryTruncated, skillName, quantity, failure
        }

        func encode(to encoder: Encoder) throws {
            _ = try validated()
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id.uuidString.lowercased(), forKey: .id)
            try values.encode(function, forKey: .function)
            try values.encode(state, forKey: .state)
            try values.encodeIfPresent(query, forKey: .query)
            try values.encodeIfPresent(queryTruncated, forKey: .queryTruncated)
            try values.encodeIfPresent(skillName, forKey: .skillName)
            try values.encodeIfPresent(quantity, forKey: .quantity)
            try values.encodeIfPresent(failure, forKey: .failure)
        }
    }

    // Persisted host history includes Core-owned ordering, never guessed by UI.
    struct Entry: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let sequence: Int
        var function: Function
        var state: State
        var query: String?
        var queryTruncated: Bool?
        var skillName: String?
        var quantity: Int?
        var failure: Failure?

        init(id: UUID, sequence: Int, function: Function, state: State, query: String? = nil, queryTruncated: Bool? = nil,
             skillName: String? = nil, quantity: Int? = nil, failure: Failure? = nil) {
            self.id = id; self.sequence = sequence; self.function = function; self.state = state
            self.query = query; self.queryTruncated = queryTruncated; self.skillName = skillName
            self.quantity = quantity; self.failure = failure
        }

        func validated() throws -> Self {
            guard (0...63).contains(sequence) else { throw ValidationError.invalid }
            _ = try Event(id: id, function: function, state: state, query: query, queryTruncated: queryTruncated,
                          skillName: skillName, quantity: quantity, failure: failure).validated()
            return self
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, sequence, function, state, query, queryTruncated, skillName, quantity, failure
        }

        init(from decoder: Decoder) throws {
            try LocalToolTrace.requireKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            sequence = try values.decode(Int.self, forKey: .sequence)
            function = try values.decode(Function.self, forKey: .function)
            state = try values.decode(State.self, forKey: .state)
            // Optional means omitted, never an explicit null in the wire format.
            query = try values.contains(.query) ? values.decode(String.self, forKey: .query) : nil
            queryTruncated = try values.contains(.queryTruncated) ? values.decode(Bool.self, forKey: .queryTruncated) : nil
            skillName = try values.contains(.skillName) ? values.decode(String.self, forKey: .skillName) : nil
            quantity = try values.contains(.quantity) ? values.decode(Int.self, forKey: .quantity) : nil
            failure = try values.contains(.failure) ? values.decode(Failure.self, forKey: .failure) : nil
            _ = try validated()
        }

        func encode(to encoder: Encoder) throws {
            _ = try validated()
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id.uuidString.lowercased(), forKey: .id)
            try values.encode(sequence, forKey: .sequence)
            try values.encode(function, forKey: .function)
            try values.encode(state, forKey: .state)
            try values.encodeIfPresent(query, forKey: .query)
            try values.encodeIfPresent(queryTruncated, forKey: .queryTruncated)
            try values.encodeIfPresent(skillName, forKey: .skillName)
            try values.encodeIfPresent(quantity, forKey: .quantity)
            try values.encodeIfPresent(failure, forKey: .failure)
        }
    }

    init(requestID: UUID, runRevision: String, entries: [Entry]) {
        version = 1; self.requestID = requestID; self.runRevision = runRevision; self.entries = entries
    }

    func validated() throws -> Self {
        guard version == 1, runRevision.utf8.count == 19,
              runRevision.utf8.allSatisfy({ (48...57).contains($0) }),
              let clock = Int64(runRevision), clock > 0,
              entries.count <= Self.maximumEntries,
              Set(entries.map(\.id)).count == entries.count else { throw ValidationError.invalid }
        for entry in entries { _ = try entry.validated() }
        return self
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ValidationError.invalid }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ValidationError.invalid }
        return data
    }

    func interruptingRunningEntries() -> Self {
        var copy = self
        for index in copy.entries.indices where copy.entries[index].state == .running {
            copy.entries[index].state = .interrupted
        }
        return copy
    }

    func displayState(for entry: Entry, activeRequestID: UUID?) -> DisplayState {
        switch entry.state {
        case .running: activeRequestID == requestID ? .running : .unconfirmed
        case .succeeded: .succeeded
        case .partial: .partial
        case .failed: .failed
        case .interrupted: .unconfirmed
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, requestID, runRevision, entries }

    init(from decoder: Decoder) throws {
        try Self.requireKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        runRevision = try values.decode(String.self, forKey: .runRevision)
        var valuesList = try values.nestedUnkeyedContainer(forKey: .entries)
        if let count = valuesList.count, count > Self.maximumEntries { throw ValidationError.invalid }
        var decoded: [Entry] = []
        while !valuesList.isAtEnd {
            guard decoded.count < Self.maximumEntries else { throw ValidationError.invalid }
            decoded.append(try valuesList.decode(Entry.self))
        }
        entries = decoded
        _ = try validated()
    }

    func encode(to encoder: Encoder) throws {
        _ = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(runRevision, forKey: .runRevision)
        try values.encode(entries, forKey: .entries)
    }

    enum ValidationError: Error { case invalid }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func requireKeys(_ decoder: Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: AnyKey.self)
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw ValidationError.invalid }
    }

    // Defense for accidentally constructed/untrusted UI values. Sanitization is
    // owned by the producer and Core; the view never repairs raw arguments.
    private static func isSafeQuery(_ query: String) -> Bool {
        guard !query.isEmpty, query.unicodeScalars.count <= 256,
              query == query.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) ||
                  (CharacterSet.whitespacesAndNewlines.contains($0) && $0 != " ") }),
              !query.contains("  ") else { return false }
        // Mirror Core's known-span detector, including its >=16 token bound.
        // Core trims after clipping. Do not impose a stricter token detector
        // that would make valid canonical stored chats unloadable.
        let wordEnd = #"(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"#
        let forbidden = [
            #"(?i)(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>"']+"#,
            #"(?i)(?<![A-Za-z0-9_])(?:authorization["']?\s*[:=]\s*["']?(?:(?:bearer|basic)\s+)?|(?:bearer|basic)\s*[:=]?\s+)[^\s,;"']+"#,
            #"(?i)(?<![A-Za-z0-9_])(?:access_token|refresh_token|client_secret|api[_-]?key|password)["']?\s*[:=]\s*["']?(?:(?:bearer|basic)\s+)?[^\s,;"']+"#,
            #"(?<![A-Za-z0-9_])(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})"# + wordEnd
        ]
        return !forbidden.contains { query.range(of: $0, options: .regularExpression) != nil }
    }
}
