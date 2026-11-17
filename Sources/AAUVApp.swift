import CloudKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@main
struct AAUVApp: App {
    @State private var store: ConversationStore
    @State private var cloudSync: CloudSync
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.default.rawValue
    @State private var proxy = SingBox()
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var openEvents: MacOpenEvents
    #endif

    init() {
        let store = ConversationStore()
        _store = State(initialValue: store)
        _cloudSync = State(initialValue: CloudSync(store: store))
        let defaults = UserDefaults.standard
        LocalDisplayProfile.prepare(defaults: defaults)
        if defaults.object(forKey: "apiProtocol") == nil, defaults.object(forKey: "endpoint") != nil {
            defaults.set("chat_completions", forKey: "apiProtocol")
        }
        store.resumeConfigurationImport()
        if !store.configurationUnavailable, store.loadError == nil {
            try? ModelServices.seed(defaults: defaults, bots: store.bots, conversations: store.conversations)
        }
        store.enablePublicPreferenceSync(defaults: defaults)
    }

    var body: some Scene {
        WindowGroup("AAUV", id: "main") {
            workspace
                .task(id: CloudSync.RunIntent(enabled: cloudSyncEnabled,
                                              configurationUnavailable: store.configurationUnavailable)) {
                    #if os(macOS)
                    openEvents.bindForegroundSync(cloudSync)
                    #endif
                    store.publicPreferencesDidChange(force: true)
                    await cloudSync.reconcileRunIntent()
                }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    store.publicPreferencesDidChange()
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    Task { await cloudSync.accountStatusDidChange() }
                }
                .tint(Theme.Palette.accent)
                .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .default).colorScheme)
                #if os(macOS)
                .frame(minWidth: 920, minHeight: 620)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    proxy.stop()
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { PendingAppCommands() }
        #endif
    }

    private var workspace: WorkspaceView {
        #if os(macOS)
        WorkspaceView(store: store, proxy: proxy, cloudSync: cloudSync, macOpenEvents: openEvents)
        #else
        WorkspaceView(store: store, proxy: proxy, cloudSync: cloudSync)
        #endif
    }
}

struct WorkspaceView: View {
    @AppStorage(LocalDisplayProfile.storageKey) private var profileData = Data()
    private struct Draft {
        var text = ""
        var files: [DraftAttachment] = []
    }

    private struct BotChange {
        let conversationID: UUID
        let previous: BotSnapshot?
        let selected: BotSnapshot
    }

    private struct SearchScope: Identifiable {
        let id = UUID()
        let conversationID: UUID?
    }

    private struct RetryTarget {
        let conversationID: UUID
        let messageID: UUID
        var regenerating = false
    }

    private struct MessageDeletionTarget {
        let conversationID: UUID
        let messageID: UUID
    }

    private struct MessageJump: Identifiable {
        let id = UUID()
        let conversationID: UUID
        let messageID: UUID?
    }

    private struct TimelineMessage: Identifiable {
        var id: UUID { message.id }
        let message: ChatMessage
        let previous: ChatMessage?
        let choice: (promptID: UUID, isCurrent: Bool)?
    }

    private struct FilePreview {
        let inbox: ShareInbox
        let item: ShareInbox.Item
    }

    private struct ImportPresentation: Identifiable {
        let id = UUID()
        let document: FileOpenRequest
        let queued: FilePreview?
    }

    private struct BotSettingsPresentation: Identifiable {
        let id = UUID()
        let bot: LocalBot
        let previewID: UUID?
    }

    private enum OpenResult { case opened, preview, deferred }

    let store: ConversationStore
    let proxy: SingBox
    let cloudSync: CloudSync
    #if os(macOS)
    @ObservedObject var macOpenEvents: MacOpenEvents
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneIsActive = false
    @State private var filePicker = false
    @State private var attachmentPickerTarget: UUID?
    @State private var loadingAttachments: UUID?
    @State private var pendingDocuments: [URL] = []
    @State private var readingIncoming = false
    @State private var incomingRequested = false
    @State private var stagingIncoming = false
    @State private var capturingFiles = 0
    @State private var importPresentation: ImportPresentation?
    @State private var filePreview: FilePreview?
    @State private var confirmDiscardFile = false
    @State private var deferredFiles: Set<UUID> = []
    @State private var unavailableInboxes: Set<URL> = []
    @State private var selection: UUID?
    @State private var section: PendingAppSection = .messages
    @State private var selectedBot: PendingBotDestination?
    @State private var selectedBotChat: UUID?
    @State private var unsentConversations = UnsentConversations()
    @State private var selectedSettings: PendingSettingsDestination?
    @State private var settingsPath: [PendingSettingsSubpage] = []
    @State private var presentedEditors: Set<UUID> = []
    @State private var photoPickerTarget: UUID?
    @State private var photoPickerPresented = false
    @State private var photoItems: [PhotosPickerItem] = []
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var cameraTarget: UUID?
    @State private var showingCamera = false
    #else
    @AppStorage("mac_message_privacy_manual") private var manualPrivacy = false
    @AppStorage("mac_message_privacy_background") private var backgroundPrivacy = false
    #endif
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var settings = false
    @State private var botSettingsPresentation: BotSettingsPresentation?
    @State private var drafts: [UUID: Draft] = [:]
    @State private var active: UUID?
    @State private var savedReplyID: UUID?
    @State private var voiceConversation: Conversation?
    @State private var pendingBotChange: BotChange?
    @State private var historySearch: SearchScope?
    @State private var pendingSearchResult: HistorySearchHit?
    @State private var searchJump: MessageJump?
    @State private var requestTask: Task<Void, Never>?
    @State private var streamingText = ""
    @State private var runningTools: Set<HostedTool> = []
    @State private var runningLocalTool: String?
    @State private var pendingRetry: RetryTarget?
    @State private var pendingMessageDeletion: MessageDeletionTarget?
    @State private var renamingConversation: UUID?
    @State private var draftTitle = ""
    @State private var error: String?
    @State private var expandedLetterRequests: Set<UUID> = []
    @State private var exportingLetter = false
    @State private var letterExportDocument: LetterTextDocument?
    @State private var letterExportFormat = LetterTextFormat.plainText

