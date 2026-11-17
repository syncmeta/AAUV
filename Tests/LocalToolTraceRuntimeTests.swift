import Foundation

@main struct LocalToolTraceRuntimeTests {
    static func main() throws {
        let entry = LocalToolTrace.Entry(id: UUID(), sequence: 0, function: .searchChatHistory, state: .succeeded,
                                          query: "TRACE_QUERY_SENTINEL", quantity: 4)
        let trace = LocalToolTrace(requestID: UUID(), runRevision: "1000000000000000001", entries: [entry])
        let now = Date(timeIntervalSince1970: 1793901600)
        var source = ChatMessage(role: .user, content: "只保留用户正文", date: now.addingTimeInterval(-60))
        source.localToolTrace = trace
        source.attachments = [.init(name: "synthetic.bin", fileName: UUID().uuidString, size: 1)]
        source.selectedReplyID = UUID()
        let runtime = try RuntimePrompt(botName: "合成机器人", now: now, timeZone: TimeZone(identifier: "Asia/Taipei")!)
        let copied = try runtime.messages([source], originals: [source])[0]
        precondition(copied.localToolTrace == source.localToolTrace)
        precondition(copied.id == source.id && copied.attachments?.first?.fileName == source.attachments?.first?.fileName)
        precondition(copied.selectedReplyID == source.selectedReplyID)
        precondition(copied.content.hasPrefix(source.content) && !copied.content.contains(entry.query!))
        precondition(!runtime.instructions.contains(entry.query!))
        let tracedItem = ContextWindow.Item(source)
        var plain = source; plain.localToolTrace = nil
        let plainItem = ContextWindow.Item(plain)
        precondition(tracedItem == plainItem && tracedItem.content.unicodeScalars.count == source.content.unicodeScalars.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let tracedInput = try encoder.encode(tracedItem)
        let plainInput = try encoder.encode(plainItem)
        precondition(tracedInput == plainInput)
        let modelInput = String(decoding: tracedInput, as: UTF8.self)
        precondition(!modelInput.contains("localToolTrace") && !modelInput.contains("runRevision") && !modelInput.contains("sequence") && !modelInput.contains("query") && !modelInput.contains(entry.query!))
        print("RuntimePrompt preserved the exact typed trace in model-only copies without inserting it into text/instructions; actual ContextWindow.Item inputs and raw character count were byte-for-byte identical with and without display metadata.")
    }
}
