import SwiftUI

struct VoiceCallView: View {
    let conversationID: UUID
    let bot: BotSnapshot
    let store: ConversationStore
    let proxy: SingBox

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("realtimeModel") private var model = RealtimeVoice.defaultModel
    @State private var task: Task<Void, Never>?
    @State private var connected = false
    @State private var failure: String?
    @State private var transcriptionFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("语音服务") {
                    TextField("Realtime 模型", text: $model)
                        .autocorrectionDisabled()
                        .disabled(task != nil)
                    Text("语音通过此机器人的 BYOK 地址和凭证发送。转写保存到当前对话并遵循其同步设置。")
                        .font(.footnote)
                }
                if let failure { Text(failure).foregroundStyle(Theme.Palette.danger) }
                if transcriptionFailed {
                    Text("服务商未能转写部分语音。").foregroundStyle(Theme.Palette.inkMuted)
                }
                if task == nil {
                    Button("开始语音", systemImage: "mic.fill", action: start)
                        .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  store.activities[conversationID] != nil || store.voiceBusy ||
                                  store.configurationUnavailable)
                } else {
                    LabeledContent(connected ? "语音已连接" : "准备连接") {
                        if !connected { ProgressView().controlSize(.small) }
                    }
                    Button("结束语音", systemImage: "phone.down.fill", role: .destructive) {
                        task?.cancel()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("语音")
            .toolbar { Button("关闭") { task?.cancel(); dismiss() } }
        }
        .interactiveDismissDisabled(task != nil)
        .onDisappear { task?.cancel() }
        .onChange(of: scenePhase) { if scenePhase == .background { task?.cancel() } }
        #if os(macOS)
        .frame(width: 440, height: 320)
        #endif
    }

    private func start() {
        guard task == nil, !store.configurationUnavailable else { return }
        failure = nil
        transcriptionFailed = false
        let activity: ConversationStore.Activity
        do { activity = try store.beginActivity(.voice, in: conversationID) }
        catch { failure = error.localizedDescription; return }
        let runTask = Task { @MainActor in
            defer {
                store.endActivity(activity)
                task = nil
                connected = false
            }
            do {
                try Task.checkCancellation()
                let model = try RealtimeVoice.modelName(model)
                guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else {
                    throw ChatClient.ClientError.message("当前对话已删除。")
                }
                let bot = conversation.bot ?? self.bot
                let voiceScope = try ConversationVoiceScope(store: store, activity: activity, conversation: conversation)
                guard bot.loginMethod == .byok else {
                    throw ChatClient.ClientError.message("当前会话须使用 BYOK 机器人才能通话。")
                }
                guard await VoiceAudio.requestPermission() else {
                    throw ChatClient.ClientError.message("请在系统设置允许 AAUV 使用麦克风。")
                }
                try Task.checkCancellation()
                let base = try ChatClient.baseURL(bot.endpoint)
                let capturedRoute = try proxy.requestRoute()
                let credentials = try await RequestCredentials.read(for: base, validateRoute: capturedRoute.validate)
                let key = credentials.key
                let request = try RealtimeVoice.request(base: base, model: model, key: key)
                let route = ProxyRequestRoute(configuration: capturedRoute.configuration, validate: {
                    try credentials.validate()
                    try voiceScope.validate()
                })
                let runtime = try RuntimePrompt(botName: bot.name)
                let instructions = [
                    runtime.instructions,
                    try store.readInstructions().requestInstructions,
                    bot.instructions?.requestInstructions ?? ""
                ].filter { !$0.isEmpty }.joined(separator: "\n\n")
                let scope = try ContextWindow.checkpointScope(bot: bot, target: "voice")
                let originalHistory = conversation.contextMessages()
                let prepared = try await ContextWindow.prepare(
                    originalHistory, now: Date(), cached: conversation.compression, policy: ContextPolicy.load(),
                    checkpointScope: scope, saveCheckpoint: {
                        try voiceScope.validate()
                        try store.saveCompressionCheckpoint($0, to: conversationID)
                    }
                ) { prompt in
                    try route.validate()
                    let text = try await ModelSession(bot: bot, instructions: "", proxy: proxy)
                    return try await text.reply(to: [.init(role: .user, content: prompt)], forSummary: true,
                                                willSend: { try voiceScope.validate() }, onUsage: { usage in
                        do { try store.recordUsage(usage, provider: .byok, model: bot.model, purpose: .compression) }
                        catch { failure = "无法保存历史压缩用量。" }
                    })
                }
                try Task.checkCancellation()
                try voiceScope.validate()
                try store.saveCompression(prepared.compression, to: conversation.id)
                let run = VoiceRun(
                    save: { message in
                        guard voiceScope.isCurrent else { return }
                        try DefaultBotSelection.savingMessage(message, with: bot, bots: store.bots) {
                            try store.append(message, to: conversationID)
                        }
                    },
                    usage: { try store.recordUsage($0, provider: .byok, model: model, purpose: .reply) },
                    transcriptionFailed: { transcriptionFailed = true },
                    localFailure: { failure = $0.localizedDescription }
                )
                try await run.run(request: request, route: route, key: key, instructions: instructions,
                                  history: runtime.messages(prepared.messages, originals: originalHistory)) { connected = true }
            } catch is CancellationError {
                // A changed history/account or a cancelled call is already reflected by the UI.
            } catch {
                if !Task.isCancelled {
                    failure = error.localizedDescription
                }
            }
        }
        task = runTask
        store.setCancellation(for: activity) { runTask.cancel() }
    }
}
