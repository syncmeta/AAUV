import AVFoundation

@MainActor
final class VoiceAudio {
    struct Playback {
        let item: String
        let contentIndex: Int
        var frames: Int64 = 0
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RealtimeVoice.sampleRate),
                                     channels: 1, interleaved: true)!
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(RealtimeVoice.sampleRate),
                                       channels: 1, interleaved: false)!
    private var capture: AsyncThrowingStream<Data, Error>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private(set) var playback: Playback?
    #if os(iOS)
    private var sessionActive = false
    #endif

    static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    func start() throws -> AsyncThrowingStream<Data, Error> {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        sessionActive = true
        #endif

        let input = engine.inputNode
        // Voice processing couples both I/O nodes and applies echo cancellation.
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: wire) else {
            throw ChatClient.ClientError.message("无法初始化麦克风。")
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(24))
        capture = continuation
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            do {
                guard let data = try Self.encode(buffer, converter: converter) else { return }
                if case .dropped = continuation.yield(data) {
                    continuation.finish(throwing: ChatClient.ClientError.message("网络传输跟不上麦克风，请重新连接。"))
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        engine.prepare()
        try engine.start()
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            continuation.finish(throwing: ChatClient.ClientError.message("音频设备已切换，请重新连接语音。"))
        })
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { notice in
            if notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                continuation.finish(throwing: ChatClient.ClientError.message("系统中断了音频，请重新连接语音。"))
            }
        })
        #endif
        return stream
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let capture {
            capture.finish()
            self.capture = nil
            engine.inputNode.removeTap(onBus: 0)
        }
        player.stop()
        engine.stop()
        playback = nil
        #if os(iOS)
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
        #endif
    }

    func enqueue(_ data: Data, item: String, contentIndex: Int, played: @escaping @Sendable () -> Void) throws {
        guard !data.isEmpty, data.count.isMultiple(of: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let channel = buffer.floatChannelData?[0] else {
            throw ChatClient.ClientError.message("服务商返回了无效的语音音频。")
        }
        if playback?.item != item {
            // Server VAD orders responses, but a provider can begin another before local playback finishes.
            player.stop()
            playback = Playback(item: item, contentIndex: contentIndex)
        }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            for frame in 0..<Int(buffer.frameLength) {
                let raw = bytes.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self)
                channel[frame] = Float(Int16(littleEndian: raw)) / 32_768
            }
        }
        playback?.frames += Int64(buffer.frameLength)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
        if !player.isPlaying { player.play() }
    }

    func interrupt() -> (Playback, frames: Int64)? {
        guard let playback else { return nil }
        let position = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
        player.stop()
        self.playback = nil
        return (playback, min(max(position, 0), playback.frames))
    }

    private nonisolated static func encode(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) throws -> Data? {
        let format = converter.outputFormat
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 8
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ChatClient.ClientError.message("无法转换麦克风音频。")
        }
        var fed = false
        var failure: NSError?
        let status = converter.convert(to: pcm, error: &failure) { _, outputStatus in
            outputStatus.pointee = fed ? .noDataNow : .haveData
            guard !fed else { return nil }
            fed = true
            return buffer
        }
        if status == .error { throw failure ?? CocoaError(.fileReadCorruptFile) }
        guard pcm.frameLength > 0, let channel = pcm.int16ChannelData?[0] else { return nil }
        return Data(bytes: channel, count: Int(pcm.frameLength) * 2)
    }
}
