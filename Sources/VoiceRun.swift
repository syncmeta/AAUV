import Foundation
import Network

@MainActor protocol VoiceAudioIO: AnyObject {
    var playback: VoiceAudio.Playback? { get }
    func start() throws -> AsyncThrowingStream<Data, Error>
    func stop()
    func enqueue(_ data: Data, item: String, contentIndex: Int, played: @escaping @Sendable () -> Void) throws
    func interrupt() -> (VoiceAudio.Playback, frames: Int64)?
}

extension VoiceAudio: VoiceAudioIO {}

@MainActor
final class VoiceRun {
    typealias ConnectionFactory = @MainActor (URLRequest, ProxyRequestRoute) -> any RealtimeVoiceTransport
    private static var running = false
    private let audio: any VoiceAudioIO
    private let makeConnection: ConnectionFactory
    private let save: (ChatMessage) throws -> Void
    private let usage: (UsageCounts) throws -> Void
    private let transcriptionFailed: () -> Void
    private let localFailure: (Error) -> Void
    private var transcripts = VoiceTranscripts()
    private var queued: [String: Int] = [:]
    private var completed: Set<String> = []
    private var interrupted: String?
    private var toolPolicy = VoiceToolPolicy()
    private var runID: UUID?
    private var ending = false
    private var hangUpSignal: AsyncStream<Void>.Continuation?

    init(save: @escaping (ChatMessage) throws -> Void, usage: @escaping (UsageCounts) throws -> Void,
         transcriptionFailed: @escaping () -> Void, localFailure: @escaping (Error) -> Void,
         audio: (any VoiceAudioIO)? = nil,
         makeConnection: @escaping ConnectionFactory = { request, route in
             RealtimeVoice.Connection(request: request, proxy: route.configuration, validateRoute: route.validate)
         }) {
        self.save = save
        self.usage = usage
        self.transcriptionFailed = transcriptionFailed
        self.localFailure = localFailure
        self.audio = audio ?? VoiceAudio()
        self.makeConnection = makeConnection
    }

