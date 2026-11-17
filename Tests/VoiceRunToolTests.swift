import Foundation

private final class VoiceFixtureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var events: [String] { lock.withLock { values } }
}

private actor VoiceFixtureInbox {
    private var queued: [RealtimeVoice.Event] = []
    private var waiting: CheckedContinuation<RealtimeVoice.Event, Error>?
    private var closed = false

    func push(_ event: RealtimeVoice.Event) {
        guard !closed else { return }
        if let waiting { self.waiting = nil; waiting.resume(returning: event) }
        else { queued.append(event) }
    }

    func next() async throws -> RealtimeVoice.Event {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func close() {
        closed = true
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }
}

private final class VoiceFixtureTransport: RealtimeVoiceTransport, @unchecked Sendable {
    private let inbox = VoiceFixtureInbox()
    private let lock = NSLock()
    private let log: VoiceFixtureLog
    private var sent: [Data] = []
    private var closed = false

    init(log: VoiceFixtureLog) { self.log = log }
    var isClosed: Bool { lock.withLock { closed } }
    var messages: [[String: Any]] {
        lock.withLock { sent }.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
    }
    func close() {
        let first = lock.withLock { let first = !closed; closed = true; return first }
        if first { log.append("socket.close") }
        Task { await inbox.close() }
    }
    func configure(instructions: String, key: String) async throws {
        try await send(RealtimeVoice.update(instructions: instructions))
    }
    func send(_ event: [String: Any]) async throws {
        let bytes = try JSONSerialization.data(withJSONObject: event)
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            sent.append(bytes)
        }
    }
    func receive() async throws -> RealtimeVoice.Event { try await inbox.next() }
    func event(_ value: [String: Any]) async throws {
        let bytes = try JSONSerialization.data(withJSONObject: value)
        try await inbox.push(JSONDecoder().decode(RealtimeVoice.Event.self, from: bytes))
    }
}

@MainActor private final class VoiceFixtureAudio: VoiceAudioIO {
    private let log: VoiceFixtureLog
    private var capture: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var playback: VoiceAudio.Playback?
    private(set) var callbacks: [@Sendable () -> Void] = []
    private(set) var starts = 0
    private(set) var stops = 0
    init(log: VoiceFixtureLog) { self.log = log }
    func start() throws -> AsyncThrowingStream<Data, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        capture = continuation
        return stream
    }
    func stop() {
        stops += 1
        log.append("mic.stop")
        capture?.finish()
        capture = nil
        playback = nil
    }
    func enqueue(_ data: Data, item: String, contentIndex: Int, played: @escaping @Sendable () -> Void) throws {
        precondition(!data.isEmpty && data.count.isMultiple(of: 2))
        if playback?.item != item { playback = .init(item: item, contentIndex: contentIndex) }
        playback?.frames += Int64(data.count / 2)
        callbacks.append(played)
    }
    func interrupt() -> (VoiceAudio.Playback, frames: Int64)? {
        guard let playback else { return nil }
        self.playback = nil
        return (playback, 0)
    }
    func microphone(_ data: Data) { capture?.yield(data) }
    func takeCallback() -> @Sendable () -> Void { callbacks.removeFirst() }
}

@MainActor private final class VoiceFixtureState {
    var saved: [ChatMessage] = []
    var usage: [UsageCounts] = []
    var localFailures = 0
    var connected = false
    var finished = false
}

