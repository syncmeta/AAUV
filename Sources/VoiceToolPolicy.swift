import Foundation

// Realtime has its own allowlist. Ordinary chat tools never enter a voice session.
struct VoiceToolPolicy {
    static var tools: [[String: Any]] {
        [["type": "function", "name": "hang_up",
          "description": "Hang up (end) this voice call. Call this when the user asks you to hang up, or when the conversation has clearly finished.",
          "parameters": ["type": "object", "properties": [:], "additionalProperties": false] as [String: Any]]]
    }

    private static let maximumResponses = 4096
    private var started: Set<String> = []
    private var finished: Set<String> = []
    private var usedCalls: Set<String> = []
    private var usedItems: Set<String> = []
    private var latest: String?
    private var interrupted: Set<String> = []
    private(set) var pendingHangUp: String?

    static var protocolError: ChatClient.ClientError {
        .message("语音服务返回了无效或未允许的工具调用，请重新连接。")
    }

    mutating func responseCreated(_ id: String?) throws {
        guard let id, Self.validID(id) else { throw Self.protocolError }
        guard !started.contains(id), !finished.contains(id) else { return }
        guard started.count < Self.maximumResponses else { throw Self.protocolError }
        started.insert(id)
        latest = id
        pendingHangUp = nil
    }

    mutating func interrupt() {
        if let latest { interrupted.insert(latest) }
        pendingHangUp = nil
    }

    // response.done is the only execution boundary. Argument/output-item done
    // events can also arrive for cancelled or incomplete responses.
    // Returns false for a duplicate terminal event, so usage is saved once.
    mutating func responseDone(_ response: RealtimeVoice.Event.Response) throws -> Bool {
        guard let id = response.id, Self.validID(id),
              ["completed", "cancelled", "incomplete", "failed"].contains(response.status) else {
            throw Self.protocolError
        }
        guard !finished.contains(id) else { return false }
        guard finished.count < Self.maximumResponses else { throw Self.protocolError }
        finished.insert(id)
        guard response.status == "completed" else {
            if pendingHangUp == id { pendingHangUp = nil }
            return true
        }
        let calls = (response.output ?? []).filter { $0.type == "function_call" }
        guard !calls.isEmpty else { return true }
        // Invalid tools are a protocol failure, rather than a function call that
        // stays unresolved forever or an opportunity to execute other tools.
        guard calls.count == 1, let call = calls.first,
              call.name == "hang_up", call.status == "completed",
              let output = response.output, output.allSatisfy({ Self.validID($0.id) }),
              Set(output.map(\.id)).count == output.count,
              Self.validID(call.id), let callID = call.call_id, Self.validID(callID),
              let arguments = call.arguments, arguments.utf8.count <= 1024,
              let bytes = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], object.isEmpty else {
            throw Self.protocolError
        }
        guard started.contains(id), usedCalls.insert(callID).inserted,
              usedItems.insert(call.id).inserted else { throw Self.protocolError }
        guard latest == id, !interrupted.contains(id) else { return true }
        pendingHangUp = id
        return true
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
