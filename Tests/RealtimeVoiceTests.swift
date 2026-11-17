import Foundation

@main
struct RealtimeVoiceTests {
    static func main() async throws {
        let base = try ChatClient.baseURL("https://provider.example/gateway/v1/")
        let request = try RealtimeVoice.request(base: base, model: "custom&voice", key: "sample-key")
        precondition(request.url?.absoluteString == "wss://provider.example/gateway/v1/realtime?model=custom%26voice")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer sample-key")
        precondition(RealtimeVoice.truncate(item: "reply", contentIndex: 0, frames: 30_000)["audio_end_ms"] as? Int64 == 1250)

        let data = Data(#"{"endpoint":"https://provider.example/v1","model":"text","version":3,"realtimeModel":" custom-voice "}"#.utf8)
        let settings = try JSONDecoder().decode(PortableSettings.self, from: data).validated()
        precondition(settings.realtimeModel == "custom-voice")

        var transcripts = VoiceTranscripts()
        var saved: [ChatMessage] = []
        transcripts.start("mic-1", role: .user)
        transcripts.start("reply-1", role: .assistant)
        transcripts.transcribe("reply-1", text: "这是第一条回复。")
        transcripts.finish("reply-1", keep: true)
        transcripts.drain { saved.append($0) }
        precondition(saved.isEmpty, "Wait for late user transcription")
        transcripts.transcribe("mic-1", text: "这是第一条消息。")
        transcripts.drain { saved.append($0) }
        precondition(saved.map(\.role) == [.user, .assistant])
        precondition(saved.map(\.content) == ["这是第一条消息。", "这是第一条回复。"])

        transcripts.start("mic-2", role: .user)
        transcripts.start("reply-2", role: .assistant)
        transcripts.transcribe("reply-2", text: "这段没有播完。")
        transcripts.finish("reply-2", keep: false)
        transcripts.transcribe("mic-2", text: "等一下。")
        transcripts.drain { saved.append($0) }
        precondition(saved.count == 3 && saved.last?.content == "等一下。")

        guard let port = ProcessInfo.processInfo.environment["AAUV_VOICE_FIXTURE_PORT"] else {
            print("Realtime wire and ordered transcript checks passed.")
            return
        }
        let fixture = try ChatClient.baseURL("http://127.0.0.1:\(port)/v1")
        let fixtureRequest = try RealtimeVoice.request(base: fixture, model: "test-model", key: "fixture-key")
        let socket = RealtimeVoice.Connection(request: fixtureRequest, proxy: nil)
        defer { socket.close() }
        try await socket.configure(instructions: "Local prompt", key: "fixture-key")
        try await socket.send(RealtimeVoice.history(.init(role: .assistant, content: "Previous reply")))
        try await socket.send(["type": "input_audio_buffer.append", "audio": "AAABAA=="])
        let audio = try await socket.receive()
        precondition(audio.type == "response.output_audio.delta" && audio.content_index == 0)
        let pcm = audio.delta.flatMap { Data(base64Encoded: $0) }
        precondition(pcm == Data([1, 0, 255, 255]))
        try await socket.send(RealtimeVoice.truncate(item: audio.item_id!, contentIndex: 0, frames: 30_000))
        let result = try await socket.receive()
        precondition(result.response?.status == "cancelled" && result.response?.usage?.input == 12)
        let error = try await socket.receive()
        precondition(error.type == "error" && !error.failure(redacting: "fixture-key").localizedDescription.contains("fixture-key"))
        print("Realtime WebSocket and ordered transcript checks passed.")
    }
}
