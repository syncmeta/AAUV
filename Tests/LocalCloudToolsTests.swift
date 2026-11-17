import Foundation

@main @MainActor
struct LocalCloudToolsTests {
    private struct FixtureFailure: LocalizedError {
        let unsafe: String
        var errorDescription: String? { unsafe }
    }
    private struct ScopeFailure: Error, Equatable { let generation: Int }
    private static let first = Attachment(id: UUID(uuidString: "abcdef01-0000-0000-0000-000000000001")!, name: "notes.txt", fileName: "fixture-one", size: 3)
    private static let second = Attachment(id: UUID(uuidString: "abcdef01-0000-0000-0000-000000000002")!, name: "notes.txt", fileName: "fixture-two", size: 4)
    private static let other = Attachment(id: UUID(uuidString: "12345678-0000-0000-0000-000000000003")!, name: "outside.txt", fileName: "fixture-other", size: 5)

    private static func expect(_ condition: Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition, file: file, line: line) }

    private static func invocation(_ name: String, _ arguments: [String: Any]) throws -> LocalToolCall {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return LocalToolCall(id: nil, callID: "call_fixture", name: name, namespace: "", arguments: String(decoding: data, as: UTF8.self))
    }

    private static func object(_ encoded: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else { fatalError("Invalid tool JSON") }
        return value
    }

    private static func requestFile(_ attachment: Attachment) -> RequestAttachment {
        RequestAttachment(name: attachment.name, mediaType: "text/plain", url: URL(fileURLWithPath: "/synthetic-fixture/" + attachment.fileName), size: attachment.size)
    }

    static func main() async throws {
        try await attachmentScopeAndResolution()
        try await argumentValidationAndDelegationIsolation()
        try await scopeRevalidationAndSafeErrors()
        try await timeoutsAndCancellationPropagate()
        try await truncationProducesBoundedHonestJSON()
        print("Local cloud tools: current-conversation UUID/prefix resolution, parameter limits, isolated request arguments, before/after scope checks, safe errors, 5-minute maximum/test deadlines, child cancellation/late-result suppression, and bounded marked JSON truncation passed with synthetic closures only.")
    }

    private static func attachmentScopeAndResolution() async throws {
        var sent = 0
        var prepared: [UUID] = []
        let tools = LocalCloudTools(attachments: [first,first], prepareAttachment: { attachment in
            prepared.append(attachment.id)
            return requestFile(attachment)
        }, cloud: { prompt, files, model in
            expect(prompt == "What is inside?" && model == nil && files.count == 1)
            expect(files[0].name == first.name && files[0].size == 3)
            sent += 1
            return "Only the selected file."
        }, validateScope: {})
        for id in [first.id.uuidString, "ABCDEF01-0000-0000-0000-000000000001", "ABCDEF01"] {
            let response = try await tools.perform(invocation("read_attachment", ["attachment_id":id,"question":"  What is inside?\n"]))
            let result = try object(response)
            expect(result["attachment_id"] as? String == first.id.uuidString.lowercased() && result["answer"] as? String == "Only the selected file.")
            expect(!response.contains("synthetic-fixture") && !response.contains("fileName"))
        }
        expect(sent == 3 && prepared == [first.id,first.id,first.id])
        for id in [other.id.uuidString, "notes.txt", "latest", "../../private", "file:///private/key"] {
            let result = try object(await tools.perform(invocation("read_attachment", ["attachment_id":id,"question":"Read"])))
            expect(result["error"] != nil)
        }
        expect(sent == 3)
        let ambiguous = LocalCloudTools(attachments: [first,second], prepareAttachment: { _ in fatalError("Ambiguous file resolved") },
                                       cloud: { _,_,_ in fatalError("Ambiguous file uploaded") }, validateScope: {})
        let result = try object(await ambiguous.perform(invocation("read_attachment", ["attachment_id":"abcdef01","question":"Read"])))
        expect(result["error"] as? String == "attachment_ambiguous")
        let conflicting = Attachment(id: first.id,name: "changed",fileName: "other",size: 6)
        let conflict = LocalCloudTools(attachments: [first,conflicting],prepareAttachment: {_ in fatalError("Conflicting record resolved")},
                                      cloud: {_,_,_ in fatalError("Conflicting record uploaded")},validateScope: {})
        expect(try object(await conflict.perform(invocation("read_attachment",["attachment_id":first.id.uuidString,"question":"Read"]))) ["error"] as? String == "attachment_ambiguous")
    }

    private static func argumentValidationAndDelegationIsolation() async throws {
        var sent = 0
        let tools = LocalCloudTools(attachments: [],prepareAttachment: {_ in fatalError("Delegate read a file")},cloud: { prompt,files,model in
            expect(prompt == "Self-contained question" && files.isEmpty && model == "provider/model")
            sent += 1
            return "Answer"
        },validateScope: {})
        for key in ["model_slug","model","specialist"] {
            let result = try object(await tools.perform(invocation("delegate_to_specialist",[key:" provider/model ","prompt":" Self-contained question "])))
            expect(result["answer"] as? String == "Answer" && result["model_slug"] as? String == "provider/model")
        }
        for (name,args) in [
            ("read_attachment",["attachment_id":first.id.uuidString,"question":String(repeating:"🙂",count:251)] as [String:Any]),
            ("read_attachment",["attachment_id":first.id.uuidString,"question":42]),
            ("delegate_to_specialist",["model_slug":"m","prompt":String(repeating:"🙂",count:4001)]),
            ("delegate_to_specialist",["model_slug":"","prompt":"q"]),
            ("delegate_to_specialist",["model_slug":"m\nsecret","prompt":"q"]),
            ("delegate_to_specialist",["model_slug":"m","prompt":false]),
            ("execute_code",["code":"print('no')"]),
        ] {
            expect(try object(await tools.perform(invocation(name,args)))["error"] != nil)
        }
        let malformed = LocalToolCall(id:nil,callID:"call_bad",name:"delegate_to_specialist",namespace:"",arguments:"[]")
        expect(try object(await tools.perform(malformed))["error"] as? String == "invalid_arguments")
        expect(sent == 3)
    }

    private static func scopeRevalidationAndSafeErrors() async throws {
        let call = try invocation("delegate_to_specialist",["model_slug":"m","prompt":"q"])
        var generation = 0
        var calls = 0
        let stale = LocalCloudTools(attachments: [],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in
            calls += 1
            generation = 1
            return "late answer"
        },validateScope:{if generation != 0 {throw ScopeFailure(generation:generation)}})
        do { _ = try await stale.perform(call);fatalError("Stale scope returned model result") }
        catch let error as ScopeFailure {expect(error.generation == 1 && calls == 1)}

        var checks = 0
        let preflight = LocalCloudTools(attachments: [],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in fatalError("Stale request sent")},validateScope:{
            checks += 1
            if checks == 3 {throw ScopeFailure(generation:2)}
        })
        do {_ = try await preflight.perform(call);fatalError("Cloud-stage scope check swallowed")}
        catch let error as ScopeFailure {expect(error.generation == 2)}

        let unsafe = "Bearer sk-synthetic-fixture /private/synthetic-fixture"
        let failed = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in throw FixtureFailure(unsafe:unsafe)},validateScope:{})
        let encoded = try await failed.perform(call)
        expect(try object(encoded)["error"] as? String == "cloud_request_failed")
        expect(!encoded.contains("Bearer") && !encoded.contains("private") && !encoded.contains("sk-"))
        let missing = LocalCloudTools(attachments:[first],prepareAttachment:{_ in throw FixtureFailure(unsafe:unsafe)},cloud:{_,_,_ in fatalError("Missing file sent")},validateScope:{})
        let fileError = try await missing.perform(invocation("read_attachment",["attachment_id":first.id.uuidString,"question":"q"]))
        expect(try object(fileError)["error"] as? String == "attachment_unavailable" && !fileError.contains("sk-"))
        let typed = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in throw LocalCloudTools.ScopeError.staleScope},validateScope:{})
        do {_ = try await typed.perform(call);fatalError("Typed stale_scope swallowed")}
        catch LocalCloudTools.ScopeError.staleScope {}
        for failure in [CancellationError() as Error,URLError(.cancelled)] {
            let cancelled = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in throw failure},validateScope:{})
            do {_ = try await cancelled.perform(call);fatalError("Cancellation swallowed")}
            catch is CancellationError {}
        }
    }

    private static func timeoutsAndCancellationPropagate() async throws {
        let call = try invocation("delegate_to_specialist",["model_slug":"m","prompt":"q"])
        var observedChildCancellation = false
        var tool = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in
            do {try await Task.sleep(for:.seconds(10));return "late"}
            catch {observedChildCancellation = Task.isCancelled;throw error}
        },validateScope:{})
        tool.limits.timeout = .milliseconds(20)
        let started = ContinuousClock.now
        let timed = try await tool.perform(call)
        expect(try object(timed)["error"] as? String == "cloud_request_timed_out")
        for _ in 0..<10 {await Task.yield()}
        expect(observedChildCancellation && started.duration(to: .now) < .seconds(1))

        var began = false
        observedChildCancellation = false
        let cancelTool = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in
            began = true
            do {try await Task.sleep(for:.seconds(10));return "late"}
            catch {observedChildCancellation = Task.isCancelled;throw error}
        },validateScope:{})
        let task = Task { @MainActor in try await cancelTool.perform(call) }
        while !began {await Task.yield()}
        task.cancel()
        do {_ = try await task.value;fatalError("Parent cancellation returned success")}
        catch is CancellationError {}
        for _ in 0..<10 {await Task.yield()}
        expect(observedChildCancellation)

        // A non-cooperating operation is still signalled and its late success
        // cannot keep the parent waiting past the deadline or replace timeout.
        var late: CheckedContinuation<String,Never>?
        var finishedLate = false
        var stubborn = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in
            let result = await withCheckedContinuation {late = $0}
            finishedLate = true
            expect(Task.isCancelled)
            return result
        },validateScope:{})
        stubborn.limits.timeout = .milliseconds(20)
        let lateResult = try await stubborn.perform(call)
        expect(try object(lateResult)["error"] as? String == "cloud_request_timed_out" && !finishedLate)
        late?.resume(returning:"untrusted late success")
        for _ in 0..<10 {await Task.yield()}
        expect(finishedLate)

        var invalid = cancelTool
        invalid.limits.timeout = .seconds(301)
        expect(try object(await invalid.perform(call))["error"] as? String == "invalid_limits")
    }

    private static func truncationProducesBoundedHonestJSON() async throws {
        let call = try invocation("delegate_to_specialist",["model_slug":"m","prompt":"q"])
        for answer in [String(repeating:"🙂<&>\"\\\n\u{0}",count:300),String(repeating:"a",count:4*1024*1024+1)] {
            var tools = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in answer},validateScope:{})
            tools.limits.resultBytes = 512
            let result = try await tools.perform(call)
            let decoded = try object(result)
            expect(result.utf8.count <= 512 && decoded["truncated"] as? Bool == true)
            expect(decoded["original_utf8_bytes"] as? Int == answer.utf8.count)
            expect((decoded["answer"] as? String)?.hasSuffix("[AAUV: answer truncated]") == true)
        }
        let exact = LocalCloudTools(attachments:[],prepareAttachment:{requestFile($0)},cloud:{_,_,_ in "no truncation"},validateScope:{})
        let result = try object(await exact.perform(call))
        expect(result["answer"] as? String == "no truncation" && result["truncated"] == nil)
    }
}
