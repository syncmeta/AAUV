import Foundation

@main
struct FileUploadTests {
    @MainActor
    static func main() async throws {
        let scratch = try PrivateTemporaryDirectory()
        let largeURL = scratch.url.appending(path: "large")
        let imageURL = scratch.url.appending(path: "image")
        let size = 11 * 1024 * 1024
        try Data([0, 42, 255]).write(to: largeURL)
        let handle = try FileHandle(forWritingTo: largeURL)
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: UInt64(size - 2))
        try handle.write(contentsOf: Data([255, 9]))
        try handle.close()
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageURL)
        let files = [
            RequestAttachment(name: "测试\".uncommon", mediaType: "application/octet-stream", url: largeURL, size: size),
            RequestAttachment(name: "image.png", mediaType: "image/png", url: imageURL, size: 4)
        ]
        let root = URL(string: CommandLine.arguments[1])!
        var submitted: Set<String> = []
        var warning = 0
        var delta = ""
        @MainActor func send(_ route: String, attachments: [RequestAttachment] = files,
                             validateCredential: AsyncCredentialCheck? = nil) async throws -> String {
            let config = ChatClient.Configuration(baseURL: root.appending(component: route).appending(component: "v1"),
                                                  model: "test", key: "fixture-key")
            return try await ChatClient.withRequestFiles(attachments, configuration: config, proxy: nil,
                                                         validateCredential: validateCredential,
                                                         onCleanupFailure: { warning += $0 }) { inputs in
                try await ChatClient.reply(to: [.init(role: .user, content: "看看附件")], configuration: config,
                                           proxy: nil, attachments: inputs,
                                           validateCredential: validateCredential,
                                           willSend: { _ = submitted.insert(route) },
                                           onDelta: { delta += $0 })
            }
        }

        let done = try await send("ok")
        precondition(done == "文件已接收" && warning == 0)
        let inline = try await send("inline", attachments: [files[1]])
        precondition(inline == "文件已接收")
        for route in ["mixed-head", "mixed-tail", "expiry", "missing-endpoint"] {
            let result = try await send(route)
            precondition(result == "文件已接收" && warning == 0)
        }
        do {
            _ = try await send("rate-limit")
            fatalError("Provider rejection should fail before model submission")
        } catch ChatClient.ClientError.service(let diagnostic, _) {
            precondition(diagnostic.status == 429 && diagnostic.code == "rate_limit_exceeded")
            precondition(!submitted.contains("rate-limit"))
        }
        do {
            _ = try await send("model-reject")
            fatalError("Responses must surface its own attachment rejection")
        } catch ChatClient.ClientError.service(let diagnostic, _) {
            precondition(diagnostic.status == 400 && diagnostic.code == "invalid_file_type")
            precondition(submitted.contains("model-reject"))
        }
        let warned = try await send("warn")
        precondition(warned == "文件已接收" && warning == 1)
        var credentialChecks = 0
        let guarded = try await send("guard-cleanup", validateCredential: {
            credentialChecks += 1
            if credentialChecks > 3 { throw CocoaError(.userCancelled) }
        })
        precondition(guarded == "文件已接收" && credentialChecks == 4 && warning == 3)
        let task = Task { try await send("cancel") }
        for _ in 0..<250 {
            if delta == "部分" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(delta == "部分")
        task.cancel()
        do {
            _ = try await task.value
            fatalError("Cancelled model request returned success")
        } catch {}
        precondition(submitted == ["ok", "inline", "mixed-head", "mixed-tail", "expiry", "missing-endpoint",
                                   "model-reject", "warn", "guard-cleanup", "cancel"])
        let retained = try largeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(retained == size && (try? Data(contentsOf: imageURL)) == Data([0x89, 0x50, 0x4e, 0x47]))
        print("Multipart upload, ordered inline fallback, preserved diagnostics, cancellation and remote cleanup passed.")
    }
}