    var body: some View {
        PendingAppShell(section: $section, preferredCompactColumn: $compactColumn,
                        avatarSeed: (LocalDisplayProfile.decode(profileData) ?? .placeholder).avatarSeed) {
            conversationList
        } letters: {
            letterFeed
        } bots: {
            botList
        } me: {
            PendingMeMenu(selection: usesSidebar ? Binding(
                get: { selectedSettings },
                set: { destination in
                    settingsPath.removeAll()
                    selectedSettings = destination
                }
            ) : nil, wide: usesSidebar,
                          onEditingVisibilityChange: editorVisibilityChanged) {
                preferencesDestination($0)
            }
        } detail: { selectedSection in
            detailColumn(selectedSection)
        }
        #if os(macOS)
        .focusedSceneValue(\.pendingWorkspaceActions, PendingWorkspaceActions(
            newConversation: store.configurationUnavailable || store.loadError != nil ? nil : { create() },
            newBot: store.configurationUnavailable || store.loadError != nil ? nil : { section = .bots; selectedBot = .new },
            search: { historySearch = SearchScope(conversationID: (section == .messages || section == .letters) ? selection : nil) },
            settings: { settings = true }
        ))
        .onChange(of: macOpenEvents.pending) { receiveMacOpenEvents() }
        #else
        .onOpenURL { queueIncoming([$0]) }
        #endif
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let target = attachmentPickerTarget
            attachmentPickerTarget = nil
            switch result {
            case .success(let urls):
                if let target {
                    loadAttachments(urls, for: target)
                } else {
                    queueIncoming(urls)
                }
            case .failure(let error): self.error = error.localizedDescription
            }
        } onCancellation: {
            attachmentPickerTarget = nil
            processIncoming()
        }
        .onChange(of: scenePhase, initial: true) { previousPhase, phase in
            sceneIsActive = phase == .active
            if sceneIsActive {
                // Mac app activation is handled once by its shared delegate.
                #if !os(macOS)
                // The app's RunIntent task already handles initial startup.
                if previousPhase != phase { Task { await cloudSync.foregroundActivated() } }
                #endif
                if store.configurationUnavailable { store.resumeConfigurationImport() }
                deferredFiles.removeAll()
                unavailableInboxes.removeAll()
                #if os(iOS)
                if !store.configurationUnavailable { recentBot.publishToShareInbox() }
                #elseif os(macOS)
                receiveMacOpenEvents()
                #endif
                processIncoming()
            }
        }
        .onChange(of: store.configurationRecovering) {
            guard !store.configurationUnavailable else { return }
            #if os(iOS)
            recentBot.publishToShareInbox()
            #elseif os(macOS)
            receiveMacOpenEvents()
            #endif
            processIncoming()
        }
        #if os(iOS)
        .onChange(of: store.bots) {
            if !store.configurationUnavailable { recentBot.publishToShareInbox() }
        }
        #endif
        .onChange(of: error) { if error == nil { processIncoming() } }
        .onChange(of: pendingBotChange == nil) { if pendingBotChange == nil { processIncoming() } }
        .onChange(of: pendingRetry == nil) { if pendingRetry == nil { processIncoming() } }
        .onChange(of: pendingMessageDeletion == nil) { if pendingMessageDeletion == nil { processIncoming() } }
        .onChange(of: renamingConversation == nil) { if renamingConversation == nil { processIncoming() } }
        .onChange(of: selectedBot) {
            if selectedBot != nil { selectedBotChat = nil }
        }
        .onChange(of: selection) {
            if let conversation = store.conversations.first(where: { $0.id == selection }) {
                section = conversation.isLetter ? .letters : .messages
            }
            if pendingRetry?.conversationID != selection { pendingRetry = nil }
        }
        .onChange(of: section) {
            if section == .letters { migrateLegacyLetters() }
            if section == .messages || section == .letters { processIncoming() }
        }
        .onAppear { migrateLegacyLetters() }
        .onChange(of: store.conversations.count) { migrateLegacyLetters() }
        .onChange(of: presentedEditors) { if presentedEditors.isEmpty { processIncoming() } }
        .onChange(of: filePicker) { if !filePicker { processIncoming() } }
        .onChange(of: photoPickerPresented) { if !photoPickerPresented { processIncoming() } }
        .onDisappear { requestTask?.cancel() }
        .photosPicker(isPresented: $photoPickerPresented, selection: $photoItems, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty, let target = photoPickerTarget else { return }
            photoItems = []
            loadPhotos(items, for: target)
        }
        #if os(iOS)
        .onChange(of: showingCamera) { if !showingCamera { processIncoming() } }
        .sheet(isPresented: $showingCamera) {
            PendingComposerCameraPicker { image in
                showingCamera = false
                guard let image, let target = cameraTarget else { return }
                loadCameraImage(image, for: target)
            }
        }
        #endif
        .sheet(item: $importPresentation, onDismiss: finishImport) { presentation in
            NavigationStack {
                Form {
                    PortableDataView(store: store, incomingDocument: presentation.document,
                                     sharedImportID: presentation.queued?.item.id)
                }
                .formStyle(.grouped)
                .toolbar {
                    if presentation.queued != nil {
                        Button("移除待导入文件…", role: .destructive) { confirmDiscardFile = true }
                            .disabled(store.restoringBackup)
                    }
                    Button(presentation.queued == nil ? "完成" : "关闭") { importPresentation = nil }
                        .disabled(store.restoringBackup)
                }
                .confirmationDialog("从大绿豆收件箱移除这份文件？", isPresented: $confirmDiscardFile) {
                    Button("移除", role: .destructive, action: discardFilePreview)
                }
            }
            .interactiveDismissDisabled(store.restoringBackup)
            #if os(macOS)
            .frame(width: 560, height: 560)
            #endif
        }
        .sheet(item: $botSettingsPresentation, onDismiss: processIncoming) { presentation in
            NavigationStack {
                BotEditor(store: store, proxy: proxy, existing: presentation.bot, onSaved: {
                    if let id = presentation.previewID,
                       let updated = store.bots.first(where: { $0.id == presentation.bot.id }) {
                        unsentConversations.changeBot(updated.snapshot.boundForNewChat(), in: id)
                    }
                    botSettingsPresentation = nil
                }, onEditingVisibilityChange: editorVisibilityChanged)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { botSettingsPresentation = nil }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 540, minHeight: 600)
            #endif
        }
        .fileExporter(isPresented: $exportingLetter, document: letterExportDocument,
                      contentType: letterExportFormat.contentType,
                      defaultFilename: String(localized: "信件")) { result in
            letterExportDocument = nil
            if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled {
                error = String(localized: "无法导出正文。")
            }
            processIncoming()
        }
        .onChange(of: exportingLetter) { if !exportingLetter { processIncoming() } }
        .sheet(item: $voiceConversation, onDismiss: processIncoming) { conversation in
            let bot = conversation.bot ?? recentBot
            VoiceCallView(conversationID: conversation.id, bot: bot, store: store, proxy: proxy)
        }
        .sheet(isPresented: $settings, onDismiss: processIncoming) {
            NavigationStack {
                PendingMeMenu(showsNavigationBar: true, onEditingVisibilityChange: editorVisibilityChanged) {
                    preferencesDestination($0)
                }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
            }
                #if os(macOS)
                .frame(width: 540, height: 560)
                #endif
        }
        .sheet(item: $historySearch, onDismiss: openHistoryResult) { scope in
            HistorySearchView(store: store, conversationID: scope.conversationID) { pendingSearchResult = $0 }
        }
        .confirmationDialog("更换当前会话的机器人？", isPresented: Binding(
            get: { pendingBotChange != nil },
            set: { if !$0 { pendingBotChange = nil } }
        ), titleVisibility: .visible, presenting: pendingBotChange) { change in
            Button("更换机器人") {
                pendingBotChange = nil
                do { try store.changeBot(change.selected, in: change.conversationID, expected: change.previous) }
                catch { self.error = error.localizedDescription }
            }
        } message: { change in
            Text("之后的请求会用 \(change.selected.name)（\(botDestination(change.selected))），并按上下文设置带上当前会话的消息。")
        }
        .alert("重命名会话", isPresented: Binding(
            get: { renamingConversation != nil }, set: { if !$0 { renamingConversation = nil } }
        ), presenting: renamingConversation) { id in
            TextField("会话标题", text: $draftTitle)
            Button("保存") {
                do { try store.rename(id, to: draftTitle) }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这条消息？", isPresented: Binding(
            get: { pendingMessageDeletion != nil },
            set: { if !$0 { pendingMessageDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingMessageDeletion) { target in
            Button("删除消息", role: .destructive) {
                pendingMessageDeletion = nil
                do { try store.deleteMessage(target.messageID, in: target.conversationID) }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) { pendingMessageDeletion = nil }
        } message: { _ in
            Text("这条消息将从本机会话中删除。开启 iCloud 同步时，删除也会同步到其它设备。此操作无法撤销。")
        }
        .alert("操作未完成", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var usesSidebar: Bool {
        #if os(iOS)
        Platform.isMac || horizontalSizeClass != .compact
        #else
        true
        #endif
    }

    private var privacyCovered: Bool {
        #if os(macOS)
        manualPrivacy || (backgroundPrivacy && !sceneIsActive)
        #else
        false
        #endif
    }

    private func migrateLegacyLetters() {
        guard store.loadError == nil, !store.configurationUnavailable else { return }
        do { try store.migrateLegacyLetters() }
        catch { self.error = String(localized: "无法整理旧信件。") }
    }

    private func letterRow(_ conversation: Conversation) -> PendingLetterRowModel {
        let replies = conversation.turns.flatMap { $0.currentReplies(selected: conversation.selectedReply(for: $0)) }
        let body = replies.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? ""
        let attempt = conversation.replyAttempts?.last
        let state: PendingLetterRowModel.State
        if store.activities[conversation.id] != nil { state = .writing }
        else if attempt?.phase == .failed { state = .failed }
        else if attempt != nil { state = .interrupted }
        else { state = body.isEmpty ? .waiting : .ready }
        let excerpt = active == conversation.id && !streamingText.isEmpty ? streamingText :
            (!body.isEmpty ? body : attempt?.partial ?? "")
        return PendingLetterRowModel(
            id: conversation.id,
            title: conversation.title.isEmpty ? String(localized: "未命名来信") : conversation.title,
            sender: conversation.bot?.name ?? String(localized: "机器人"),
            senderID: conversation.bot?.profileID,
            date: conversation.messages.first?.date,
            excerpt: String(excerpt.prefix(240)), state: state,
            canDelete: store.activities[conversation.id] == nil && voiceConversation?.id != conversation.id &&
                !store.configurationUnavailable
        )
    }

    private var letterFeed: some View {
        PendingLetterFeed(rows: store.conversations.filter(\.isLetter).map(letterRow),
                          selection: selection, canWrite: !letterActionsDisabled,
                          privacyCovered: privacyCovered,
                          onSelect: { id in section = .letters; selection = id; compactColumn = .detail },
                          onWrite: { presentLetter(bot: recentBot) },
                          onSearch: { historySearch = SearchScope(conversationID: nil) },
                          onDelete: delete)
            .safeAreaInset(edge: .top) {
                if store.configurationRecovering { ProgressView("正在恢复本机配置…").padding() }
                if let loadError = store.loadError {
                    Text(loadError).foregroundStyle(Theme.Palette.danger).padding()
                }
            }
    }

    private func letterArticle(_ conversation: Conversation) -> some View {
        let jump = searchJump.flatMap { target in
            target.conversationID == conversation.id ? PendingTimelineJump(id: target.id, messageID: target.messageID) : nil
        }
        return PendingLetterArticle(row: letterRow(conversation), showsBack: !usesSidebar,
                                    jump: jump, onBack: { compactColumn = .sidebar },
                                    onJumpConsumed: { id in if searchJump?.id == id { searchJump = nil } }) {
            #if os(macOS)
            PendingChatHeaderAction(systemImage: privacyCovered ? "eye.slash.fill" : "eye",
                                    label: "消息隐私遮盖", action: { manualPrivacy.toggle() })
                .accessibilityValue(privacyCovered ? "已开启" : "已关闭")
            #endif
            if active == conversation.id {
                Button(savedReplyID == nil ? "停止生成" : "停止处理附件") { requestTask?.cancel() }
            }
            Menu {
                Button("请它写信", systemImage: "envelope") { presentLetter(bot: conversation.bot ?? recentBot) }
                    .disabled(letterActionsDisabled)
                Button("搜索当前对话", systemImage: "magnifyingglass") {
                    historySearch = SearchScope(conversationID: conversation.id)
                }
                Button("删除信件", role: .destructive) { delete(conversation.id) }
                    .disabled(!letterRow(conversation).canDelete)
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("更多信件操作")
        } content: {
            letterArticleContent(conversation)
                .pendingChatPrivacyCover(privacyCovered)
        }
        .confirmationDialog("重新请求可能重复产生用量或执行服务商工具", isPresented: Binding(
            get: { pendingRetry?.conversationID == conversation.id },
            set: { if !$0 { pendingRetry = nil } }
        ), titleVisibility: .visible, presenting: pendingRetry) { target in
            Button(target.regenerating ? "重新生成" : "重新请求") {
                pendingRetry = nil
                ask(target.conversationID, to: target.messageID, regenerating: target.regenerating)
            }
        }
    }

    private func letterArticleContent(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let context = conversation.letterContext {
                Text(context.sourceConversationID == nil ?
                     String(localized: "没有可参考的聊天记录，将自然开启话题。") :
                     String(localized: "背景来自此机器人最近一次聊天；按当前上下文设置取用。"))
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
                if !context.messages.isEmpty { letterBackground(context, botName: conversation.bot?.name ?? "") }
            }
            ForEach(conversation.turns) { turn in
                if turn.first.role == .user {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedLetterRequests.contains(turn.first.id) },
                        set: { expanded in
                            if expanded { expandedLetterRequests.insert(turn.first.id) }
                            else { expandedLetterRequests.remove(turn.first.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(LetterWritingPrompt.displayedRequirements(turn.first.content))
                                .font(Theme.Fonts.body).pendingChatSelectableText()
                            ForEach(turn.first.attachments ?? []) { shareAttachment($0, in: conversation.id) }
                            if let trace = turn.first.localToolTrace {
                                LocalToolTraceView(trace: trace,
                                                  activeRequestID: store.activities[conversation.id]?.kind == .reply ?
                                                    store.activities[conversation.id]?.id : nil)
                            }
                            Button("重新生成", systemImage: "arrow.clockwise") {
                                pendingRetry = RetryTarget(conversationID: conversation.id, messageID: turn.first.id,
                                                           regenerating: true)
                            }
                            .disabled(replyActionsDisabled(in: conversation.id))
                            Button("删除消息", role: .destructive) {
                                pendingMessageDeletion = MessageDeletionTarget(conversationID: conversation.id, messageID: turn.first.id)
                            }
                            .disabled(store.configurationUnavailable)
                        }
                        .padding(.top, 10)
                    } label: {
                        Text(conversation.letterContext == nil ? String(localized: "写信要求") : String(localized: "生成说明"))
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
                    }
                    .id(turn.first.id)
                } else {
                    letterReply(turn.first, in: conversation.id)
                        .id(turn.first.id)
                }
                ForEach(turn.replies) { reply in
                    VStack(alignment: .leading, spacing: 12) {
                        if !turn.alternatives.isEmpty {
                            if turn.currentReplies(selected: conversation.selectedReply(for: turn)).contains(where: { $0.id == reply.id }) {
                                Label("当前回答", systemImage: "checkmark")
                                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
                            } else {
                                Button("使用这个回答") {
                                    do { try store.selectReply(reply.id, for: turn.id, in: conversation.id) }
                                    catch { self.error = error.localizedDescription }
                                }
                                .disabled(replyActionsDisabled(in: conversation.id))
                            }
                        }
                        letterReply(reply, in: conversation.id)
                    }
                    .id(reply.id)
                }
            }
            ForEach(conversation.replyAttempts ?? []) { attempt in
                if attempt.id != store.activities[conversation.id]?.id {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(attempt.diagnostic?.summary ?? (attempt.phase == .failed ? "请求失败" : "生成中断 · 可重新请求"))
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
                        if let diagnostic = attempt.diagnostic {
                            Text(diagnostic.supportDetails).font(.caption2).textSelection(.enabled)
                            if diagnostic.usageLimited { Link("查看 ChatGPT 用量", destination: ChatGPTPlanSession.usageURL) }
                        }
                        if !attempt.partial.isEmpty { MessageMarkdown(text: attempt.partial).equatable() }
                        if attempt.regenerating == true {
                            Button("重新生成") {
                                pendingRetry = RetryTarget(conversationID: conversation.id, messageID: attempt.userMessageID,
                                                           regenerating: true)
                            }
                            .disabled(replyActionsDisabled(in: conversation.id))
                        }
                    }
                }
            }
            if active == conversation.id {
                VStack(alignment: .leading, spacing: 10) {
                    if !runningTools.isEmpty { Text(runningTools.map(\.progressLabel).sorted().joined(separator: " · ")).font(.caption) }
                    if let runningLocalTool { Text(localToolProgress(runningLocalTool)).font(.caption) }
                    if savedReplyID != nil { ProgressView("正在处理附件…") }
                    else if !streamingText.isEmpty { Text(streamingText).font(Theme.Fonts.body).pendingChatSelectableText() }
                }
            } else if store.activities[conversation.id] != nil {
                Text("此会话正在另一窗口生成回复").font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
            }
            if conversation.unansweredPrompt != nil {
                Button("重新请求", systemImage: "arrow.clockwise") { retryUnanswered(in: conversation.id) }
                    .disabled(replyActionsDisabled(in: conversation.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func letterBackground(_ context: LetterContext, botName: String) -> some View {
        DisclosureGroup("聊天背景") {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(context.messages, id: \.id) { message in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(message.role == .user ? String(localized: "你") : botName)
                            if let date = message.date { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                        }
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.inkMuted)
                        Text(message.content).font(Theme.Fonts.footnote).pendingChatSelectableText()
                    }
                }
            }
            .padding(.top, 10)
        }
        .font(Theme.Fonts.footnote)
    }

    private func letterReply(_ message: ChatMessage, in id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.content.isEmpty {
                MessageMarkdown(text: message.content, citations: message.citations ?? []).equatable()
                Menu {
                    Button("文本（.txt）") { exportLetterBody(message.content, format: .plainText) }
                    Button("Markdown（.md）") { exportLetterBody(message.content, format: .markdown) }
                } label: {
                    Label("导出正文", systemImage: "square.and.arrow.up")
                }
                .font(Theme.Fonts.footnote)
            }
            ForEach(message.attachments ?? []) { shareAttachment($0, in: id) }
            if let unavailable = message.unavailableAttachments, unavailable > 0, savedReplyID != message.id {
                Text("\(unavailable) 个生成文件未能保存").font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("删除消息", role: .destructive) {
                pendingMessageDeletion = MessageDeletionTarget(conversationID: id, messageID: message.id)
            }
            .disabled(store.configurationUnavailable)
        }
    }

    private var conversationRows: [PendingConversationRowModel] {
        store.conversations.filter { !$0.isLetter }.map { conversation in
            let last = conversation.messages.last
            return PendingConversationRowModel(
                id: conversation.id, title: conversation.title,
                botID: conversation.bot?.profileID, botName: conversation.bot?.name ?? "",
                model: conversation.bot?.model ?? "",
                preview: last?.content ?? conversation.attachments?.first?.name ?? "",
                date: last?.date, busy: store.activities[conversation.id] != nil,
                canDelete: store.activities[conversation.id] == nil && voiceConversation?.id != conversation.id
            )
        }
    }

    private var newConversationItems: [PendingNewConversationItem] {
        guard !store.bots.isEmpty else { return [] }
        return [PendingNewConversationItem(id: "recent", title: "最近使用 · \(recentBot.name)", action: { create() }),
                PendingNewConversationItem(id: "default", title: "默认机器人", action: { create(bot: .activeDefaults()) })]
            + store.bots.map { bot in
                PendingNewConversationItem(id: bot.id.uuidString, title: bot.configuration.name,
                                           action: { create(bot: bot.snapshot) })
            }
    }

    private var conversationList: some View {
        PendingConversationList(rows: conversationRows, selection: $selection,
                                isBusy: store.configurationRecovering,
                                canCreate: store.loadError == nil && !store.configurationUnavailable,
                                canSearch: store.loadError == nil,
                                canOpenFiles: store.loadError == nil,
                                newConversationItems: newConversationItems,
                                onNewForConversation: { id in
                                    if let conversation = store.conversations.first(where: { $0.id == id }) { create(bot: conversation.bot) }
                                },
                                onSelect: { id in selection = id; compactColumn = .detail },
                                onNew: { create() },
                                onSearch: { historySearch = SearchScope(conversationID: nil) },
                                onFiles: { filePicker = true },
                                onRename: { id in
                                    guard let conversation = store.conversations.first(where: { $0.id == id }) else { return }
                                    draftTitle = conversation.title
                                    renamingConversation = id
                                },
                                onDelete: { delete($0) })
            .safeAreaInset(edge: .top) {
                if store.configurationRecovering { ProgressView("正在恢复本机配置…").padding() }
                if stagingIncoming || capturingFiles > 0 { ProgressView("正在复制文件到本机…").padding() }
                if !deferredFiles.isEmpty || !unavailableInboxes.isEmpty {
                    Button("继续处理待导入文件") {
                        deferredFiles.removeAll()
                        unavailableInboxes.removeAll()
                        processIncoming()
                    }
                    .padding(8)
                }
                if let loadError = store.loadError {
                    Text(loadError).foregroundStyle(Theme.Palette.danger).padding()
                }
                if let message = store.configurationRecoveryError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).foregroundStyle(Theme.Palette.danger)
                        Button("重试恢复配置") {
                            store.resumeConfigurationImport()
                        }
                        .disabled(store.configurationRecovering)
                    }
                    .padding()
                }
            }
    }

    private func openBotSettings(in conversation: Conversation) {
        guard let id = conversation.bot?.profileID, let bot = store.bots.first(where: { $0.id == id }) else {
            settings = true
            return
        }
        botSettingsPresentation = BotSettingsPresentation(bot: bot,
            previewID: unsentConversations[conversation.id] != nil ? conversation.id : nil)
    }

    private func chatConversation(_ id: UUID?) -> Conversation? {
        guard let id else { return nil }
        return store.conversations.first(where: { $0.id == id }) ?? unsentConversations[id]
    }

    private var botListContent: some View {
        BotProfilesView(store: store, proxy: proxy,
                        selection: usesSidebar ? $selectedBot : nil,
                        onChat: openBotChat,
                        onEditingVisibilityChange: editorVisibilityChanged)
    }

    @ViewBuilder private var botList: some View {
        if usesSidebar { botListContent }
        else {
            botListContent.navigationDestination(isPresented: Binding(
                get: { selectedBotChat != nil },
                set: { if !$0 { selectedBotChat = nil } }
            )) {
                if let id = selectedBotChat, let conversation = chatConversation(id) {
                    detail(conversation).id(id)
                        #if os(iOS)
                        .toolbar(.hidden, for: .tabBar)
                        #endif
                }
            }
        }
    }

    private func openBotChat(_ bot: BotSnapshot) {
        guard !store.configurationUnavailable, store.loadError == nil else { return }
        let conversation = unsentConversations.open(bot: bot.boundForNewChat(), reusing: true)
        selectedBot = nil
        selectedBotChat = conversation.id
        selection = conversation.id
        section = .bots
    }

    @ViewBuilder private func detailColumn(_ selectedSection: PendingAppSection) -> some View {
        switch selectedSection {
        case .messages:
            if store.configurationRecovering {
                ProgressView("正在恢复本机配置…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let conversation = chatConversation(selection), !conversation.isLetter {
                detail(conversation).id(conversation.id)
            } else {
                PendingEmptyDetail()
            }
        case .letters:
            if store.configurationRecovering {
                ProgressView("正在恢复本机配置…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let conversation = store.conversations.first(where: { $0.id == selection && $0.isLetter }) {
                letterArticle(conversation).id(conversation.id)
            } else {
                PendingEmptyDetail(systemImage: "envelope.open")
            }
        case .bots:
            if let id = selectedBotChat, let conversation = chatConversation(id) {
                detail(conversation).id(id)
            } else {
            NavigationStack {
                switch selectedBot {
                case .new: BotEditor(store: store, proxy: proxy, onSaved: { selectedBot = nil },
                                     onEditingVisibilityChange: editorVisibilityChanged)
                case .existing(let id):
                    if let bot = store.bots.first(where: { $0.id == id }) {
                        BotEditor(store: store, proxy: proxy, existing: bot, onSaved: { selectedBot = nil },
                                  onEditingVisibilityChange: editorVisibilityChanged)
                    } else { PendingEmptyDetail(systemImage: "person.2") }
                case nil: PendingEmptyDetail(systemImage: "person.2")
                }
            }
            .id(selectedBot)
            }
        case .me:
            NavigationStack(path: $settingsPath) {
                if let selectedSettings { preferencesDestination(selectedSettings) }
                else { PendingEmptyDetail(systemImage: "person.crop.circle") }
            }
            .id(selectedSettings)
        }
    }

    @ViewBuilder private func preferencesDestination(_ destination: PendingSettingsDestination) -> some View {
        if destination == .usage {
            ModelUsageView(store: store)
        } else {
            SettingsView(proxy: proxy, store: store, cloudSync: cloudSync,
                         destination: destination, embedded: true,
                         onEditingVisibilityChange: editorVisibilityChanged)
        }
    }

    private func editorVisibilityChanged(_ id: UUID, _ visible: Bool) {
        if visible { presentedEditors.insert(id) }
        else { presentedEditors.remove(id) }
    }

    private func timelineMessages(in conversation: Conversation) -> [TimelineMessage] {
        var rows: [TimelineMessage] = []
        var previous: ChatMessage?
        for turn in conversation.turns {
            rows.append(TimelineMessage(message: turn.first, previous: previous, choice: nil))
            let current = Set(turn.currentReplies(selected: conversation.selectedReply(for: turn)).map(\.id))
            let replies = turn.replies
            for (index, reply) in replies.enumerated() {
                rows.append(TimelineMessage(message: reply,
                                            previous: index > 0 ? replies[index - 1] : turn.first,
                                            choice: turn.alternatives.isEmpty ? nil : (turn.id, current.contains(reply.id))))
            }
            previous = turn.original.last ?? turn.first
        }
        return rows
    }

    private func detail(_ conversation: Conversation) -> some View {
        let messages = timelineMessages(in: conversation)
        let bot = conversation.bot ?? recentBot
        let jump = searchJump.flatMap { target in
            target.conversationID == conversation.id ? PendingTimelineJump(id: target.id, messageID: target.messageID) : nil
        }
        return VStack(spacing: 0) {
            PendingChatHeader(title: conversation.title, botName: bot.name, modelName: bot.model,
                              conversationID: conversation.id.uuidString, botID: bot.profileID?.uuidString,
                              isPending: store.activities[conversation.id] != nil,
                              showsBack: !usesSidebar,
                              onBack: {
                                  if selectedBotChat == conversation.id, section == .bots { selectedBotChat = nil }
                                  else { compactColumn = .sidebar }
                              },
                              onNewConversation: { create(bot: bot) },
                              onSearch: unsentConversations[conversation.id] != nil ? nil : {
                                  historySearch = SearchScope(conversationID: conversation.id)
                              },
                              onSettings: { openBotSettings(in: conversation) }) {
                chatHeaderMenu(conversation)
            }
            PendingConversationTimeline(messageCount: conversation.messages.count,
                                        lastMessageIsUser: conversation.messages.last?.role == .user,
                                        streamingText: active == conversation.id ? streamingText : "",
                                        activityRevision: active == conversation.id ?
                                            ([runningLocalTool ?? "generating"] + runningTools.map(\.rawValue).sorted()).joined(separator: ":") : "idle",
                                        jump: jump,
                                        onJumpConsumed: { id in if searchJump?.id == id { searchJump = nil } }) {
                    ForEach(conversation.attachments ?? []) { attachment in
                        shareAttachment(attachment, in: conversation.id).padding(8)
                    }
                    if conversation.messages.isEmpty {
                        PendingChatEmptyConversation(
                            title: conversation.title, botName: bot.name, modelName: bot.model,
                            conversationID: conversation.id.uuidString, botID: bot.profileID?.uuidString
                        ) {
                            HStack(spacing: 16) {
                                #if os(iOS)
                                if bot.loginMethod == .byok, unsentConversations[conversation.id] == nil {
                                    PendingChatPreChatAction(title: "致电", systemImage: "phone.fill", action: { voiceConversation = conversation })
                                        .disabled(voiceActionsDisabled(in: conversation.id))
                                }
                                #endif
                                PendingChatPreChatAction(title: "请它写信", systemImage: "envelope.fill",
                                                         action: { presentLetter(bot: bot) })
                                    .disabled(letterActionsDisabled)
                                PendingChatPreChatAction(title: "设置", systemImage: "gearshape",
                                                         action: { openBotSettings(in: conversation) })
                            }
                        }
                    }
                    // Keep each message a directly identified lazy row. A whole
                    // turn can contain a reply much taller than the viewport.
                    ForEach(messages) { row in
                        VStack(spacing: 2) {
                            messageRow(row.message, after: row.previous, in: conversation.id, choice: row.choice)
                        }
                        .id(row.id)
                    }
                    ForEach(conversation.replyAttempts ?? []) { attempt in
                        if attempt.id != store.activities[conversation.id]?.id {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(attempt.diagnostic?.summary ?? (attempt.regenerating == true
                                     ? (attempt.phase == .failed ? "重新生成失败" : "重新生成中断")
                                     : (attempt.phase == .failed ? "请求失败" : "生成中断 · 可重新请求")))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.inkMuted)
                                if let diagnostic = attempt.diagnostic {
                                    Text(diagnostic.supportDetails).font(.caption2).textSelection(.enabled)
                                    if diagnostic.usageLimited {
                                        Link("查看 ChatGPT 用量", destination: ChatGPTPlanSession.usageURL)
                                    }
                                }
                                if !attempt.partial.isEmpty { MessageMarkdown(text: attempt.partial).equatable() }
                                if attempt.regenerating == true {
                                    Button("重新生成") {
                                        pendingRetry = RetryTarget(conversationID: conversation.id, messageID: attempt.userMessageID,
                                                                   regenerating: true)
                                    }
                                    .disabled(replyActionsDisabled(in: conversation.id))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if active == conversation.id {
                        if let name = runningLocalTool {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(localToolProgress(name))
                                    .font(Theme.Fonts.footnote)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(HostedTool.allCases.filter(runningTools.contains), id: \.rawValue) { tool in
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(tool.progressLabel).font(Theme.Fonts.footnote)
                            }
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if savedReplyID != nil {
                            ProgressView("正在处理附件…").font(Theme.Fonts.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if !streamingText.isEmpty {
                            PendingChatBubble(id: "stream-" + conversation.id.uuidString,
                                              isUser: false, botName: bot.name,
                                              conversationID: conversation.id.uuidString,
                                              botID: bot.profileID?.uuidString,
                                              hasContent: true, isStreaming: true) {
                                Text(streamingText).font(Theme.Fonts.body)
                                    .pendingChatSelectableText()
                            } attachments: { EmptyView() } menu: { EmptyView() }
                        }
                    } else if let activity = store.activities[conversation.id] {
                        Text(activity.kind == .voice ? "此会话正在通话" : "此会话正在另一窗口生成回复")
                            .font(.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
            }
            .pendingChatPrivacyCover(privacyCovered)
        }
        .confirmationDialog("重新请求可能重复产生用量或执行服务商工具", isPresented: Binding(
            get: { pendingRetry?.conversationID == conversation.id },
            set: { if !$0 { pendingRetry = nil } }
        ), titleVisibility: .visible, presenting: pendingRetry) { target in
            Button(target.regenerating ? "重新生成" : "重新请求") {
                pendingRetry = nil
                ask(target.conversationID, to: target.messageID, regenerating: target.regenerating)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .pendingComposerDock(content: composer(for: conversation))
    }

    @ViewBuilder private func chatHeaderMenu(_ conversation: Conversation) -> some View {
        #if os(macOS)
        PendingChatHeaderAction(systemImage: privacyCovered ? "eye.slash.fill" : "eye",
                                label: "消息隐私遮盖", action: { manualPrivacy.toggle() })
            .accessibilityValue(privacyCovered ? "已开启" : "已关闭")
        #else
        if (conversation.bot ?? recentBot).loginMethod == .byok, unsentConversations[conversation.id] == nil {
            PendingChatHeaderAction(systemImage: "phone.fill", label: "语音通话",
                                    action: { voiceConversation = conversation })
                .disabled(voiceActionsDisabled(in: conversation.id))
        }
        #endif
        Menu {
            Button("请它写信", systemImage: "envelope") {
                presentLetter(bot: conversation.bot ?? recentBot)
            }
            .disabled(letterActionsDisabled)
            Menu("更换机器人") {
                botChoice("当前默认机器人", bot: .activeDefaults(), in: conversation)
                ForEach(store.bots) { bot in
                    botChoice(bot.configuration.name, bot: bot.snapshot, in: conversation)
                }
            }
            .disabled(replyActionsDisabled(in: conversation.id))
            if (conversation.bot ?? recentBot).loginMethod == .byok, unsentConversations[conversation.id] == nil {
                Button("语音", systemImage: "waveform") { voiceConversation = conversation }
                    .disabled(voiceActionsDisabled(in: conversation.id))
            }
        } label: {
            Image(systemName: "ellipsis").font(Theme.Fonts.glyph(size: 17))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("更多会话操作")
    }

    private func voiceActionsDisabled(in id: UUID) -> Bool {
        active != nil || voiceConversation != nil || store.activities[id] != nil || store.voiceBusy || store.configurationUnavailable
    }

    private func openHistoryResult() {
        guard let hit = pendingSearchResult else { processIncoming(); return }
        pendingSearchResult = nil
        migrateLegacyLetters()
        guard let conversation = store.conversations.first(where: { $0.id == hit.conversationID }),
              hit.messageID.map({ id in conversation.messages.contains(where: { $0.id == id }) }) ?? true else {
            error = "这条本地记录已删除。"
            return
        }
        searchJump = MessageJump(conversationID: hit.conversationID, messageID: hit.messageID)
        if conversation.isLetter, let messageID = hit.messageID {
            expandedLetterRequests.insert(messageID)
        }
        section = conversation.isLetter ? .letters : .messages
        selection = conversation.id
        compactColumn = .detail
        processIncoming()
        if selection != conversation.id { searchJump = nil }
    }

    private func botChoice(_ name: String, bot: BotSnapshot, in conversation: Conversation) -> some View {
        let model = bot.model.isEmpty ? (bot.loginMethod == .copilot ? "服务默认模型" : "未配置模型") : bot.model
        return Button {
            if unsentConversations[conversation.id] != nil {
                unsentConversations.changeBot(bot.boundForNewChat(), in: conversation.id)
            } else {
                pendingBotChange = BotChange(conversationID: conversation.id, previous: conversation.bot,
                                             selected: bot.boundForNewChat())
            }
        } label: {
            Text("\(name) · \(model)")
        }
        .disabled(bot.boundForNewChat() == conversation.bot || (bot.loginMethod == .copilot && !CopilotClient.available) ||
                  (bot.loginMethod != .copilot && bot.model.isEmpty) ||
                  (bot.loginMethod == .byok && bot.apiProtocol == "anthropic_messages"))
    }

    private func botDestination(_ bot: BotSnapshot) -> String {
        switch bot.loginMethod {
        case .byok: bot.endpoint
        case .chatgpt: "ChatGPT"
        case .copilot: "GitHub Copilot"
        }
    }

    private func composer(for conversation: Conversation) -> PendingComposer {
        let id = conversation.id
        let draft = drafts[id, default: Draft()]
        return PendingComposer(
            input: Binding(get: { drafts[id]?.text ?? "" }, set: { drafts[id, default: Draft()].text = $0 }),
            files: draft.files.map { PendingComposerFile(id: $0.id, name: $0.attachment.name, url: $0.url) },
            canSend: active == nil && voiceConversation == nil && loadingAttachments != id &&
                store.activities[id] == nil && !store.configurationUnavailable &&
                (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty),
            isStreaming: active == id,
            attachmentsDisabled: active != nil || voiceConversation != nil || loadingAttachments != nil || store.configurationUnavailable,
            isPreparingAttachments: loadingAttachments == id,
            showsRetry: conversation.unansweredPrompt != nil,
            canRetry: !replyActionsDisabled(in: id),
            stopLabel: savedReplyID == nil ? "停止生成" : "停止处理附件",
            onFiles: { chooseFiles(for: id) },
            onPhotos: { choosePhotos(for: id) },
            onCamera: cameraAction(for: id),
            onRemoveFile: { fileID in drafts[id]?.files.removeAll { $0.id == fileID } },
            onSend: { send(to: id) },
            onStop: { requestTask?.cancel() },
            onRetry: { retryUnanswered(in: id) },
            privacyCovered: privacyCovered
        )
    }

    private func chooseFiles(for id: UUID) {
        guard !replyActionsDisabled(in: id), loadingAttachments == nil else { return }
        attachmentPickerTarget = id
        filePicker = true
    }

    private func choosePhotos(for id: UUID) {
        guard !replyActionsDisabled(in: id), loadingAttachments == nil else { return }
        photoPickerTarget = id
        photoPickerPresented = true
    }

    private func cameraAction(for id: UUID) -> (() -> Void)? {
        #if os(iOS)
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return nil }
        return {
            guard !replyActionsDisabled(in: id), loadingAttachments == nil else { return }
            cameraTarget = id
            showingCamera = true
        }
        #else
        return nil
        #endif
    }

    private func retryUnanswered(in id: UUID) {
        guard !replyActionsDisabled(in: id),
              let conversation = store.conversations.first(where: { $0.id == id }),
              let message = conversation.unansweredPrompt else { return }
        if conversation.replyAttempts?.contains(where: { $0.userMessageID == message.id && $0.phase != .failed }) == true {
            pendingRetry = RetryTarget(conversationID: id, messageID: message.id)
        } else { ask(id, to: message.id) }
    }

    private func loadPhotos(_ items: [PhotosPickerItem], for id: UUID) {
        guard loadingAttachments == nil, !replyActionsDisabled(in: id),
              chatConversation(id) != nil else { return }
        loadingAttachments = id
        Task { @MainActor in
            defer { loadingAttachments = nil; processIncoming() }
            do {
                var staged: [DraftAttachment] = []
                for item in items {
                    guard let image = try await item.loadTransferable(type: PendingPickedImage.self) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    defer { withExtendedLifetime(image) {} }
                    staged.append(try await store.stageFileOpen(image.url))
                }
                guard chatConversation(id) != nil else { return }
                drafts[id, default: Draft()].files.append(contentsOf: staged)
            } catch { self.error = "无法添加图片。\n\(error.localizedDescription)" }
        }
    }

    #if os(iOS)
    private func loadCameraImage(_ image: UIImage, for id: UUID) {
        guard loadingAttachments == nil, !replyActionsDisabled(in: id),
              chatConversation(id) != nil else { return }
        loadingAttachments = id
        Task { @MainActor in
            defer { loadingAttachments = nil; processIncoming() }
            do {
                guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileReadCorruptFile) }
                let directory = try PrivateTemporaryDirectory()
                defer { withExtendedLifetime(directory) {} }
                let url = directory.url.appendingPathComponent("Camera.jpg")
                try data.write(to: url, options: .atomic)
                let staged = try await store.stageFileOpen(url)
                guard chatConversation(id) != nil else { return }
                drafts[id, default: Draft()].files.append(staged)
            } catch { self.error = "无法添加照片。\n\(error.localizedDescription)" }
        }
    }
    #endif

    private func loadAttachments(_ urls: [URL], for id: UUID, suggestedNames: [URL: String] = [:]) {
        guard loadingAttachments == nil, chatConversation(id) != nil else { return }
        loadingAttachments = id
        Task { @MainActor in
            defer {
                loadingAttachments = nil
                processIncoming()
            }
            do {
                let files = try await Task.detached {
                    try urls.map { try DraftAttachment($0, suggestedName: suggestedNames[$0]) }
                }.value
                guard chatConversation(id) != nil else { return }
                drafts[id, default: Draft()].files.append(contentsOf: files)
            } catch {
                self.error = "无法添加附件。\n\(error.localizedDescription)"
            }
        }
    }

    private var recentBot: BotSnapshot {
        DefaultBotSelection.currentBot(bots: store.bots)
    }

    @ViewBuilder
    private var newChatControl: some View {
        if store.configurationUnavailable {
            Button {} label: { Label("新对话", systemImage: "plus") }.disabled(true)
        } else if store.bots.isEmpty {
            Button { create() } label: { Label("新对话", systemImage: "plus") }
                .disabled(store.loadError != nil)
        } else {
            Menu {
                Button("最近使用 · \(recentBot.name)") { create() }
                Button("默认机器人") { create(bot: .activeDefaults()) }
                ForEach(store.bots) { bot in
                    Button(bot.configuration.name) { create(bot: bot.snapshot) }
                }
            } label: {
                Label("新对话", systemImage: "plus")
            }
            .disabled(store.loadError != nil)
        }
    }

    private var openInbox: ShareInbox {
        ShareInbox(root: store.file.deletingLastPathComponent().appending(path: "OpenInbox", directoryHint: .isDirectory))
    }

    #if os(macOS)
    private func receiveMacOpenEvents() {
        guard sceneIsActive, !store.configurationUnavailable else { return }
        let urls = macOpenEvents.takePending()
        if !urls.isEmpty { queueIncoming(urls) }
    }
    #endif

    private func queueIncoming(_ urls: [URL]) {
        pendingDocuments.append(contentsOf: urls.filter { !$0.isFileURL })
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            let inbox = openInbox
            let snapshot = store.configurationUnavailable
                ? UserDefaults.standard.data(forKey: "recentBot")
                : try? JSONEncoder().encode(recentBot.boundForNewChat())
            capturingFiles += 1
            Task { @MainActor in
                defer { capturingFiles -= 1; processIncoming() }
                do {
                    let failures = try await Task.detached(priority: .userInitiated) {
                        try inbox.capture(files, botSnapshot: snapshot)
                    }.value
                    if !failures.isEmpty {
                        self.error = ([self.error, "有些文件无法复制到本机。"].compactMap { $0 } + failures).joined(separator: "\n")
                    }
                } catch {
                    self.error = [self.error, "无法准备待导入文件。\n\(error.localizedDescription)"]
                        .compactMap { $0 }.joined(separator: "\n")
                }
            }
        }
        processIncoming()
    }

    private var mediaPickerShowing: Bool {
        #if os(iOS)
        photoPickerPresented || showingCamera
        #else
        photoPickerPresented
        #endif
    }

    private var canOpenIncoming: Bool {
        sceneIsActive && presentedEditors.isEmpty && !mediaPickerShowing && !filePicker && attachmentPickerTarget == nil && loadingAttachments == nil &&
            pendingBotChange == nil && pendingRetry == nil && pendingMessageDeletion == nil && renamingConversation == nil &&
            historySearch == nil && pendingSearchResult == nil && !store.configurationUnavailable &&
            importPresentation == nil && filePreview == nil && !settings && botSettingsPresentation == nil && voiceConversation == nil && error == nil &&
            !exportingLetter
    }

    private func processIncoming() {
        guard canOpenIncoming else { return }
        if readingIncoming {
            incomingRequested = true
            return
        }
        readingIncoming = true
        Task { @MainActor in
            defer {
                readingIncoming = false
                if incomingRequested {
                    incomingRequested = false
                    processIncoming()
                }
            }
            await openIncomingDocuments()
        }
    }

    private func readIncoming(_ url: URL) async -> Result<FileOpenRequest, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try FileOpenRequest.read(url) }
        }.value
    }

    private func openIncomingDocuments() async {
        while canOpenIncoming, let url = pendingDocuments.first {
            let request = await readIncoming(url)
            guard canOpenIncoming else { return }
            do {
                let result = try await handleOpen(request.get())
                if case .deferred = result { return }
                pendingDocuments.removeFirst()
                if case .preview = result { return }
            } catch {
                pendingDocuments.removeFirst()
                self.error = error.localizedDescription
                return
            }
        }
        await drainInbox(openInbox)
        #if os(iOS)
        if let inbox = ShareInbox.shared() { await drainInbox(inbox) }
        #endif
    }

    private func drainInbox(_ inbox: ShareInbox) async {
        guard canOpenIncoming, !unavailableInboxes.contains(inbox.root) else { return }
        do {
            let items = try await Task.detached { try inbox.pending() }.value
            for item in items where !deferredFiles.contains(item.id) {
                guard canOpenIncoming else { return }
                do {
                    if try store.sharedImportCommitted(item.id) {
                        try inbox.consume(item)
                        continue
                    }
                    let request = await readIncoming(item.file)
                    guard canOpenIncoming else { return }
                    // Another window may have handled this item while the file was being read.
                    if try store.sharedImportCommitted(item.id) {
                        try inbox.consume(item)
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: item.file.path) else { continue }
                    switch try await handleOpen(request.get(), queued: FilePreview(inbox: inbox, item: item)) {
                    case .deferred:
                        return
                    case .preview:
                        return
                    case .opened:
                        try inbox.consume(item)
                    }
                } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code)
                    && !FileManager.default.fileExists(atPath: item.file.path) {
                    continue
                } catch {
                    deferredFiles.insert(item.id)
                    self.error = "无法导入文件 \(item.file.lastPathComponent)。\n\(error.localizedDescription)"
                    return
                }
            }
        } catch {
            unavailableInboxes.insert(inbox.root)
            self.error = error.localizedDescription
        }
    }

    private func handleOpen(_ document: FileOpenRequest, queued: FilePreview? = nil) async throws -> OpenResult {
        switch document {
        case .configuration, .configurationFile, .backup:
            filePreview = queued
            importPresentation = ImportPresentation(document: document, queued: queued)
            return .preview
        case .attachment(let file):
            let shareID = queued?.item.id
            let fallbackBot = recentBot
            stagingIncoming = true
            defer { stagingIncoming = false }
            let staged: DraftAttachment
            do { staged = try await store.stageFileOpen(file, shareID: shareID) }
            catch {
                guard canOpenIncoming else { return .deferred }
                if let shareID, try store.sharedImportCommitted(shareID) { return .opened }
                throw error
            }
            guard canOpenIncoming else { return .deferred }
            let id = try store.openFile(staged, bot: fallbackBot, shareID: shareID, capturedBot: queued?.item.botSnapshot)
            if store.conversations.contains(where: { $0.id == id }) {
                section = .messages
                selection = id
                compactColumn = .detail
            }
            return .opened
        }
    }

    private func finishImport() {
        if let preview = filePreview {
            filePreview = nil
            do {
                if !store.configurationUnavailable, try store.sharedImportCommitted(preview.item.id) {
                    try preview.inbox.consume(preview.item)
                } else {
                    deferredFiles.insert(preview.item.id)
                }
            } catch {
                deferredFiles.insert(preview.item.id)
                self.error = error.localizedDescription
            }
        }
        processIncoming()
    }

    private func discardFilePreview() {
        guard let preview = filePreview else { return }
        do {
            try preview.inbox.consume(preview.item)
            filePreview = nil
        } catch {
            self.error = error.localizedDescription
        }
        importPresentation = nil
    }

    private var letterActionsDisabled: Bool {
        !sceneIsActive || active != nil || voiceConversation != nil || store.voiceBusy ||
            store.configurationUnavailable || store.loadError != nil || loadingAttachments != nil ||
            readingIncoming || stagingIncoming || capturingFiles > 0 ||
            filePicker || attachmentPickerTarget != nil || mediaPickerShowing ||
            importPresentation != nil || filePreview != nil || !presentedEditors.isEmpty ||
            settings || botSettingsPresentation != nil || historySearch != nil || pendingSearchResult != nil ||
            pendingBotChange != nil || pendingRetry != nil || pendingMessageDeletion != nil ||
            renamingConversation != nil || exportingLetter || error != nil
    }

    private func presentLetter(bot: BotSnapshot) {
        guard !letterActionsDisabled else { return }
        do {
            let selectedBot = bot.boundForNewChat()
            let conversation = try LetterGeneration.makeConversation(
                bot: selectedBot, conversations: store.conversations, policy: ContextPolicy.load())
            guard let request = conversation.messages.first else { return }
            try DefaultBotSelection.savingUserMessage(with: selectedBot, bots: store.bots) {
                try store.insert(conversation)
            }
            section = .letters
            selection = conversation.id
            compactColumn = .detail
            ask(conversation.id, to: request.id)
        } catch { self.error = error.localizedDescription }
    }

    private func exportLetterBody(_ body: String, format: LetterTextFormat) {
        guard !body.isEmpty, !exportingLetter else { return }
        letterExportFormat = format
        letterExportDocument = LetterTextDocument(text: body)
        exportingLetter = true
    }

    private func create(bot: BotSnapshot? = nil) {
        guard !store.configurationUnavailable, store.loadError == nil else { return }
        let conversation = unsentConversations.open(bot: (bot ?? recentBot).boundForNewChat())
        selectedBotChat = nil
        section = .messages
        selection = conversation.id
        compactColumn = .detail
    }

    private func delete(_ id: UUID) {
        do {
            try store.delete(id)
            drafts.removeValue(forKey: id)
            if selection == id {
                selection = nil
                compactColumn = .sidebar
            }
        } catch { self.error = "无法删除本地对话。" }
    }

    private func send(to id: UUID) {
        guard let draft = drafts[id], active == nil, voiceConversation == nil, loadingAttachments != id,
              !store.configurationUnavailable else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draft.files.isEmpty else { return }
        do {
            let bot = chatConversation(id)?.bot ?? recentBot.boundForNewChat()
            let messageID = try DefaultBotSelection.savingUserMessage(with: bot, bots: store.bots) {
                if let preview = unsentConversations[id] {
                    let messageID = try store.sendFirstMessage(text, files: draft.files, in: preview)
                    unsentConversations.remove(id)
                    selectedBotChat = nil
                    section = .messages
                    selection = id
                    compactColumn = .detail
                    return messageID
                } else {
                    return try store.appendUserMessage(text, files: draft.files, to: id)
                }
            }
            drafts.removeValue(forKey: id)
            ask(id, to: messageID)
        } catch { self.error = "无法保存消息。\n\(error.localizedDescription)" }
    }

    private func replyActionsDisabled(in id: UUID) -> Bool {
        active != nil || voiceConversation != nil || store.activities[id] != nil || store.configurationUnavailable
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, after previous: ChatMessage?, in id: UUID,
                            choice: (promptID: UUID, isCurrent: Bool)? = nil) -> some View {
        if message.isAlternative != true, let date = message.date,
           previous?.date.map({ date.timeIntervalSince($0) >= RelativeMessageTime.separatorGapSeconds }) ?? true {
            PendingChatTimeSeparator(date: date)
        }
        let bot = store.conversations.first(where: { $0.id == id })?.bot ?? recentBot
        VStack(alignment: .leading, spacing: 4) {
            PendingChatBubble(id: message.id.uuidString, isUser: message.role == .user,
                              botName: bot.name, conversationID: id.uuidString,
                              botID: bot.profileID?.uuidString, hasContent: !message.content.isEmpty) {
                if !message.content.isEmpty, message.role == .assistant {
                    MessageMarkdown(text: message.content, citations: message.citations ?? []).equatable()
                } else if !message.content.isEmpty {
                    Text(message.content).font(Theme.Fonts.body).pendingChatSelectableText()
                        .foregroundStyle(Theme.Palette.ink)
                }
            } attachments: {
                ForEach(message.attachments ?? []) { shareAttachment($0, in: id) }
                if let unavailable = message.unavailableAttachments, unavailable > 0, savedReplyID != message.id {
                    Text("\(unavailable) 个生成文件未能保存")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
                }
            } menu: {
                if message.role == .assistant, !message.content.isEmpty {
                    Menu {
                        Button("文本（.txt）") { exportLetterBody(message.content, format: .plainText) }
                        Button("Markdown（.md）") { exportLetterBody(message.content, format: .markdown) }
                    } label: {
                        Label("导出正文", systemImage: "square.and.arrow.up")
                    }
                }
                if message.role == .user {
                    Button("重新生成", systemImage: "arrow.clockwise") {
                        pendingRetry = RetryTarget(conversationID: id, messageID: message.id, regenerating: true)
                    }
                    .disabled(replyActionsDisabled(in: id))
                }
                Button("删除消息", role: .destructive) {
                    pendingMessageDeletion = MessageDeletionTarget(conversationID: id, messageID: message.id)
                }
                .disabled(store.configurationUnavailable)
            }
            if message.role == .user, let trace = message.localToolTrace {
                LocalToolTraceView(trace: trace,
                                  activeRequestID: store.activities[id]?.kind == .reply ? store.activities[id]?.id : nil)
                    .padding(.horizontal, Theme.Metrics.conversationGutter)
            }
            if let choice {
                Group {
                    if choice.isCurrent {
                        Label("当前回答", systemImage: "checkmark").foregroundStyle(Theme.Palette.inkMuted)
                    } else {
                        Button("使用这个回答") {
                            do { try store.selectReply(message.id, for: choice.promptID, in: id) }
                            catch { self.error = error.localizedDescription }
                        }
                        .buttonStyle(.borderless).disabled(replyActionsDisabled(in: id))
                    }
                }
                .font(Theme.Fonts.footnote)
                .padding(.horizontal, Theme.Metrics.conversationGutter + 40)
            }
        }
    }

    @ViewBuilder private func shareAttachment(_ attachment: Attachment, in id: UUID) -> some View {
        if let url = try? store.attachmentURL(attachment) {
            VStack(alignment: .leading, spacing: 6) {
                AttachmentImagePreview(url: url, name: attachment.name)
                HStack {
                    ShareLink(item: AttachmentShare(url: url, name: attachment.name),
                              preview: SharePreview(attachment.name)) {
                        Label(attachment.name, systemImage: "doc")
                    }
                    Button("再次附加") { loadAttachments([url], for: id, suggestedNames: [url: attachment.name]) }
                        .buttonStyle(.borderless)
                        .disabled(replyActionsDisabled(in: id) || loadingAttachments != nil)
                }
            }
        }
    }

    private func ask(_ id: UUID, to messageID: UUID, regenerating: Bool = false) {
        guard active == nil, voiceConversation == nil, !store.configurationUnavailable else { return }
        let started: (ConversationStore.Activity, Conversation, ChatMessage, ReplyAttempt)
        do { started = try store.beginReply(in: id, to: messageID, regenerating: regenerating) }
        catch { self.error = error.localizedDescription; return }
        let (activity, conversation, userMessage, initialAttempt) = started
        var attempt = initialAttempt
        active = id
        savedReplyID = nil
        streamingText = ""
        runningTools = []
        runningLocalTool = nil
        let task = Task { @MainActor in
            defer {
                store.endActivity(activity)
                active = nil
                savedReplyID = nil
                streamingText = ""
                runningTools = []
                runningLocalTool = nil
                requestTask = nil
            }
            var cleanupNotice: String?
            var usageSaveFailed = false
            do {
                try Task.checkCancellation()
                if conversation.isLetter {
                    try conversation.letterContext?.validate(excluding: Set(conversation.messages.map(\.id)))
                }
                let files = try store.filesForReply(in: conversation, to: userMessage)
                let bot = conversation.bot ?? recentBot.boundForNewChat()
                if bot.loginMethod == .chatgpt, bot.chatGPTClientID?.isEmpty != false {
                    throw ChatClient.ClientError.message("此会话尚未绑定 ChatGPT 账户。请先在设置选择账户，再通过『更换机器人』确认。")
                }
                let model = bot.model.trimmingCharacters(in: .whitespacesAndNewlines)
                let policy = ContextPolicy.load()
                let history = conversation.contextForReply(to: userMessage, regenerating: regenerating,
                                                           now: Date(), policy: policy)
                let wantsLocalTools = LocalToolPreference.enabled() && (
                    bot.loginMethod == .chatgpt || bot.loginMethod == .copilot ||
                    (bot.loginMethod == .byok && (bot.apiProtocol ?? "chat_completions") == "responses")
                )
                let runtime = try RuntimePrompt(botName: bot.name)
                let delegation = LocalModelDelegation(store: store, current: bot)
                let instructions = [
                    runtime.instructions,
                    try store.readInstructions().requestInstructions,
                    bot.instructions?.requestInstructions ?? "",
                    conversation.isLetter && conversation.letterContext != nil ? LetterGeneration.backgroundInstructions : ""
                ].filter { !$0.isEmpty }.joined(separator: "\n\n")
                let replyScope = try ConversationReplyScope(store: store, activity: activity,
                                                            conversation: conversation, attempt: attempt)
                let toolInstructions = wantsLocalTools ? [ConversationLocalTools.attachmentManifest(conversation.allAttachments),
                                                          delegation.manifest].filter { !$0.isEmpty }.joined(separator: "\n\n") : ""
                let session = try await ModelSession(bot: bot, instructions: instructions, proxy: proxy,
                                                    localToolInstructions: toolInstructions)
                let target = regenerating ? "regenerate" : "reply"
                let scope = try ContextWindow.checkpointScope(bot: bot, target: "\(target):\(messageID.uuidString)")
                try Task.checkCancellation()
                @MainActor func recordUsage(_ counts: UsageCounts, _ purpose: ModelUsage.Purpose) {
                    do { try store.recordUsage(counts, provider: bot.loginMethod,
                                               model: model.isEmpty ? "Copilot" : model, purpose: purpose) }
                    catch { usageSaveFailed = true }
                }
                let prepared = try await ContextWindow.prepare(
                    history.messages, now: history.windowEnd, cached: conversation.compression, policy: policy,
                    checkpointScope: scope, saveCheckpoint: {
                        try replyScope.validate()
                        try store.saveCompressionCheckpoint($0, to: id)
                    }
                ) { prompt in
                    try await session.reply(
                        to: [.init(role: .user, content: prompt)],
                        forSummary: true, validateContext: { try replyScope.validate() },
                        willSend: { try replyScope.validate() },
                        onUsage: { recordUsage($0, .compression) }
                    )
                }
                try replyScope.validate()
                if !regenerating { try store.saveCompression(prepared.compression, to: id) }
                let localTools: ConversationLocalTools? = try session.prepareConversationTools(enabled: wantsLocalTools) {
                    let toolRoute = try proxy.requestRoute()
                    let tools = try ConversationLocalTools(store: store, activity: activity, conversation: conversation,
                                                           attempt: attempt, method: bot.loginMethod,
                                                           validateRoute: toolRoute.validate)
                    tools.configureCloud(session: session, proxy: toolRoute.configuration,
                                               delegation: delegation, makeDelegateSession: { target in
                        try await ModelSession(bot: target, instructions: "", proxy: proxy)
                    }, onDelegateUsage: { counts, provider, delegatedModel in
                        do { try store.recordUsage(counts, provider: provider,
                                                   model: delegatedModel.isEmpty ? "Copilot" : delegatedModel,
                                                   purpose: .reply) }
                        catch { usageSaveFailed = true }
                    },
                                               onUsage: { counts, delegatedModel in
                        do { try store.recordUsage(counts, provider: bot.loginMethod,
                                                   model: delegatedModel.isEmpty ? "Copilot" : delegatedModel,
                                                   purpose: .reply) }
                        catch { usageSaveFailed = true }
                    })
                    return tools
                }
                if let localTools { try replyScope.bindLocalTools(localTools) }
                let requestMessages = try runtime.messages(prepared.messages, originals: history.messages)
                var lastCheckpoint = ContinuousClock.now
                _ = try await session.reply(
                    to: requestMessages, files: files, localExecution: localTools?.execution,
                    validateContext: { try replyScope.validate() }, willSend: {
                        try Task.checkCancellation()
                        try replyScope.validate()
                        attempt.phase = .submitted
                        try store.saveAttempt(attempt, to: id)
                    },
                    onDelta: { delta in
                        try replyScope.validate()
                        let first = attempt.partial.isEmpty
                        attempt.partial += delta
                        streamingText = attempt.partial
                        if first || lastCheckpoint.duration(to: .now) >= .milliseconds(500) {
                            try store.saveAttempt(attempt, to: id)
                            lastCheckpoint = .now
                        }
                    },
                    onTools: { runningTools = $0 },
                    onLocalTool: { runningLocalTool = $0 },
                    onUsage: { recordUsage($0, .reply) },
                    onReplyReady: { reply in
                        try replyScope.validate()
                        let content = reply.text.isEmpty ? "服务商返回了生成文件。" : reply.text
                        let answer = ChatMessage(role: .assistant, content: content,
                                                 unavailableAttachments: reply.fileCount == 0 ? nil : reply.fileCount,
                                                 citations: reply.citations.isEmpty ? nil : reply.citations)
                        try store.complete(answer, attempt: attempt, in: id)
                        if regenerating { try? store.clearCompressionCheckpoint(scope: scope, in: id) }
                        savedReplyID = answer.id
                        streamingText = ""
                        if regenerating && selection == id {
                            searchJump = MessageJump(conversationID: id, messageID: answer.id)
                        }
                    },
                    onGeneratedFiles: { generated in
                        if let savedReplyID { try store.saveReplyAttachments(generated, to: savedReplyID, in: id) }
                    },
                    onCleanupFailure: { cleanupNotice = "服务商尚未确认清理 \($0) 个临时上传的附件。" }
                )
                if usageSaveFailed || cleanupNotice != nil {
                    self.error = [usageSaveFailed ? "回复已保存，本次部分用量未能写入。" : nil, cleanupNotice]
                        .compactMap { $0 }.joined(separator: "\n")
                }
                if !regenerating, !Task.isCancelled, let savedReplyID {
                    scheduleTitle(after: savedReplyID, in: id, using: session, bot: bot)
                }
            } catch {
                // A history deletion invalidates this request before cancellation.
                // Its late unwind must not recreate attempts or compressed text.
                guard store.activities[id] == activity else { return }
                if savedReplyID != nil {
                    self.error = ["已保存收到的回复和附件，后续处理未完成。", error.localizedDescription, cleanupNotice]
                        .compactMap { $0 }.joined(separator: "\n")
                    return
                }
                attempt.phase = attempt.phase == .submitted ? .interrupted : .failed
                if case .service(let diagnostic, _) = error as? ChatClient.ClientError {
                    attempt.diagnostic = diagnostic
                }
                do { try store.saveAttempt(attempt, to: id) }
                catch { self.error = "无法保存请求状态。\n\(error.localizedDescription)"; return }
                if !Task.isCancelled {
                    self.error = [error.localizedDescription, cleanupNotice].compactMap { $0 }.joined(separator: "\n")
                } else if let cleanupNotice {
                    self.error = cleanupNotice
                }
            }
        }
        requestTask = task
        store.setCancellation(for: activity) { task.cancel() }
    }

    private func localToolProgress(_ name: String) -> String {
        switch name {
        case "create_skill": String(localized: "正在保存本机技能…")
        case "read_attachment": String(localized: "正在读取会话附件…")
        case "delegate_to_specialist": String(localized: "正在请教另一个模型…")
        case "send_images": String(localized: "正在获取图片…")
        default: String(localized: "正在检索当前会话…")
        }
    }

    private func scheduleTitle(after replyID: UUID, in id: UUID, using session: ModelSession, bot: BotSnapshot) {
        guard UserDefaults.standard.bool(forKey: ConversationTitleRequest.enabledKey),
              let request = store.prepareTitle(for: id, after: replyID) else { return }
        let store = self.store
        let model = bot.model.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let title = try? await session.reply(to: [.init(role: .user, content: request.prompt)], forSummary: true,
                                                  validateContext: {
                guard UserDefaults.standard.bool(forKey: ConversationTitleRequest.enabledKey),
                      store.titleRequestIsCurrent(request) else { throw CancellationError() }
            }, willSend: {
                guard UserDefaults.standard.bool(forKey: ConversationTitleRequest.enabledKey),
                      store.titleRequestIsCurrent(request) else { throw CancellationError() }
            }, onUsage: { counts in
                try? store.recordUsage(counts, provider: bot.loginMethod, model: model.isEmpty ? "Copilot" : model, purpose: .title)
            })
            if let title, UserDefaults.standard.bool(forKey: ConversationTitleRequest.enabledKey) {
                try? store.saveGeneratedTitle(title, for: request)
            }
        }
    }
}
