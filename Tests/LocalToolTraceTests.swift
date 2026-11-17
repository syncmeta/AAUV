import Foundation

@main struct LocalToolTraceTests {
    static func main() throws {
        let request = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
        let running = LocalToolTrace.Entry(id: UUID(), sequence: 1, function: .createSkill, state: .running, skillName: "meeting-notes")
        let search = LocalToolTrace.Entry(id: UUID(), sequence: 0, function: .searchChatHistory, state: .succeeded,
                                          query: "上次 OR \"预算\" [omitted]", queryTruncated: true, quantity: 3)
        let image = LocalToolTrace.Entry(id: UUID(), sequence: 2, function: .sendImages, state: .partial, quantity: 2)
        let failed = LocalToolTrace.Entry(id: UUID(), sequence: 3, function: .readAttachment, state: .failed, failure: .timeout)
        let delegated = LocalToolTrace.Entry(id: UUID(), sequence: 4, function: .delegateToSpecialist, state: .succeeded, quantity: 200)
        let trace = LocalToolTrace(requestID: request, runRevision: "1000000000000000001", entries: [search, running, image, failed, delegated])
        let bytes = try trace.encoded()
        let restored = try LocalToolTrace.decode(bytes)
        precondition(restored == trace)
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        precondition(object["requestID"] as? String == request.uuidString.lowercased())
        precondition((object["entries"] as! [[String: Any]]).allSatisfy { ($0["id"] as! String) == ($0["id"] as! String).lowercased() })
        precondition(trace.displayState(for: running, activeRequestID: request) == .running)
        precondition(trace.displayState(for: running, activeRequestID: nil) == .unconfirmed)
        precondition(trace.displayState(for: running, activeRequestID: UUID()) == .unconfirmed)
        precondition(trace.displayState(for: search, activeRequestID: nil) == .succeeded)
        let interrupted = trace.interruptingRunningEntries()
        precondition(trace.entries[1].state == .running && interrupted.entries[1].state == .interrupted)
        precondition(interrupted.entries[0] == search && interrupted.entries[2] == image && interrupted.entries[3] == failed)
        precondition(interrupted.runRevision == trace.runRevision)
        precondition(interrupted.entries.map(\.sequence) == trace.entries.map(\.sequence))
        precondition(interrupted.requestID == trace.requestID && interrupted.entries.map(\.id) == trace.entries.map(\.id))
        precondition(interrupted.displayState(for: interrupted.entries[1], activeRequestID: request) == .unconfirmed)
        precondition(interrupted.interruptingRunningEntries() == interrupted)

        var checks = 0
        func rejected(_ name: String, _ modify: (inout [String: Any]) -> Void) throws {
            var copy = object
            modify(&copy)
            let data = try JSONSerialization.data(withJSONObject: copy)
            do { _ = try LocalToolTrace.decode(data); preconditionFailure("Accepted invalid schema: " + name) }
            catch { checks += 1 }
        }
        func entry(_ name: String, _ modify: (inout [String: Any]) -> Void) throws {
            try rejected(name) { root in
                var entries = root["entries"] as! [[String: Any]]
                modify(&entries[0]); root["entries"] = entries
            }
        }
        try rejected("version") { $0["version"] = 2 }
        try rejected("missing version") { $0["version"] = nil }
        try rejected("missing Core run ordering") { $0["runRevision"] = nil }
        try rejected("run ordering is not number input") { $0["runRevision"] = 1 }
        for clock in ["0", "0000000000000000000", "9999999999999999999", "100000000000000000x"] {
            try rejected("invalid Core run ordering") { $0["runRevision"] = clock }
        }
        try rejected("provider call ID used as host request") { $0["requestID"] = "call_provider_id" }
        try rejected("unknown envelope field") { $0["arguments"] = ["token": "synthetic-secret"] }
        try rejected("duplicate invocation IDs") { root in var e = root["entries"] as! [[String: Any]]; e.append(e[0]); root["entries"] = e }
        try rejected("65 invocations") { root in root["entries"] = (0..<65).map { _ -> [String: Any] in ["id": UUID().uuidString, "sequence": 0, "function": "create_skill", "state": "running"] } }
        try entry("missing Core sequence") { $0["sequence"] = nil }
        try entry("negative Core sequence") { $0["sequence"] = -1 }
        try entry("Core sequence max") { $0["sequence"] = 64 }
        try entry("Core sequence type") { $0["sequence"] = "0" }
        try entry("unknown tool") { $0["function"] = "shell" }
        try entry("unknown state") { $0["state"] = "done" }
        try entry("free error") { $0["error"] = "https://synthetic.invalid/private" }
        try entry("arbitrary URL field") { $0["url"] = "https://synthetic.invalid" }
        try entry("null optional") { $0["query"] = NSNull() }
        try entry("null flag") { $0["queryTruncated"] = NSNull() }
        try entry("fraction quantity") { $0["quantity"] = 1.5 }
        try entry("bool quantity") { $0["quantity"] = true }
        try entry("search limit") { $0["quantity"] = 31 }
        try entry("negative quantity") { $0["quantity"] = -1 }
        try entry("query without search") { $0["function"] = "read_attachment" }
        try entry("skill outside create") { $0["skillName"] = "safe-skill" }
        try entry("truncation without query") { $0["query"] = nil }
        try entry("running result") { $0["state"] = "running" }
        try entry("success failure") { $0["failure"] = "timeout" }
        try entry("raw failure text") { $0["state"] = "failed"; $0["failure"] = "secret user path" }
        try entry("partial wrong tool") { $0["state"] = "partial" }
        for query in ["https://synthetic.invalid/path?q=private", "www.synthetic.invalid/key", "Bearer SYNTHETIC_TOKEN", "access_token=synthetic", "sk-SYNTHETIC000000000", "github_pat_SYNTHETIC000000000", "eyJabcdefghijklmno.abcdefghijklmnopq.abcdefghijklmnopq", "two  spaces", "budget OR ", "line\nnext", "\u{202E}reverse", String(repeating: "绿", count: 257)] {
            try entry("unsafe/unbounded query") { $0["query"] = query }
        }
        let validEntry: [String: Any] = ["id": UUID().uuidString, "sequence": 0, "function": "send_images", "state": "partial", "quantity": 1]
        func singleRejected(_ name: String, _ modify: (inout [String: Any]) -> Void) throws {
            try rejected(name) { root in var copy = validEntry;modify(&copy);root["entries"] = [copy] }
        }
        try singleRejected("partial zero") { $0["quantity"] = 0 }
        try singleRejected("images max") { $0["quantity"] = 6 }
        try singleRejected("partial failure") { $0["failure"] = "tool_failed" }
        try singleRejected("answer count max") { $0["function"] = "read_attachment"; $0["state"] = "succeeded"; $0["quantity"] = 4 * 1024 * 1024 + 1 }
        try singleRejected("create count") { $0["function"] = "create_skill"; $0["state"] = "succeeded" }
        for name in ["UPPER", "has_underscore", "", String(repeating: "a", count: 81)] {
            try singleRejected("invalid skill") { $0["function"] = "create_skill"; $0["state"] = "succeeded"; $0["quantity"] = nil; $0["skillName"] = name }
        }
        let inputEvent = LocalToolTrace.Event(id: UUID(), function: .searchChatHistory, state: .running, query: "budget")
        let eventData = try JSONEncoder().encode(inputEvent)
        let eventFields = try JSONSerialization.jsonObject(with: eventData) as! [String: Any]
        precondition(eventFields["sequence"] == nil && eventFields["runRevision"] == nil)
        precondition(Set(eventFields.keys) == ["id", "function", "state", "query"])
        let maximum = LocalToolTrace(requestID: request, runRevision: "1000000000000000001", entries: (0..<64).map { index in .init(id: UUID(), sequence: index, function: .searchChatHistory, state: .succeeded, query: String(repeating: "🌱", count: 256), quantity: 30) })
        let maximumBytes = try maximum.encoded()
        precondition(maximumBytes.count <= LocalToolTrace.maximumBytes)
        // Core keeps incomplete URL syntax and short placeholder token words;
        // Core trims after clipping; a 256-scalar clip may canonically be 255.
        for query in ["protocol https://", "www.", "sk-example12", "authorization:", "api_key=", "api-key=", "\"authorization\":", "Basic", String(repeating: "a ", count: 127) + "a"] {
            let canonical = LocalToolTrace(requestID: request, runRevision: "1000000000000000001", entries: [
                .init(id: UUID(), sequence: 0, function: .searchChatHistory, state: .succeeded, query: query, queryTruncated: true)
            ])
            let decoded = try LocalToolTrace.decode(canonical.encoded())
            precondition(decoded.entries[0].query == query)
        }
        let allFailures = LocalToolTrace.Failure.allCases.map { LocalToolTrace.Entry(id: UUID(), sequence: 0, function: .readAttachment, state: .failed, failure: $0) }
        _ = try LocalToolTrace(requestID: request, runRevision: "1000000000000000001", entries: allFailures).encoded()
        _ = try LocalToolTrace(requestID: request, runRevision: "1000000000000000001", entries: []).encoded()
        do { _ = try LocalToolTrace.decode(Data(repeating: 32, count: LocalToolTrace.maximumBytes + 1));preconditionFailure("Accepted oversized envelope") }
        catch { checks += 1 }
        print("LocalToolTrace schema passed \(checks) malformed/unsafe cases, five tools, canonical host UUIDs, 64-entry Unicode boundary, read-only orphan-running presentation, and copy-only running interruption with terminal history unchanged.")
    }
}
