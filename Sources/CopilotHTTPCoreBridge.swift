import Foundation
import AAUVCore

// Small app-facing adapter: Go remains the owner of request schemas,
// continuation validation, function-call policy and stream terminal semantics.
@MainActor
enum CopilotHTTPCoreBridge {
    static func reply(
        to messages: [ChatMessage], prepared: CopilotHTTPAdapter.Prepared,
        adapter: CopilotHTTPAdapter, guards: CopilotHTTPAdapter.Guards,
        instructions: String = "", attachments: [ChatClient.AttachmentInput] = [],
        localTools: [String] = [], continuation: Data? = nil, usedCallIDs: [String] = [],
        allowEmptyFinalReply: Bool = false,
        willSend: (@MainActor @Sendable () throws -> Void)? = nil,
        onUsage: (@MainActor @Sendable (UsageCounts) -> Void)? = nil,
        onDelta: (@MainActor @Sendable (String) throws -> Void)? = nil
    ) async throws -> ResponseToolLoop.Turn {
        try Task.checkCancellation()
        try guards.validateScope()
        guard (prepared.apiProtocol != .responses || prepared.model.capabilities?.supports?.streaming != false),
              localTools.isEmpty || prepared.model.capabilities?.supports?.tool_calls != false else {
            throw CopilotHTTPAdapter.Failure.unsupportedProtocol
        }
        var inline: [InlineRequestBody.File] = []
        var fields: [[String: String]] = []
        for attachment in attachments {
            switch attachment {
            case .inline(let file):
                let part = InlineRequestBody.File(attachment: file)
                inline.append(part); fields.append(part.fields)
            case .uploaded:
                // No documented Copilot file-upload endpoint or cross-provider
                // file-ID contract was found. Use the existing inline stager.
                throw CopilotHTTPAdapter.Failure.invalidRequest
            }
        }
        var input: [String: Any] = [
            "protocol": prepared.apiProtocol.rawValue, "base_url": prepared.baseURL.absoluteString,
            "model": prepared.model.id,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "instructions": instructions, "files": fields, "credential_kind": "byok", "hosted_tools": []
        ]
        if !localTools.isEmpty { input["local_tools"] = localTools }
        var encoded = try JSONSerialization.data(withJSONObject: input)
        if let continuation {
            encoded.removeLast()
            encoded.append(Data(",\"continuation\":".utf8))
            encoded.append(continuation) // Preserve opaque JSON numbers verbatim.
            encoded.append(125)
        }
        var error: NSError?
        let planJSON = AauvcoreBuildRequest(String(decoding: encoded, as: UTF8.self), &error)
        guard error == nil else { throw CopilotHTTPAdapter.Failure.invalidRequest }
        struct Plan: Decodable { let url: URL; let streaming: Bool }
        guard let plan = try? JSONDecoder().decode(Plan.self, from: Data(planJSON.utf8)),
              plan.url == prepared.requestURL, plan.streaming == (prepared.apiProtocol == .responses),
              let template = AauvcoreRequestPlanBody(planJSON, &error), error == nil else {
            throw CopilotHTTPAdapter.Failure.invalidRequest
        }
        let staged: InlineRequestBody?
        let body: CopilotHTTPBody
        if inline.isEmpty {
            staged = nil; body = .data(template)
        } else {
            let file = try InlineRequestBody(template: template, files: inline)
            staged = file; body = .file(file.url, bytes: file.size)
        }
        defer { withExtendedLifetime(staged) {} }
        if prepared.apiProtocol == .chatCompletions {
            let collector = CompletionData()
            try await adapter.send(prepared, body: body, guards: guards, willSend: willSend, onChunk: { try await collector.append($0) })
            try Task.checkCancellation()
            try guards.validateScope()
            let text = AauvcoreDecodeCompletion(String(decoding: collector.data, as: UTF8.self), &error)
            guard error == nil, !text.isEmpty else { throw CopilotHTTPAdapter.Failure.invalidStream }
            struct CompletionUsage: Decodable { let usage: UsageCounts? }
            if let usage = (try? JSONDecoder().decode(CompletionUsage.self, from: collector.data))?.usage { onUsage?(usage) }
            try onDelta?(text)
            return .init(reply: .init(text: text), outputJSON: Data("[]".utf8), calls: [])
        }
        let decoder = try Decoder(localTools: localTools, usedCallIDs: usedCallIDs,
                                  validateScope: guards.validateScope, allowEmptyFinalReply: allowEmptyFinalReply, onUsage: onUsage, onDelta: onDelta)
        try await adapter.send(prepared, body: body, guards: guards, willSend: willSend, onChunk: { try await decoder.push($0) })
        return try decoder.finish(protocol: prepared.apiProtocol)
    }

    @MainActor private final class CompletionData {
        var data = Data()
        func append(_ chunk: Data) throws -> Bool {
            guard chunk.count <= 32 * 1024 * 1024 - data.count else { throw CopilotHTTPAdapter.Failure.responseTooLarge }
            data.append(chunk)
            return true
        }
    }