@MainActor private final class VoiceRunFixture {
    let log = VoiceFixtureLog()
    let state = VoiceFixtureState()
    let audio: VoiceFixtureAudio
    let transport: VoiceFixtureTransport
    let run: VoiceRun
    private(set) var task: Task<Void, Error>?
    init(save: ((ChatMessage) throws -> Void)? = nil) {
        audio = VoiceFixtureAudio(log: log)
        transport = VoiceFixtureTransport(log: log)
        let state = state, log = log, transport = transport
        run = VoiceRun(save: {
                           if let save { try save($0) }
                           else { state.saved.append($0) }
                           log.append("save.\($0.role.rawValue)")
                       },
                       usage: { state.usage.append($0); log.append("usage") },
                       transcriptionFailed: { state.localFailures += 1 }, localFailure: { _ in state.localFailures += 1 },
                       audio: audio, makeConnection: { _, _ in transport })
    }
    func start() async throws {
        let run = run, state = state
        task = Task {
            defer { state.finished = true }
            try await run.run(request: URLRequest(url: URL(string: "https://synthetic.invalid/realtime")!),
                              route: .init(configuration: nil, validate: {}), key: "synthetic-voice-key",
                              instructions: "synthetic voice instructions", history: [.init(role: .user, content: "synthetic history")]) {
                state.connected = true
            }
        }
        try await VoiceRunToolTests.eventually { state.connected }
    }
    func cancel() async throws {
        task?.cancel()
        do { try await result(); preconditionFailure("Manual cancellation unexpectedly succeeded") }
        catch is CancellationError {}
        precondition(audio.stops == 1 && transport.isClosed)
    }
    func result() async throws {
        try await VoiceRunToolTests.eventually { state.finished }
        try await task!.value
    }
    func created(_ id: String) async throws {
        try await transport.event(["type": "response.created", "response": ["id": id, "status": "in_progress"]])
    }
    func done(_ id: String, status: String = "completed", output: [[String: Any]], usage: Int = 12) async throws {
        try await transport.event(["type": "response.done", "response": ["id": id, "status": status, "output": output,
                                      "usage": ["input_tokens": usage, "output_tokens": 7]]])
    }
}

