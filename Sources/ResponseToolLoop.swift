import Foundation

struct LocalToolCall: Codable, Sendable {
    let id: String?
    let callID: String
    let name: String
    let namespace: String
    let arguments: String

    enum CodingKeys: String, CodingKey { case id, callID = "call_id", name, namespace, arguments }
}

struct LocalToolExecution: Sendable {
    let names: [String]
    let namespace: String
    let validate: @MainActor @Sendable () throws -> Void
    let perform: @MainActor @Sendable (LocalToolCall) async throws -> String
    let drainGenerated: @MainActor @Sendable () -> ChatClient.GeneratedFiles
    let hasGeneratedFiles: @MainActor @Sendable () -> Bool

    init(names: [String], namespace: String, validate: @escaping @MainActor @Sendable () throws -> Void = {},
         drainGenerated: @escaping @MainActor @Sendable () -> ChatClient.GeneratedFiles = { .init() },
         hasGeneratedFiles: @escaping @MainActor @Sendable () -> Bool = { false },
         perform: @escaping @MainActor @Sendable (LocalToolCall) async throws -> String) {
        self.names = names
        self.namespace = namespace
        self.validate = validate
        self.perform = perform
        self.drainGenerated = drainGenerated
        self.hasGeneratedFiles = hasGeneratedFiles
    }
}

enum ResponseToolLoop {
    struct State: Sendable {
        var continuation = Data("[]".utf8)
        var usedCallIDs: [String] = []
        var remainingFileCount = 32
        var remainingFileBytes = 32 * 1024 * 1024
        var allowEmptyFinalReply = false
    }

    struct Turn: Sendable {
        var reply: ChatClient.CompletedReply
        let outputJSON: Data
        let calls: [LocalToolCall]
        var generated = ChatClient.GeneratedFiles()
    }

    struct Limits: Sendable {
        var rounds = 12
        var calls = 40
        var continuationBytes = 64 * 1024 * 1024
        var resultBytes = 4 * 1024 * 1024
        var textBytes = 32 * 1024 * 1024
    }

