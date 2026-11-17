import Foundation
import Network

protocol RealtimeVoiceTransport: Sendable {
    func close()
    func send(_ event: [String: Any]) async throws
    func receive() async throws -> RealtimeVoice.Event
    func configure(instructions: String, key: String) async throws
}

enum RealtimeVoice {
    static let defaultModel = "gpt-realtime"
    static let sampleRate = 24_000

    static func modelName(_ model: String) throws -> String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256, !value.contains(where: \.isNewline) else {
            throw ChatClient.ClientError.message("请输入有效的 Realtime 模型名称。")
        }
        return value
    }

    static func request(base: URL, model: String, key: String) throws -> URLRequest {
        let model = try modelName(model)
        guard !key.isEmpty, !key.contains(where: \.isNewline) else {
            throw ChatClient.ClientError.message("请填写此 Base URL 的 API Key。")
        }
        guard var url = URLComponents(url: base.appending(component: "realtime"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let endpoint = url.url else { throw URLError(.badURL) }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func update(instructions: String) -> [String: Any] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": sampleRate]
        return [
            "type": "session.update",
            "session": [
                "type": "realtime", "instructions": instructions,
                "output_modalities": ["audio"], "tools": VoiceToolPolicy.tools, "tool_choice": "auto",
                "audio": [
                    "input": [
                        "format": format,
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                        "turn_detection": ["type": "server_vad", "create_response": true, "interrupt_response": true]
                    ],
                    "output": ["format": format, "voice": "marin"]
                ]
            ] as [String: Any]
        ]
    }

    static func history(_ message: ChatMessage) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": message.role.rawValue,
                "content": [[
                    "type": message.role == .user ? "input_text" : "output_text",
                    "text": message.content
                ]]
            ] as [String: Any]
        ]
    }

    static func truncate(item: String, contentIndex: Int, frames: Int64) -> [String: Any] {
        [
            "type": "conversation.item.truncate", "item_id": item,
            "content_index": contentIndex, "audio_end_ms": max(0, frames) * 1_000 / Int64(sampleRate)
        ]
    }

    struct Event: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                let type: String?
                let transcript: String?
                let text: String?
            }
            let id: String
            let role: String?
            let type: String?
            let status: String?
            let name: String?
            let call_id: String?
            let arguments: String?
            let content: [Content]?

            var finalTranscript: String? {
                let text = (content ?? []).compactMap { part -> String? in
                    switch part.type {
                    case "output_audio": return part.transcript
                    case "output_text": return part.text
                    default: return nil
                    }
                }.joined()
                return text.isEmpty ? nil : text
            }
        }

        struct Response: Decodable {
            let id: String?
            let status: String
            let output: [Item]?
            let usage: UsageCounts?
            private enum CodingKeys: String, CodingKey { case id, status, output, usage }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decodeIfPresent(String.self, forKey: .id)
                status = try values.decode(String.self, forKey: .status)
                output = try values.decodeIfPresent([Item].self, forKey: .output)
                usage = try? values.decodeIfPresent(UsageCounts.self, forKey: .usage)
            }
        }

        struct Failure: Decodable {
            let message: String?
        }

        let type: String
        let item_id: String?
        let content_index: Int?
        let delta: String?
        let transcript: String?
        let item: Item?
        let response: Response?
        let error: Failure?

        func failure(redacting key: String) -> ChatClient.ClientError {
            var detail = error?.message ?? ""
            if !key.isEmpty { detail = detail.replacingOccurrences(of: key, with: "•••") }
            return .message(detail.isEmpty ? "Realtime 服务返回错误。" : "Realtime 服务返回错误。\n\(detail.prefix(500))")
        }
    }

    final class Connection: RealtimeVoiceTransport {
        private let session: URLSession
        private let socket: URLSessionWebSocketTask
        private let validateRoute: ProxyRouteCheck?

        init(request: URLRequest, proxy: ProxyConfiguration?, validateRoute: ProxyRouteCheck? = nil) {
            self.validateRoute = validateRoute
            session = ChatClient.session(proxy: proxy)
            socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 4 * 1024 * 1024
            socket.resume()
        }

        func close() {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        deinit { close() }

        func send(_ event: [String: Any]) async throws {
            let body = try JSONSerialization.data(withJSONObject: event)
            try await validateRoute?()
            try await socket.send(.string(String(decoding: body, as: UTF8.self)))
        }

        func receive() async throws -> Event {
            let body: Data
            switch try await socket.receive() {
            case .data(let data): body = data
            case .string(let text): body = Data(text.utf8)
            @unknown default: throw URLError(.cannotParseResponse)
            }
            return try JSONDecoder().decode(Event.self, from: body)
        }

        func configure(instructions: String, key: String) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    self.close()
                    throw ChatClient.ClientError.message("连接 Realtime 服务超时。")
                }
                group.addTask {
                    try await self.send(RealtimeVoice.update(instructions: instructions))
                    while !Task.isCancelled {
                        let event = try await self.receive()
                        switch event.type {
                        case "session.updated": return
                        case "error": throw event.failure(redacting: key)
                        default: break
                        }
                    }
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
    }
}

struct VoiceTranscripts {
    private struct Turn {
        let id: String
        let role: ChatMessage.Role
        let date = Date()
        var text: String?
        var ready = false
    }
    private var turns: [Turn] = []

    mutating func start(_ id: String, role: ChatMessage.Role) {
        guard !turns.contains(where: { $0.id == id }) else { return }
        turns.append(Turn(id: id, role: role))
    }

    mutating func transcribe(_ id: String, text: String) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].text = text
        if turns[index].role == .user { turns[index].ready = true }
    }

    mutating func finish(_ id: String, keep: Bool) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        if !keep { turns[index].text = nil }
        turns[index].ready = true
    }

    mutating func drain(closing: Bool = false, save: (ChatMessage) throws -> Void) rethrows {
        while let turn = turns.first, turn.ready || closing {
            if turn.ready, let text = turn.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try save(.init(role: turn.role, content: text, date: turn.date))
            }
            turns.removeFirst()
        }
    }
}
