import Foundation

@main @MainActor
struct ResponseToolLoopTests {
    private static func call(_ id: String, name: String = "search_chat_history", namespace: String = "") -> LocalToolCall {
        .init(id: nil, callID: id, name: name, namespace: namespace, arguments: #"{"query":"past"}"#)
    }

    private static func turn(_ text: String, calls: [LocalToolCall] = [], output: String = "[]",
                             files: [ChatClient.GeneratedFiles.File] = []) -> ResponseToolLoop.Turn {
        .init(reply: .init(text: text, citations: text.isEmpty ? [] : [
            .init(url: "https://example.invalid/source", title: "Fixture", start: 0, end: text.unicodeScalars.count)
        ], fileCount: files.count), outputJSON: Data(output.utf8), calls: calls, generated: .init(files: files))
    }

    static func main() async throws {
        try await preserveContinuationAndReply()
        try await rejectRepeatedOrUnallowedCalls()
        try await returnCorrectableErrorsToModel()
        try await preserveFilesWhenContinuationFails()
        try await stopOnCancellationAndBudgets()
        try await retainPostedImagesOnCancellation()
        try await rejectStalePostedImages()
        try await attachmentOnlyFinal()
        print("Response tool loop preserved opaque continuation, file budgets and citations; rejected stale namespaces/repeated calls before side effects; returned tool errors for correction and retained completed files on later failure.")
    }

    private static func attachmentOnlyFinal() async throws {
        var sends = 0
        var replies = 0
        var files: ChatClient.GeneratedFiles?
        let result = try await ResponseToolLoop.run(execution: .init(names: ["search_chat_history"], namespace: "", perform: { _ in "{}" }), send: { state in
            sends += 1
            if sends == 1 {
                precondition(!state.allowEmptyFinalReply)
                // A completed hosted-tool file can coexist with a local call.
                return turn("", calls: [call("hosted_file_followup")], files: [.init(name: "complete.bin", data: Data([1, 2]))])
            }
            precondition(state.allowEmptyFinalReply)
            return turn("")
        }, onReplyReady: { reply in replies += 1; precondition(reply.text.isEmpty && reply.fileCount == 1) },
           onGeneratedFiles: { files = $0 })
        precondition(result.isEmpty && sends == 2 && replies == 1 && files?.files.count == 1)
        do {
            _ = try await ResponseToolLoop.run(execution: .init(names: ["send_images"], namespace: "", perform: { _ in "{}" }),
                                               send: { state in
                precondition(!state.allowEmptyFinalReply)
                return turn("")
            })
            preconditionFailure("A plain empty final returned success")
        } catch is ChatClient.ClientError {}
    }

    private static func preserveContinuationAndReply() async throws {
        let opaque = #"[{ "type":"reasoning", "encrypted_content":"opaque", "number": 9007199254740993 },{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"查证"}]},{"type":"function_call","call_id":"call_one","name":"search_chat_history","arguments":"{}"}]"#
        var sends = 0
        var performed = 0
        var saved: ChatClient.CompletedReply?
        var files: ChatClient.GeneratedFiles?
        let execution = LocalToolExecution(names: ["search_chat_history"], namespace: "") { invocation in
            precondition(invocation.callID == "call_one")
            performed += 1
            return #"{"results":[{"content":"record"}]}"#
        }
        let result = try await ResponseToolLoop.run(execution: execution, send: { state in
            sends += 1
            if sends == 1 {
                precondition(state.usedCallIDs.isEmpty && state.remainingFileCount == 32)
                return turn("查证", calls: [call("call_one")], output: opaque,
                            files: [.init(name: "already-complete.bin", data: Data([1]))])
            }
            let history = String(decoding: state.continuation, as: UTF8.self)
            precondition(history.contains(#""number": 9007199254740993"#) && history.contains(#""phase":"commentary""#))
            precondition(history.contains(#""encrypted_content":"opaque""#) && history.contains("function_call_output"))
            precondition(state.usedCallIDs == ["call_one"] && state.remainingFileCount == 31)
            precondition(state.remainingFileBytes == 32 * 1024 * 1024 - 1)
            return turn("结果")
        }, onReplyReady: { saved = $0 }, onGeneratedFiles: { files = $0 })
        precondition(result == "查证\n\n结果" && saved?.text == result && sends == 2 && performed == 1)
        precondition(saved?.citations.count == 2 && saved?.citations.last?.start == 4 && saved?.citations.last?.end == 6)
        precondition(saved?.fileCount == 1 && files?.files.first?.data == Data([1]))
    }

    private static func rejectRepeatedOrUnallowedCalls() async throws {
        for invalid in [call("call_one"), call("call_other", name: "execute_code"), call("call_other", namespace: "aauv")] {
            var sends = 0
            var performed = 0
            let execution = LocalToolExecution(names: ["search_chat_history"], namespace: "") { _ in
                performed += 1
                return "{}"
            }
            do {
                _ = try await ResponseToolLoop.run(execution: execution, send: { _ in
                    sends += 1
                    return turn("", calls: sends == 1 ? [call("call_one")] : [invalid])
                })
                fatalError("A repeated or unallowed tool executed")
            } catch is ChatClient.ClientError {
                precondition(sends == 2 && performed == 1)
            }
        }
        var performed = false
        do {
            _ = try await ResponseToolLoop.run(execution: .init(names: ["search_chat_history"], namespace: "", perform: { _ in
                performed = true
                return "{}"
            }), send: { _ in turn("", calls: [call("valid"), call("bad", name: "shell")]) })
            fatalError("A partly invalid batch executed")
        } catch is ChatClient.ClientError { precondition(!performed) }
    }

    private static func returnCorrectableErrorsToModel() async throws {
        var sends = 0
        var performed = 0
        let result = try await ResponseToolLoop.run(execution: .init(names: ["search_chat_history"], namespace: "", perform: { _ in
            performed += 1
            return performed == 1 ? #"{"error":"choose a query"}"# : #"{"results":[]}"#
        }), send: { state in
            sends += 1
            if sends == 1 { return turn("", calls: [call("call_first")]) }
            if sends == 2 {
                precondition(String(decoding: state.continuation, as: UTF8.self).contains("choose a query"))
                return turn("", calls: [call("call_fixed")])
            }
            precondition(Set(state.usedCallIDs) == ["call_first", "call_fixed"])
            return turn("No records")
        })
        precondition(sends == 3 && performed == 2 && result == "No records")
    }

    private static func preserveFilesWhenContinuationFails() async throws {
        var sends = 0
        var reply: ChatClient.CompletedReply?
        var files: ChatClient.GeneratedFiles?
        do {
            _ = try await ResponseToolLoop.run(execution: .init(names: ["search_chat_history"], namespace: "", perform: { _ in "{}" }),
                                               send: { _ in
                sends += 1
                if sends == 1 {
                    return turn("已生成", calls: [call("call_one")],
                                files: [.init(name: "complete.bin", data: Data([0, 255]))])
                }
                throw URLError(.networkConnectionLost)
            }, onReplyReady: { reply = $0 }, onGeneratedFiles: { files = $0 })
            fatalError("A failed continuation returned success")
        } catch is URLError {
            precondition(reply?.text == "已生成" && reply?.fileCount == 1 && files?.files.first?.data == Data([0, 255]))
        }
    }

    private static func stopOnCancellationAndBudgets() async throws {
        let cancelled = Task { @MainActor in
            var sends = 0
            do {
                _ = try await ResponseToolLoop.run(execution: .init(names: ["search_chat_history"], namespace: "", perform: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "{}"
                }), send: { _ in sends += 1; return turn("", calls: [call("call_one")]) })
                fatalError("A cancelled tool sent another request")
            } catch is CancellationError { precondition(sends == 1) }
        }
        try await cancelled.value
        for limits in [ResponseToolLoop.Limits(rounds: 1), ResponseToolLoop.Limits(resultBytes: 1),
                       ResponseToolLoop.Limits(continuationBytes: 1)] {
            var sends = 0
            do {
                _ = try await ResponseToolLoop.run(execution: .init(names: ["search_chat_history"], namespace: "", perform: { _ in "{}" }),
                                                   limits: limits, send: { _ in
                    sends += 1
                    return turn("", calls: [call("call_one")])
                })
                fatalError("A tool loop ignored its budget")
            } catch is ChatClient.ClientError { precondition(sends == 1) }
        }
    }

    private static func retainPostedImagesOnCancellation() async throws {
        let task = Task { @MainActor in
            var buffered = ChatClient.GeneratedFiles()
            var saved: ChatClient.GeneratedFiles?
            var sends = 0
            var replies = 0
            let execution = LocalToolExecution(names: ["send_images"], namespace: "", drainGenerated: {
                let value = buffered
                buffered = .init()
                return value
            }, perform: { _ in
                buffered.files = [.init(name: "finished.png", data: Data([0, 255]))]
                withUnsafeCurrentTask { $0?.cancel() }
                return #"{"sent":1,"cancelled":true}"#
            })
            do {
                _ = try await ResponseToolLoop.run(execution: execution, send: { _ in
                    sends += 1
                    return turn("", calls: [call("image_one", name: "send_images")])
                }, onReplyReady: { reply in replies += 1; precondition(reply.fileCount == 1) },
                   onGeneratedFiles: { saved = $0 })
                fatalError("Cancelled posted image sent another cloud request")
            } catch is CancellationError {
                precondition(sends == 1 && replies == 1 && saved?.files.first?.data == Data([0, 255]))
            }
        }
        try await task.value
    }

    private static func rejectStalePostedImages() async throws {
        struct Stale: Error {}
        var stale = false
        var delivered = false
        var drained = false
        let execution = LocalToolExecution(names: ["send_images"], namespace: "", validate: {
            if stale { throw Stale() }
        }, drainGenerated: {
            drained = true
            return .init(files: [.init(name: "wrong-chat.png", data: Data([1]))])
        }, perform: { _ in stale = true; return "{}" })
        do {
            _ = try await ResponseToolLoop.run(execution: execution, send: { _ in
                turn("", calls: [call("image_one", name: "send_images")])
            }, onReplyReady: { _ in delivered = true }, onGeneratedFiles: { _ in delivered = true })
            fatalError("Stale image result delivered")
        } catch is Stale { precondition(!delivered && !drained) }
    }
}