    @MainActor static func run(
        execution: LocalToolExecution, limits: Limits = Limits(),
        send: @MainActor (State) async throws -> Turn,
        onDelta: (@MainActor (String) throws -> Void)? = nil,
        onLocalTool: (@MainActor (String?) -> Void)? = nil,
        onReplyReady: (@MainActor (ChatClient.CompletedReply) throws -> Void)? = nil,
        onGeneratedFiles: (@MainActor (ChatClient.GeneratedFiles) throws -> Void)? = nil
    ) async throws -> String {
        let allowed = Set(execution.names)
        guard !allowed.isEmpty, allowed.count == execution.names.count,
              ["", "aauv"].contains(execution.namespace), limits.rounds > 0, limits.calls > 0 else {
            throw ChatClient.ClientError.message("本机工具配置无效。")
        }
        var state = State()
        var seen = Set<String>()
        var text = ""
        var citations: [WebCitation] = []
        var generated = ChatClient.GeneratedFiles()
        var localFiles = 0
        var localBytes = 0
        var deliveryStarted = false
        defer { onLocalTool?(nil) }

        func collectLocalFiles() throws {
            try execution.validate()
            let prepared = execution.drainGenerated()
            generated.unavailable += prepared.unavailable
            for file in prepared.files {
                if localFiles < 5, file.data.count <= 25 * 1024 * 1024,
                   file.data.count <= 125 * 1024 * 1024 - localBytes {
                    generated.files.append(file)
                    localFiles += 1
                    localBytes += file.data.count
                } else { generated.unavailable += 1 }
            }
            state.allowEmptyFinalReply = !generated.files.isEmpty
        }

        func deliver() throws {
            try execution.validate()
            deliveryStarted = true
            try onReplyReady?(.init(text: text, citations: citations,
                                   fileCount: generated.files.count + generated.unavailable))
            if !generated.files.isEmpty || generated.unavailable != 0 {
                try onGeneratedFiles?(generated)
            }
        }

        do {
            for index in 0..<limits.rounds {
                try Task.checkCancellation()
                try execution.validate()
                if index > 0, !text.isEmpty { try onDelta?("\n\n") }
                let turn = try await send(state)
                if !turn.reply.text.isEmpty {
                    let separator = text.isEmpty ? "" : "\n\n"
                    guard text.utf8.count + separator.utf8.count + turn.reply.text.utf8.count <= limits.textBytes else {
                        throw ChatClient.ClientError.message("本轮回复过长，请分次请求。")
                    }
                    let offset = text.unicodeScalars.count + separator.unicodeScalars.count
                    text += separator + turn.reply.text
                    citations += turn.reply.citations.map { item in
                        WebCitation(url: item.url, title: item.title,
                                    start: item.start.map { $0 + offset }, end: item.end.map { $0 + offset })
                    }
                }
                generated.unavailable += max(turn.generated.unavailable, turn.reply.fileCount - turn.generated.files.count)
                for file in turn.generated.files {
                    if state.remainingFileCount > 0, file.data.count <= state.remainingFileBytes {
                        generated.files.append(file)
                        state.remainingFileCount -= 1
                        state.remainingFileBytes -= file.data.count
                    } else {
                        generated.unavailable += 1
                    }
                }
                try execution.validate()
                guard !turn.calls.isEmpty else {
                    guard !turn.reply.text.isEmpty || !generated.files.isEmpty else {
                        throw ChatClient.ClientError.message("服务商未返回文本。")
                    }
                    try deliver()
                    return text
                }
                try Task.checkCancellation()
                guard index + 1 < limits.rounds, seen.count + turn.calls.count <= limits.calls else {
                    throw ChatClient.ClientError.message("本轮工具调用已达上限，请分次请求。")
                }
                // Validate the entire batch before the first local side effect.
                var batch = Set<String>()
                for call in turn.calls {
                    guard allowed.contains(call.name), call.namespace == execution.namespace,
                          validCallID(call.callID), !seen.contains(call.callID), batch.insert(call.callID).inserted else {
                        throw ChatClient.ClientError.message("模型返回了未允许或重复的本机工具调用。")
                    }
                }
                seen.formUnion(batch)
                state.usedCallIDs = seen.sorted()
                var results: [[String: String]] = []
                for call in turn.calls {
                    try Task.checkCancellation()
                    try execution.validate()
                    onLocalTool?(call.name)
                    let result = try await execution.perform(call)
                    try collectLocalFiles()
                    try Task.checkCancellation()
                    try execution.validate()
                    guard result.utf8.count <= limits.resultBytes else {
                        throw ChatClient.ClientError.message("本机工具结果过长，请缩小请求范围。")
                    }
                    results.append(["type": "function_call_output", "call_id": call.callID, "output": result])
                    onLocalTool?(nil)
                }
                let encoded = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
                state.continuation = try await appendContinuation(state.continuation, output: turn.outputJSON,
                                                                 results: encoded, maximumBytes: limits.continuationBytes)
            }
            throw ChatClient.ClientError.message("本轮工具调用未能完成，请重试。")
        } catch {
            // Keep files from successful completed rounds even when a later
            // continuation fails; an interrupted round itself supplies no files.
            if !deliveryStarted {
                try collectLocalFiles()
                if !generated.files.isEmpty { try deliver() }
            }
            throw error
        }
    }

    private static func validCallID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    private static func appendContinuation(_ previous: Data, output: Data, results: Data, maximumBytes: Int) async throws -> Data {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let parts = try [previous, output, results].map(arrayContents).filter { !$0.isEmpty }
            let size = parts.reduce(2) { $0 + $1.count } + max(0, parts.count - 1)
            guard size <= maximumBytes else {
                throw ChatClient.ClientError.message("工具上下文过大，请分次请求。")
            }
            var combined = Data(capacity: size)
            combined.append(91)
            for (index, part) in parts.enumerated() {
                if index != 0 { combined.append(44) }
                combined.append(part)
            }
            combined.append(93)
            try Task.checkCancellation()
            return combined
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // Output comes from Stream.CompletedOutput after its successful terminal
    // validation. Preserve opaque JSON bytes rather than rebuilding old items.
    private static func arrayContents(_ data: Data) throws -> Data {
        var start = data.startIndex
        var end = data.endIndex
        let whitespace: Set<UInt8> = [9, 10, 13, 32]
        while start < end, whitespace.contains(data[start]) { start += 1 }
        while start < end, whitespace.contains(data[end - 1]) { end -= 1 }
        guard end - start >= 2, data[start] == 91, data[end - 1] == 93 else {
            throw ChatClient.ClientError.message("模型工具上下文无效。")
        }
        let content = data[(start + 1)..<(end - 1)]
        return content.allSatisfy(whitespace.contains) ? Data() : Data(content)
    }
}
