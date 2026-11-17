#if os(macOS)
import Darwin
import Foundation

actor CopilotPipeWriter {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws {
        try Task.checkCancellation()
        try handle.write(contentsOf: data)
    }
}

// Cancellation closes both directions before waiting for the child. This also
// releases an input write or output read blocked by a stopped bridge.
final class CopilotProcessIO: @unchecked Sendable {
    let process: Process
    let reader: FileHandle
    let writer: FileHandle
    private let lock = NSLock()
    private var stopped = false
    init(process: Process, reader: FileHandle, writer: FileHandle) {
        self.process = process; self.reader = reader; self.writer = writer
    }
    func closeInput() { try? writer.close() }
    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        guard first else { return }
        try? writer.close()
        try? reader.close()
        if process.isRunning { process.terminate() }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func wait() async -> Int32 {
        let process = process
        return await Task.detached {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}

enum CopilotJSONValue: Codable, Sendable {
    case object([String: CopilotJSONValue]), array([CopilotJSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

@MainActor final class CopilotToolDispatcher {
    let requestID: String
    private let execution: LocalToolExecution
    private let validate: ProxyRouteCheck?
    private let writer: CopilotPipeWriter
    private let io: CopilotProcessIO
    private let onLocalTool: (@MainActor (String?) -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var answering = Set<String>()
    private var names: [String: String] = [:]
    private var seen = Set<String>()
    private(set) var failure: Error?

    init(requestID: String, execution: LocalToolExecution, validate: ProxyRouteCheck?,
         writer: CopilotPipeWriter, io: CopilotProcessIO, onLocalTool: (@MainActor (String?) -> Void)?) {
        self.requestID = requestID; self.execution = execution; self.validate = validate
        self.writer = writer; self.io = io; self.onLocalTool = onLocalTool
    }
    private func check() throws {
        try Task.checkCancellation()
        try validate?()
        try execution.validate()
    }
    func call(id: String, name: String, arguments: [String: CopilotJSONValue]) throws {
        try check()
        guard UUID(uuidString: id) != nil, execution.names.contains(name), !seen.contains(id),
              seen.count < 64, tasks.count < 8 else { throw CocoaError(.fileReadCorruptFile) }
        let argumentsData = try JSONEncoder().encode(arguments)
        guard argumentsData.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        seen.insert(id)
        names[id] = name
        let call = LocalToolCall(id: nil, callID: id, name: name, namespace: execution.namespace,
                                 arguments: String(decoding: argumentsData, as: UTF8.self))
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.tasks.removeValue(forKey: id)
                self.answering.remove(id)
                self.names.removeValue(forKey: id)
                self.onLocalTool?(self.names.sorted { $0.key < $1.key }.first?.value)
            }
            do {
                try self.check()
                self.onLocalTool?(name)
                let text: String
                do { text = try await self.execution.perform(call) }
                catch {
                    if error is LocalCloudTools.ScopeError { throw error }
                    try self.check()
                    try await self.respond(id: id, status: "error", code: "failed", text: "")
                    return
                }
                try self.check()
                if text.isEmpty || text.utf8.count > 1024 * 1024 {
                    try await self.respond(id: id, status: "error", code: "limit_exceeded", text: "")
                } else {
                    try await self.respond(id: id, status: "ok", code: nil, text: text)
                }
            } catch {
                if Task.isCancelled { return }
                self.failure = error
                self.io.stop()
            }
        }
    }
    private func respond(id: String, status: String, code: String?, text: String) async throws {
        try check()
        var result: [String: String] = ["type": "tool_result", "request_id": requestID,
                                       "call_id": id, "status": status, "text": text]
        if let code { result["code"] = code }
        let data = try JSONSerialization.data(withJSONObject: result)
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        answering.insert(id)
        try await writer.write(frame)
        try check()
    }
    func cancel(id: String) throws {
        guard seen.contains(id) else { throw CocoaError(.fileReadCorruptFile) }
        tasks.removeValue(forKey: id)?.cancel()
        answering.remove(id)
        names.removeValue(forKey: id)
        onLocalTool?(names.sorted { $0.key < $1.key }.first?.value)
    }
    func finish() async throws {
        if let failure { throw failure }
        // SDK completion may race the writer's return to MainActor. Only tasks
        // already writing their result may still be settling at EOF.
        guard Set(tasks.keys).isSubset(of: answering) else { throw CocoaError(.fileReadCorruptFile) }
        let pending = Array(tasks.values)
        for task in pending { await task.value }
        if let failure { throw failure }
        try check()
    }
    func cancelAll() {
        let pending = Array(tasks.values)
        tasks.removeAll()
        answering.removeAll()
        names.removeAll()
        for task in pending { task.cancel() }
        onLocalTool?(nil)
    }
}
#endif