    @MainActor private final class Decoder {
        private let stream: AauvcoreStream
        private var pending = Data()
        private var totalBytes = 0
        private let onDelta: (@MainActor @Sendable (String) throws -> Void)?
        private let validateScope: @MainActor @Sendable () throws -> Void
        private let allowEmptyFinalReply: Bool
        private let onUsage: (@MainActor @Sendable (UsageCounts) -> Void)?
        private var completed = false

        init(localTools: [String], usedCallIDs: [String], validateScope: @escaping @MainActor @Sendable () throws -> Void,
             allowEmptyFinalReply: Bool, onUsage: (@MainActor @Sendable (UsageCounts) -> Void)?,
             onDelta: (@MainActor @Sendable (String) throws -> Void)?) throws {
            self.onDelta = onDelta
            self.validateScope = validateScope
            self.allowEmptyFinalReply = allowEmptyFinalReply
            self.onUsage = onUsage
            var error: NSError?
            let parser: AauvcoreStream?
            if localTools.isEmpty {
                parser = AauvcoreNewStream()
            } else {
                let policy: [String: Any] = ["local_tools": localTools, "namespace": "", "used_call_ids": usedCallIDs]
                let encoded = try JSONSerialization.data(withJSONObject: policy)
                parser = AauvcoreNewStreamWithLocalTools(String(decoding: encoded, as: UTF8.self), &error)
            }
            guard error == nil, let parser else { throw CopilotHTTPAdapter.Failure.invalidStream }
            stream = parser
        }

        struct Update: Decodable { let type: String; let text: String? }
        func push(_ data: Data) throws -> Bool {
            try Task.checkCancellation()
            try validateScope()
            guard !completed else { return false }
            guard data.count <= 64 * 1024 * 1024 - totalBytes else { throw CopilotHTTPAdapter.Failure.responseTooLarge }
            totalBytes += data.count
            for byte in data {
                pending.append(byte)
                if byte == 10 || pending.count == 8192 {
                    var error: NSError?
                    let events = stream.push(pending, error: &error)
                    pending.removeAll(keepingCapacity: true)
                    guard error == nil, let updates = try? JSONDecoder().decode([Update].self, from: Data(events.utf8)) else {
                        throw CopilotHTTPAdapter.Failure.invalidStream
                    }
                    for update in updates {
                        if update.type == "delta", let text = update.text {
                            try Task.checkCancellation()
                            try validateScope()
                            try onDelta?(text)
                        }
                        if update.type == "completed" { completed = true; return false }
                    }
                }
            }
            return true
        }

        func finish(protocol apiProtocol: CopilotHTTPAdapter.APIProtocol) throws -> ResponseToolLoop.Turn {
            try Task.checkCancellation()
            try validateScope()
            var error: NSError?
            if !pending.isEmpty { _ = stream.push(pending, error: &error) }
            guard error == nil else { throw CopilotHTTPAdapter.Failure.invalidStream }
            let terminal = stream.finish(&error)
            guard error == nil else { throw CopilotHTTPAdapter.Failure.invalidStream }
            struct Envelope: Decodable {
                let text: String?
                let usage: UsageCounts?
                let function_calls: [LocalToolCall]?
                let output: [ResponseWebCitations.Item]?
                enum CodingKeys: String, CodingKey { case text, usage, function_calls, output }
                init(from decoder: Swift.Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    text = try values.decodeIfPresent(String.self, forKey: .text)
                    // Provider-specific/missing usage must not discard an
                    // otherwise complete response (same policy as ChatClient).
                    usage = try? values.decode(UsageCounts.self, forKey: .usage)
                    function_calls = try values.decodeIfPresent([LocalToolCall].self, forKey: .function_calls)
                    output = try values.decodeIfPresent([ResponseWebCitations.Item].self, forKey: .output)
                }
            }
            guard let reply = try? JSONDecoder().decode(Envelope.self, from: Data(terminal.utf8)) else {
                throw CopilotHTTPAdapter.Failure.invalidStream
            }
            let text = reply.text ?? ""
            let calls = reply.function_calls ?? []
            guard !text.isEmpty || !calls.isEmpty || allowEmptyFinalReply else { throw CopilotHTTPAdapter.Failure.invalidStream }
            let output: Data
            if apiProtocol == .responses {
                let raw = stream.completedOutput(&error)
                guard error == nil else { throw CopilotHTTPAdapter.Failure.invalidStream }
                output = Data(raw.utf8)
            } else {
                output = Data("[]".utf8)
            }
            if let usage = reply.usage { onUsage?(usage) }
            return .init(reply: .init(text: text, citations: ResponseWebCitations.collect(from: reply.output ?? [], matching: text)),
                         outputJSON: output, calls: calls)
        }
    }
}