    func run(request: URLRequest, route: ProxyRequestRoute, key: String, instructions: String,
             history: [ChatMessage], connected: () -> Void) async throws {
        guard !Self.running else { throw ChatClient.ClientError.message("已有一通语音正在进行。") }
        try route.validate()
        Self.running = true
        let runID = UUID()
        self.runID = runID
        transcripts = VoiceTranscripts()
        queued = [:]
        completed = []
        interrupted = nil
        toolPolicy = VoiceToolPolicy()
        ending = false
        let (hangUpFinished, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        hangUpSignal = signal
        let connection = makeConnection(request, route)
        defer {
            self.runID = nil
            hangUpSignal?.finish()
            hangUpSignal = nil
            connection.close()
            audio.stop()
            do { try transcripts.drain(closing: true, save: save) }
            catch { localFailure(error) }
            Self.running = false
        }
        try await withTaskCancellationHandler {
            try await connection.configure(instructions: instructions, key: key)
            for message in history where !message.content.isEmpty {
                try Task.checkCancellation()
                try await connection.send(RealtimeVoice.history(message))
            }
            try Task.checkCancellation()
            let capture = try audio.start()
            connected()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await data in capture {
                        try Task.checkCancellation()
                        try await connection.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        let event = try await connection.receive()
                        try await self.handle(event, connection: connection, key: key, runID: runID)
                        if await self.ending { return }
                    }
                }
                group.addTask {
                    for await _ in hangUpFinished { return }
                    try Task.checkCancellation()
                }
                defer { connection.close(); group.cancelAll() }
                try await group.next()
            }
            try Task.checkCancellation()
        } onCancel: {
            connection.close()
        }
    }

    private func handle(_ event: RealtimeVoice.Event, connection: any RealtimeVoiceTransport, key: String, runID: UUID) async throws {
        try Task.checkCancellation()
        guard self.runID == runID, !ending else { return }
        switch event.type {
        case "error":
            throw event.failure(redacting: key)
        case "input_audio_buffer.committed":
            if let id = event.item_id { transcripts.start(id, role: .user) }
        case "conversation.item.input_audio_transcription.completed":
            if let id = event.item_id, let transcript = event.transcript {
                transcripts.transcribe(id, text: transcript)
            }
        case "conversation.item.input_audio_transcription.failed":
            if let id = event.item_id { transcripts.finish(id, keep: false) }
            transcriptionFailed()
        case "response.output_item.added":
            if let item = event.item, item.role == "assistant" { transcripts.start(item.id, role: .assistant) }
        case "response.created":
            try toolPolicy.responseCreated(event.response?.id)
        case "response.output_audio.delta":
            guard let id = event.item_id, id != interrupted else { break }
            guard let index = event.content_index, let delta = event.delta, let data = Data(base64Encoded: delta) else {
                throw ChatClient.ClientError.message("服务商返回了无效的语音音频。")
            }
            if let playing = audio.playback, playing.item != id, queued[playing.item] != nil {
                discard(playing.item)
            }
            queued[id, default: 0] += 1
            try audio.enqueue(data, item: id, contentIndex: index) { [weak self] in
                Task { @MainActor in self?.played(id, runID: runID) }
            }
        case "input_audio_buffer.speech_started":
            toolPolicy.interrupt()
            if let (playback, position) = audio.interrupt() {
                if position >= playback.frames && completed.contains(playback.item) {
                    queued[playback.item] = nil
                    transcripts.finish(playback.item, keep: true)
                } else {
                    interrupted = playback.item
                    discard(playback.item)
                    try await connection.send(RealtimeVoice.truncate(item: playback.item,
                                                                     contentIndex: playback.contentIndex, frames: position))
                }
            }
        case "response.output_audio_transcript.done":
            if let id = event.item_id, let text = event.transcript, id != interrupted {
                transcripts.transcribe(id, text: text)
            }
        case "response.done":
            if let response = event.response {
                guard try toolPolicy.responseDone(response) else { break }
                if let counts = response.usage {
                    do { try usage(counts) }
                    catch { localFailure(error) }
                }
                for item in response.output ?? [] where item.role == "assistant" {
                    if response.status == "completed", item.id != interrupted {
                        transcripts.start(item.id, role: .assistant)
                        if let text = item.finalTranscript { transcripts.transcribe(item.id, text: text) }
                        if queued[item.id] == nil { transcripts.finish(item.id, keep: true) }
                        completed.insert(item.id)
                    } else { discard(item.id) }
                }
                // Completed audio IDs are only needed while queued or retained by the playback clock.
                let retained = audio.playback?.item
                completed = completed.filter { queued[$0] != nil || $0 == retained }
                if response.status == "failed" {
                    throw ChatClient.ClientError.message("服务商未能生成语音回复。")
                }
            }
        default:
            break
        }
        try transcripts.drain(save: save)
        finishHangUpIfReady()
    }

    private func discard(_ id: String) {
        queued[id] = nil
        completed.remove(id)
        transcripts.finish(id, keep: false)
    }

    private func played(_ id: String, runID: UUID) {
        guard self.runID == runID, !ending else { return }
        guard let count = queued[id] else { return }
        if count > 1 {
            queued[id] = count - 1
        } else {
            queued[id] = nil
            if completed.contains(id) {
                transcripts.finish(id, keep: true)
                do { try transcripts.drain(save: save) }
                catch { localFailure(error) }
            }
        }
        finishHangUpIfReady()
    }

    private func finishHangUpIfReady() {
        guard runID != nil, !ending, toolPolicy.pendingHangUp != nil, queued.isEmpty else { return }
        // Real .dataPlayedBack completions empty the queue. Persist ready final
        // transcripts (including those behind an unavailable user transcript)
        // before the normal run exit closes the socket and stops the microphone.
        do { try transcripts.drain(closing: true, save: save) }
        catch { localFailure(error) }
        ending = true
        hangUpSignal?.yield(())
    }
}
