import Foundation

@main @MainActor
struct CopilotLocalToolsTests {
    private enum Rejected: Error { case stale, operation }
    private static let names = ["search_chat_history", "create_skill", "read_attachment", "send_images", "delegate_to_specialist"]
    static func main() async throws {
        var active = 0
        var maximumActive = 0
        var calls: [LocalToolCall] = []
        let execution = LocalToolExecution(names: names, namespace: "", perform: { call in
            precondition(Thread.isMainThread && call.namespace.isEmpty)
            active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            calls.append(call)
            try await Task.sleep(for: .milliseconds(call.name == "delegate_to_specialist" ? 60 : 15))
            return "synthetic-result"
        })
        let result = try await reply("swift-tools", execution)
        precondition(result == "tools complete" && calls.count == 6 && maximumActive > 1)
        precondition(Set(calls.map(\.callID)).count == 6 && Set(calls.map(\.name)) == Set(names))
        let images = calls.first(where: { $0.name == "send_images" })!
        precondition(images.arguments.contains("https:") && images.arguments.contains("synthetic.png"))

        let failed = try await reply("swift-error", .init(names: names, namespace: "", perform: { _ in throw Rejected.operation }))
        precondition(failed == "error handled")

        var allowed = true
        do {
            _ = try await reply("swift-stale", .init(names: names, namespace: "", validate: {
                if !allowed { throw Rejected.stale }
            }, perform: { _ in allowed = false; return "synthetic-result" }))
            preconditionFailure("A changed scope published a tool result.")
        } catch Rejected.stale {}

        do {
            _ = try await reply("swift-stale", .init(names: names, namespace: "", perform: { _ in
                throw LocalCloudTools.ScopeError.staleScope
            }))
            preconditionFailure("A stale specialist scope became a recoverable tool error.")
        } catch LocalCloudTools.ScopeError.staleScope {}

        var toolCancelled = false
        let cancelled = try await reply("swift-cancel-tool", .init(names: names, namespace: "", perform: { _ in
            do { try await Task.sleep(for: .seconds(20)) }
            catch { toolCancelled = true; throw error }
            preconditionFailure("Cancelled tool continued to completion.")
        }))
        precondition(cancelled == "cancel complete" && toolCancelled)

        let started = AsyncStream<Void>.makeStream()
        var parentCancelled = false
        let task = Task {
            try await reply("swift-parent-cancel", .init(names: names, namespace: "", perform: { _ in
                started.continuation.yield(())
                do { try await Task.sleep(for: .seconds(20)) }
                catch { parentCancelled = true; throw error }
                preconditionFailure("Cancelled parent tool continued.")
            }))
        }
        for await _ in started.stream.prefix(1) {}
        let stoppedAt = Date()
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled bridge returned success.") }
        catch is CancellationError {}
        precondition(parentCancelled && Date().timeIntervalSince(stoppedAt) < 3)
        try await imageOnlyFinals()
        print("Copilot v2 shared schemas, concurrent/multi-round tools, fixed errors, scope checks, runtime tool cancellation and parent pipe shutdown passed with the real Go bridge and fake runtime.")
    }
    private static func imageOnlyFinals() async throws {
        for mode in ["image-only", "ordinary-empty", "image-claim", "image-eof", "image-cancelled", "image-no-message", "image-stale"] {
            var generated = ChatClient.GeneratedFiles()
            var valid = true
            var performed = 0
            let execution = LocalToolExecution(names: names, namespace: "", validate: {
                if !valid { throw Rejected.stale }
            }, drainGenerated: { let value = generated; generated = .init(); return value },
               hasGeneratedFiles: { !generated.files.isEmpty }, perform: { call in
                precondition(call.name == "send_images")
                performed += 1
                if mode != "image-claim" {
                    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
                    generated.files = [.init(name: "synthetic.png", data: png)]
                }
                if mode == "image-stale" { valid = false }
                return #"{"ok":true,"sent":1}"#
            })
            do {
                let answer = try await reply(mode, execution)
                precondition(mode == "image-only" && answer.isEmpty && performed == 1)
                precondition(execution.hasGeneratedFiles() && execution.drainGenerated().files.count == 1)
            } catch {
                precondition(mode != "image-only", "A successful image-only SDK final was rejected")
                if mode == "image-stale" { precondition(error is Rejected) }
            }
        }
    }
    private static func reply(_ model: String, _ execution: LocalToolExecution) async throws -> String {
        try await CopilotClient.reply(to: [.init(role: .user, content: "normal")], model: model,
                                      instructions: "", token: "gho_synthetic-only", proxyURL: nil,
                                      localExecution: execution)
    }
}