@main @MainActor
struct VoiceRunToolTests {
    static func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Synthetic VoiceRun event processing timed out")
    }
    private static func hangUp(_ callID: String = "call_hang_up", item: String = "fc_hang_up", name: String = "hang_up", arguments: String = "{}") -> [String: Any] {
        ["id": item, "type": "function_call", "status": "completed", "name": name, "call_id": callID, "arguments": arguments]
    }
    private static func message(_ id: String = "msg_goodbye", text: String = "再见，通话结束。") -> [String: Any] {
        ["id": id, "type": "message", "status": "completed", "role": "assistant",
         "content": [["type": "output_audio", "transcript": text]]]
    }
    private static func audio(_ fixture: VoiceRunFixture, item: String = "msg_goodbye") async throws {
        try await fixture.transport.event(["type": "response.output_item.added", "item": message(item)])
        try await fixture.transport.event(["type": "response.output_audio.delta", "item_id": item,
                                            "content_index": 0, "delta": Data([1, 0, 255, 255]).base64EncodedString()])
        try await eventually { !fixture.audio.callbacks.isEmpty }
    }
    static func main() async throws {
        try await completedAfterPlayback()
        try await nonCompletedResponses()
        try await malformedTools()
        try await staleAndDuplicateResponses()
        try await pendingHangUpCanBeInterrupted()
        try await stalePlaybackCannotEndNextRun()
        try await deletionInvalidatesReadyTranscriptFlush()
        try await voiceRecencyFollowsUserCommits()
        print("VoiceRun hang_up: real event path, allowlist/IDs, completed-only execution, playback drain, final transcript/usage ordering, duplicate/stale rejection, interruption and manual cancellation passed using fake transport/audio only.")
    }

    private static func voiceRecencyFollowsUserCommits() async throws {
        for mode in ["stream", "playback", "closing"] {
            let directory = try PrivateTemporaryDirectory()
            let suite = "com.pendingname.aauv.synthetic.voice-recency." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
            precondition(store.loadError == nil)
            let profiles = try [LocalBot(configuration: .init(name: "Voice A", endpoint: "https://voice-a.invalid/v1",
                                      model: "voice-a", loginMethod: .byok, apiProtocol: "responses")),
                                LocalBot(configuration: .init(name: "Chat B", endpoint: "https://chat-b.invalid/v1",
                                      model: "chat-b", loginMethod: .byok, apiProtocol: "responses"))].map { try $0.validated() }
            try store.saveBots(profiles)
            let a = profiles[0].snapshot, b = profiles[1].snapshot
            let voiceID = try store.create(bot: a)
            let voice = try store.beginActivity(.voice, in: voiceID)
            defer { store.endActivity(voice) }
            let captured = store.conversations.first { $0.id == voiceID }!
            let scope = try ConversationVoiceScope(store: store, activity: voice, conversation: captured)
            DefaultBotSelection.remember(b, bots: store.bots, defaults: defaults)
            let fixture = VoiceRunFixture(save: { transcript in
                guard scope.isCurrent else { return }
                try DefaultBotSelection.savingMessage(transcript, with: a, bots: store.bots, defaults: defaults) {
                    try store.append(transcript, to: voiceID)
                }
            })
            try await fixture.start()
            try await fixture.transport.event(["type": "input_audio_buffer.committed", "item_id": "mic_first"])
            try await fixture.transport.event(["type": "conversation.item.input_audio_transcription.completed", "item_id": "mic_first", "transcript": "Voice user A before B"])
            try await eventually { store.conversations.first(where: { $0.id == voiceID })?.messages.count == 1 }
            precondition(DefaultBotSelection.currentBot(bots: store.bots, defaults: defaults) == a,
                         "A real saved VoiceRun user transcript must select A")
            let chatB = Conversation(title: "Concurrent ordinary B", bot: b)
            let bUser = try DefaultBotSelection.savingUserMessage(with: b, bots: store.bots, defaults: defaults) {
                try store.sendFirstMessage("B user committed while A voice is active", files: [], in: chatB)
            }
            let (replyB, _, _, _) = try store.beginReply(in: chatB.id, to: bUser)
            defer { store.endActivity(replyB) }
            precondition(store.activities.count == 2 && store.voiceBusy && scope.isCurrent,
                         "Actual store activities must permit a voice and another chat reply concurrently")
            let recentB = defaults.data(forKey: "recentBot")
            if mode == "closing" {
                try await fixture.transport.event(["type": "input_audio_buffer.committed", "item_id": "mic_unavailable"])
            }
            try await fixture.created("resp_late")
            if mode == "playback" { try await audio(fixture, item: "msg_late") }
            try await fixture.done("resp_late", output: [message("msg_late", text: "Late assistant A " + mode)])
            try await eventually { fixture.state.usage.count == 1 }
            if mode == "playback" { fixture.audio.takeCallback()() }
            if mode == "closing" { try await fixture.cancel() }
            try await eventually { store.conversations.first(where: { $0.id == voiceID })?.messages.count == 2 }
            precondition(defaults.data(forKey: "recentBot") == recentB
                         && DefaultBotSelection.currentBot(bots: store.bots, defaults: defaults) == b,
                         "Late assistant save, playback or closing flush must preserve newer B")
            let reopened = ConversationStore(file: store.file)
            precondition(reopened.loadError == nil
                         && reopened.conversations.first(where: { $0.id == voiceID })?.messages.last?.content == "Late assistant A " + mode,
                         "The assistant transcript must still be persisted")
            if mode != "closing" {
                try await fixture.transport.event(["type": "input_audio_buffer.committed", "item_id": "mic_later"])
                try await fixture.transport.event(["type": "conversation.item.input_audio_transcription.completed", "item_id": "mic_later", "transcript": "A genuinely later saved user turn"])
                try await eventually { store.conversations.first(where: { $0.id == voiceID })?.messages.count == 3 }
                precondition(DefaultBotSelection.currentBot(bots: store.bots, defaults: defaults) == a,
                             "A later actual user commit must still select A")
                try await fixture.cancel()
            }
            precondition(fixture.state.localFailures == 0 && fixture.transport.isClosed && fixture.audio.stops == 1)
        }
        print("Voice recency: real VoiceRun user commits, concurrent chat B, late assistant/played/closing saves, independent SQLite reopen and later user selection passed; fake transport/audio only.")
    }
    // A missing input transcription blocks a later ready assistant turn. The
    // real VoiceRun closing drain attempts to flush it after cancellation.
    private static func deletionInvalidatesReadyTranscriptFlush() async throws {
        for deleteHistory in [false, true] {
            let directory = try PrivateTemporaryDirectory()
            let store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
            let conversationID = try store.create()
            let historical = ChatMessage(role: .user, content: "historical message to delete")
            try store.append(historical, to: conversationID)
            let activity = try store.beginActivity(.voice, in: conversationID)
            let captured = store.conversations.first { $0.id == conversationID }!
            let scope = try ConversationVoiceScope(store: store, activity: activity, conversation: captured)
            var flushAttempts = 0
            var writes = 0
            let fixture = VoiceRunFixture(save: { message in
                flushAttempts += 1
                guard scope.isCurrent else { return }
                try store.append(message, to: conversationID)
                writes += 1
            })
            store.setCancellation(for: activity) { fixture.task?.cancel() }
            try await fixture.start()
            try await fixture.transport.event(["type": "input_audio_buffer.committed", "item_id": "mic_not_transcribed"])
            try await fixture.created("resp_pending_flush")
            try await fixture.done("resp_pending_flush", output: [message("msg_pending_flush", text: "ready final transcript")])
            try await eventually { fixture.state.usage.count == 1 }
            precondition(flushAttempts == 0 && writes == 0, "The fixture must leave a ready turn blocked until close")
            if deleteHistory { try store.deleteMessage(historical.id, in: conversationID) }
            try await fixture.cancel()
            let after = store.conversations.first { $0.id == conversationID }!
            precondition(flushAttempts == 1, "The real VoiceRun closing path must attempt the pending save")
            if deleteHistory {
                precondition(!scope.isCurrent && writes == 0 && after.messages.isEmpty)
                precondition(after.compression == nil && after.historyRevision != nil)
            } else {
                precondition(scope.isCurrent && writes == 1)
                precondition(after.messages.map(\.content) == [historical.content, "ready final transcript"])
            }
            store.endActivity(activity)
        }
    }

    private static func completedAfterPlayback() async throws {
        let fixture = VoiceRunFixture()
        try await fixture.start()
        let session = fixture.transport.messages.first!["session"] as! [String: Any]
        let tools = session["tools"] as! [[String: Any]]
        precondition(tools.count == 1 && tools[0]["name"] as? String == "hang_up" && session["tool_choice"] as? String == "auto")
        let parameters = tools[0]["parameters"] as! [String: Any]
        precondition((parameters["properties"] as! [String: Any]).isEmpty && parameters["additionalProperties"] as? Bool == false)
        precondition(tools[0]["description"] as? String == "Hang up (end) this voice call. Call this when the user asks you to hang up, or when the conversation has clearly finished.")
        try await fixture.transport.event(["type": "input_audio_buffer.committed", "item_id": "mic_goodbye"])
        try await fixture.transport.event(["type": "conversation.item.input_audio_transcription.completed", "item_id": "mic_goodbye", "transcript": "请挂断。"])
        fixture.audio.microphone(Data([0, 0, 1, 0]))
        try await fixture.created("resp_goodbye")
        try await audio(fixture)
        // No separate transcript.done: final response.output is the fallback.
        try await fixture.done("resp_goodbye", output: [message(), hangUp()])
        try await eventually { fixture.state.usage.count == 1 }
        precondition(!fixture.state.finished && !fixture.transport.isClosed && fixture.audio.stops == 0)
        precondition(fixture.state.saved.map(\.content) == ["请挂断。"])
        fixture.audio.takeCallback()()
        try await fixture.result()
        precondition(fixture.state.saved.map(\.content) == ["请挂断。", "再见，通话结束。"])
        precondition(fixture.state.usage.count == 1 && fixture.state.usage[0].input == 12 && fixture.state.localFailures == 0)
        precondition(fixture.audio.stops == 1 && fixture.transport.isClosed)
        let log = fixture.log.events
        precondition(log.firstIndex(of: "usage")! < log.firstIndex(of: "socket.close")!)
        precondition(log.firstIndex(of: "save.assistant")! < log.firstIndex(of: "socket.close")!)
        precondition(fixture.transport.messages.contains { $0["type"] as? String == "input_audio_buffer.append" })
    }
    private static func nonCompletedResponses() async throws {
        for status in ["cancelled", "incomplete", "failed"] {
            let fixture = VoiceRunFixture()
            try await fixture.start()
            try await fixture.created("resp_" + status)
            try await fixture.transport.event(["type": "response.function_call_arguments.done", "response_id": "resp_" + status,
                                                "item_id": "fc_partial", "call_id": "call_partial", "name": "hang_up", "arguments": "{}"])
            try await fixture.done("resp_" + status, status: status, output: [message(), hangUp()])
            try await eventually { fixture.state.usage.count == 1 }
            precondition(fixture.state.saved.isEmpty)
            if status == "failed" {
                do { try await fixture.result(); preconditionFailure("Failed response ended normally") }
                catch let error as ChatClient.ClientError {
                    precondition(error.localizedDescription.contains("未能生成语音回复"))
                }
            } else {
                precondition(!fixture.state.finished && !fixture.transport.isClosed)
                try await fixture.cancel()
            }
        }
    }
    private static func malformedTools() async throws {
        var badStatus = hangUp(); badStatus["status"] = "incomplete"
        var badID = hangUp(); badID["call_id"] = "bad\ncall"
        var badItem = hangUp(); badItem["id"] = "bad item"
        var missing = hangUp(); missing["arguments"] = nil
        for output in [[hangUp(name: "create_skill")], [hangUp(arguments: "{\"extra\":true}")],
                       [hangUp(arguments: "[]")], [hangUp(), hangUp(item: "fc_duplicate")], [badStatus], [badID],
                       [badItem], [message("fc_hang_up"), hangUp()], [missing]] {
            let fixture = VoiceRunFixture()
            try await fixture.start()
            try await fixture.created("resp_invalid")
            try await fixture.done("resp_invalid", output: output)
            do { try await fixture.result(); preconditionFailure("Malformed/unknown voice tool executed") }
            catch let error as ChatClient.ClientError {
                precondition(error.localizedDescription == VoiceToolPolicy.protocolError.localizedDescription)
            }
            precondition(fixture.transport.isClosed && fixture.audio.stops == 1 && fixture.state.saved.isEmpty)
        }
        let unanchored = VoiceRunFixture()
        try await unanchored.start()
        try await unanchored.done("resp_without_creation", output: [hangUp()])
        do { try await unanchored.result(); preconditionFailure("Unanchored tool executed") }
        catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription == VoiceToolPolicy.protocolError.localizedDescription)
        }
    }
    private static func staleAndDuplicateResponses() async throws {
        let fixture = VoiceRunFixture()
        try await fixture.start()
        try await fixture.created("resp_old")
        try await fixture.created("resp_current")
        try await fixture.done("resp_old", output: [hangUp("call_old")])
        try await fixture.done("resp_old", output: [hangUp("call_old")])
        try await fixture.created("resp_old") // Replayed creation cannot become current.
        try await fixture.done("resp_current", status: "cancelled", output: [hangUp("call_current")])
        try await eventually { fixture.state.usage.count == 2 }
        precondition(!fixture.state.finished && !fixture.transport.isClosed)
        // A call ID replayed under another response must fail closed.
        try await fixture.created("resp_replayed_call")
        try await fixture.done("resp_replayed_call", output: [hangUp("call_old", item: "fc_other")])
        do { try await fixture.result(); preconditionFailure("A reused call ID hung up") }
        catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription == VoiceToolPolicy.protocolError.localizedDescription)
        }
        let itemReplay = VoiceRunFixture()
        try await itemReplay.start()
        try await itemReplay.created("resp_old_item")
        try await itemReplay.created("resp_new_item")
        try await itemReplay.done("resp_old_item", output: [hangUp("call_first", item: "fc_replayed")])
        try await itemReplay.done("resp_new_item", output: [hangUp("call_second", item: "fc_replayed")])
        do { try await itemReplay.result(); preconditionFailure("A reused item ID hung up") }
        catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription == VoiceToolPolicy.protocolError.localizedDescription)
        }
    }
    private static func pendingHangUpCanBeInterrupted() async throws {
        for change in ["speech", "new_response"] {
            let fixture = VoiceRunFixture()
            try await fixture.start()
            try await fixture.created("resp_waiting")
            try await audio(fixture)
            try await fixture.done("resp_waiting", output: [message(), hangUp()])
            try await eventually { fixture.state.usage.count == 1 }
            if change == "speech" {
                try await fixture.transport.event(["type": "input_audio_buffer.speech_started"])
                try await eventually { fixture.transport.messages.contains { $0["type"] as? String == "conversation.item.truncate" } }
            } else {
                try await fixture.created("resp_next")
                // A cancelled terminal event is a barrier proving creation was handled.
                try await fixture.done("resp_next", status: "cancelled", output: [])
                try await eventually { fixture.state.usage.count == 2 }
            }
            fixture.audio.takeCallback()()
            await Task.yield()
            precondition(!fixture.state.finished && !fixture.transport.isClosed)
            try await fixture.cancel()
        }
    }
    private static func stalePlaybackCannotEndNextRun() async throws {
        let log = VoiceFixtureLog(), state = VoiceFixtureState()
        let audio = VoiceFixtureAudio(log: log)
        let first = VoiceFixtureTransport(log: log), second = VoiceFixtureTransport(log: log)
        var connections = [first, second]
        let run = VoiceRun(save: { state.saved.append($0) }, usage: { state.usage.append($0) },
                           transcriptionFailed: {}, localFailure: { _ in state.localFailures += 1 }, audio: audio,
                           makeConnection: { _, _ in connections.removeFirst() })
        func start() -> Task<Void, Error> {
            Task {
                try await run.run(request: URLRequest(url: URL(string: "https://synthetic.invalid/realtime")!),
                                  route: .init(configuration: nil, validate: {}), key: "synthetic",
                                  instructions: "", history: []) { state.connected = true }
            }
        }
        let one = start()
        try await eventually { state.connected }
        try await first.event(["type": "response.created", "response": ["id": "resp_reused", "status": "in_progress"]])
        try await first.event(["type": "response.output_audio.delta", "item_id": "msg_reused", "content_index": 0, "delta": "AQD//w=="])
        try await eventually { audio.callbacks.count == 1 }
        let oldCallback = audio.takeCallback()
        one.cancel()
        try await eventually { audio.stops == 1 }
        do { try await one.value; preconditionFailure("Cancelled first run succeeded") } catch is CancellationError {}
        state.connected = false
        let two = start()
        try await eventually { state.connected }
        try await second.event(["type": "response.created", "response": ["id": "resp_reused", "status": "in_progress"]])
        try await second.event(["type": "response.output_audio.delta", "item_id": "msg_reused", "content_index": 0, "delta": "AQD//w=="])
        try await second.event(["type": "response.done", "response": ["id": "resp_reused", "status": "completed",
                                     "output": [message("msg_reused"), hangUp()], "usage": ["input_tokens": 3, "output_tokens": 2]]])
        try await eventually { state.usage.count == 1 && audio.callbacks.count == 1 }
        oldCallback()
        await Task.yield()
        precondition(!second.isClosed && audio.stops == 1)
        audio.takeCallback()()
        try await eventually { audio.stops == 2 }
        try await two.value
        precondition(second.isClosed && audio.stops == 2 && state.saved.map(\.content) == ["再见，通话结束。"])
    }
}
