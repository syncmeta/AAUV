import Foundation

@main
struct TransportCredentialTests {
    private enum Blocked: Error { case credential, unexpectedSubmission }

    @MainActor static func main() async throws {
        let configuration = ChatClient.Configuration(baseURL: URL(string: "http://127.0.0.1:1/v1")!,
                                                     model: "fixture", key: "synthetic-only", apiProtocol: "responses")
        var guardCalls = 0
        var submitted = false
        do {
            _ = try await ChatClient.reply(to: [.init(role: .user, content: "synthetic")],
                                           configuration: configuration, proxy: nil,
                                           validateCredential: {
                                               guardCalls += 1
                                               throw Blocked.credential
                                           }, willSend: {
                                               submitted = true
                                               throw Blocked.unexpectedSubmission
                                           })
            preconditionFailure("A rejected credential reached the model request.")
        } catch Blocked.credential {}
        precondition(guardCalls == 1 && !submitted)

        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let waiting = Task {
            try await ChatClient.reply(to: [.init(role: .user, content: "synthetic")],
                                       configuration: configuration, proxy: nil,
                                       validateCredential: {
                                           started.continuation.yield(())
                                           for await _ in gate.stream { break }
                                       }, willSend: {
                                           submitted = true
                                           throw Blocked.unexpectedSubmission
                                       })
        }
        for await _ in started.stream.prefix(1) {}
        waiting.cancel()
        gate.continuation.yield(())
        do { _ = try await waiting.value; preconditionFailure("Cancelled credential wait reached submission.") }
        catch is CancellationError {}
        precondition(!submitted)

        let directory = try PrivateTemporaryDirectory()
        let url = directory.url.appending(path: "synthetic.bin")
        precondition(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        let size = 11 * 1024 * 1024
        try writer.truncate(atOffset: UInt64(size))
        try writer.close()
        let file = RequestAttachment(name: "synthetic.bin", mediaType: "application/octet-stream", url: url, size: size)
        do {
            let _: String = try await ChatClient.withRequestFiles(
                [file], configuration: configuration, proxy: nil,
                validateCredential: { guardCalls += 1; throw Blocked.credential }, onCleanupFailure: nil
            ) { _ in
                throw Blocked.unexpectedSubmission
            }
            preconditionFailure("A rejected credential reached file upload.")
        } catch Blocked.credential {}
        precondition(guardCalls == 2)
        print("Async credential guards blocked model and upload submission and discarded cancellation while awaiting validation.")
    }
}
