import Darwin
import Foundation

struct ConfigurationImport: Codable, Sendable {
    let id: UUID
    let vault: PortableSettings
    let providerDefaults: ProviderDefaults
    let loginMethod: LoginMethod?
    let contextPolicy: ContextPolicy?
    let realtimeModel: String?
    let automaticConversationTitles: Bool?
    let selectsImportedChatGPT: Bool
    let importedChatGPTRegistrations: [String]?
    let selectsImportedCopilot: Bool
    let localToolsEnabled: Bool?
    var defaultBotSelection: DefaultBotSelection?
    var selectedBotSnapshot: BotSnapshot?
    let selectedProxyNode: String?
    let proxyRequiresTunnel: Bool?
    let githubCopilotClientID: String?
    let cloudSyncEnabled: Bool?
    let localProfile: LocalDisplayProfile?
    let modelServices: [ModelService]?

    var appPreferences: PortableAppPreferences {
        .init(selectedProxyNode: selectedProxyNode, proxyRequiresTunnel: proxyRequiresTunnel,
              githubCopilotClientID: githubCopilotClientID, cloudSyncEnabled: cloudSyncEnabled,
              localProfile: localProfile, modelServices: modelServices)
    }

    @MainActor init(settings: PortableSettings, vault: PortableSettings, previous: PortableSettings?,
                    incoming: PortableCredentials) {
        id = UUID()
        self.vault = vault
        let method = settings.loginMethod ?? .byok
        var models = settings.providerDefaults ?? ProviderDefaults()
        switch method {
        case .byok:
            models.byokEndpoint = settings.endpoint
            models.byokModel = settings.model
            models.byokProtocol = settings.apiProtocol ?? "responses"
            models.byokHostedTools = HostedTool.supported(settings.hostedTools ?? models.byokHostedTools ?? [], by: .byok)
        case .chatgpt:
            models.chatGPTModel = settings.model
            models.chatGPTHostedTools = HostedTool.supported(settings.hostedTools ?? models.chatGPTHostedTools ?? [], by: .chatgpt)
        case .copilot:
            models.copilotModel = settings.model
        }
        if models.chatGPTModel == nil, (UserDefaults.standard.string(forKey: "chatGPTModel") ?? "").isEmpty,
           previous?.loginMethod == .chatgpt {
            models.chatGPTModel = previous?.model
        }
        providerDefaults = models
        loginMethod = method == .copilot && !CopilotClient.available ? nil : method
        contextPolicy = settings.contextPolicy
        realtimeModel = settings.realtimeModel
        automaticConversationTitles = settings.automaticConversationTitles
        localToolsEnabled = settings.localToolsEnabled
        defaultBotSelection = settings.defaultBotSelection
        selectedBotSnapshot = settings.defaultBotSelection?.snapshotForPublication
        selectedProxyNode = settings.selectedProxyNode
        proxyRequiresTunnel = settings.proxyRequiresTunnel
        githubCopilotClientID = settings.githubCopilotClientID
        cloudSyncEnabled = settings.cloudSyncEnabled
        localProfile = settings.localProfile
        modelServices = settings.modelServices
        selectsImportedChatGPT = method == .chatgpt && incoming.chatGPTAuthorization() != nil
        importedChatGPTRegistrations = incoming.chatGPT?.compactMap(\.clientID)
        selectsImportedCopilot = incoming.copilot != nil
    }

    @MainActor func finish(in store: ConversationStore, publish: (PortableSettings) throws -> Void,
                          writePreferences: (ConfigurationImport) throws -> Void, clear: () throws -> Void) throws {
        if try store.configurationImportCommitted(id) {
            let pending = try resolvingDefaultBotSelection(bots: store.bots)
            try publish(vault)
            try writePreferences(pending)
            pending.publishDefaultForFutureShares(in: store)
        }
        try clear()
    }

    @MainActor fileprivate func publishDefaultForFutureShares(in store: ConversationStore) {
        #if os(iOS)
        // Legacy files can change provider defaults without selecting a recent
        // bot. Publish the resolved current choice after preferences commit;
        // already queued shares retain their own entrance-time snapshot.
        DefaultBotSelection.currentBot(bots: store.bots).publishToShareInbox()
        #endif
    }

    @MainActor func persistPreferences() throws {
        let preferences = try appPreferences.validated()
        let defaults = UserDefaults.standard
        for (name, value) in [
            ("endpoint", providerDefaults.byokEndpoint), ("model", providerDefaults.byokModel),
            ("apiProtocol", providerDefaults.byokProtocol), ("chatGPTModel", providerDefaults.chatGPTModel),
            ("githubCopilotModel", providerDefaults.copilotModel), ("realtimeModel", realtimeModel),
            ("loginMethod", loginMethod?.rawValue)
        ] {
            if let value { defaults.set(value, forKey: name) }
        }
        let legacyImported = selectsImportedChatGPT ? vault.credentials?.chatGPTAuthorization()?.clientID : nil
        let imported = importedChatGPTRegistrations ?? [legacyImported].compactMap { $0 }
        if !imported.isEmpty { ChatGPTPlanSession.recordCredentialSources(imported: imported) }
        if selectsImportedChatGPT { defaults.removeObject(forKey: ChatGPTPlanSession.selectionKey) }
        if let tools = providerDefaults.byokHostedTools {
            let endpoint = providerDefaults.byokEndpoint ?? defaults.string(forKey: "endpoint") ?? "https://api.openai.com/v1"
            DefaultHostedTools.saveBYOK(tools, at: endpoint)
        }
        if let tools = providerDefaults.chatGPTHostedTools { DefaultHostedTools.saveChatGPT(tools) }
        contextPolicy?.save()
        if let localToolsEnabled { LocalToolPreference.save(localToolsEnabled) }
        if let automaticConversationTitles {
            defaults.set(automaticConversationTitles, forKey: ConversationTitleRequest.enabledKey)
        }
        try persistDefaultBotSelection()
        try preferences.persist(defaults: defaults)
        defaults.set(id.uuidString, forKey: ProxyNodes.revisionKey)
        APIKey.announceConfigurationImport(id, selectsImportedCopilot: selectsImportedCopilot)
        // Do not retire the recovery record until the preference write has reached disk.
        guard defaults.synchronize() else {
            throw ChatClient.ClientError.message("暂时无法保存本机配置。")
        }
    }

    @MainActor func persistAppPreferences(defaults: UserDefaults = .standard) throws {
        try appPreferences.persist(defaults: defaults)
    }

    @MainActor func persistDefaultBotSelection(defaults: UserDefaults = .standard) throws {
        // Legacy configurations that omit the field must not reset an existing
        // custom or saved-profile selection.
        try defaultBotSelection?.persist(snapshot: selectedBotSnapshot, defaults: defaults)
    }

    func resolvingDefaultBotSelection(bots: [LocalBot]) throws -> Self {
        guard let selection = defaultBotSelection else { return self }
        var pending = self
        let resolved = try selection.resolvingProfiles(bots)
        pending.defaultBotSelection = resolved
        pending.selectedBotSnapshot = resolved.snapshotForPublication
        return pending
    }
}

extension ConversationStore {
    func applyConfiguration(_ settings: PortableSettings, sharedImportID: UUID? = nil) throws {
        try commitConfiguration(settings, sharedImportID: sharedImportID) { id in
            try saveBots(settings.bots ?? [], instructions: settings.botInstructions, configurationImportID: id,
                         sharedImportID: sharedImportID)
        }
    }

    func settingsResolvingBotSelection(_ settings: PortableSettings, extraBots: [LocalBot] = []) throws -> PortableSettings {
        var prepared = try settings.validated()
        guard let selection = prepared.defaultBotSelection else { return prepared }
        var available = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) })
        for bot in try LocalBot.validateBatch((settings.bots ?? []) + extraBots) { available[bot.id] = bot }
        prepared.defaultBotSelection = try selection.resolvingProfiles(Array(available.values))
        return prepared
    }

    func commitConfiguration(_ settings: PortableSettings, sharedImportID: UUID? = nil, selectionBots: [LocalBot] = [],
                             updateStore: (UUID) throws -> Void) throws {
        try withConfigurationImportLock {
            try finishPendingConfigurationImport()
            if let sharedImportID, try sharedImportCommitted(sharedImportID) { return }
            let prepared = try settingsResolvingBotSelection(settings, extraBots: selectionBots)
            let pending = try APIKey.stageConfigurationImport(prepared)
            do {
                try updateStore(pending.id)
            } catch {
                try? finishPendingConfigurationImport()
                throw error
            }
            try finishPendingConfigurationImport()
        }
    }

    @discardableResult
    func resumeConfigurationImport(
        read: @escaping @Sendable () throws -> ConfigurationImport? = { try APIKey.startupConfigurationImport() },
        publish: @escaping @Sendable (PortableSettings) throws -> Void = { try APIKey.publishConfiguration($0) },
        writePreferences: @escaping @MainActor (ConfigurationImport) throws -> Void = { try $0.persistPreferences() },
        clear: @escaping @Sendable () throws -> Void = { try APIKey.clearConfigurationImport() }
    ) -> Task<Void, Never> {
        if let configurationRecoveryTask { return configurationRecoveryTask }
        configurationRecovering = true
        let task = Task { @MainActor in
            defer {
                configurationRecovering = false
                configurationRecoveryTask = nil
            }
            do {
                // Keep the cross-window/process lock through every suspension.
                // A user import must not replace the journal being recovered.
                let lock = try ConfigurationImportLock(file: file)
                defer { lock.unlock() }
                if let pending = try await APIKey.readInBackground(read) {
                    if try configurationImportCommitted(pending.id) {
                        let resolved = try pending.resolvingDefaultBotSelection(bots: bots)
                        try await APIKey.readInBackground { try publish(pending.vault) }
                        try Task.checkCancellation()
                        try writePreferences(resolved)
                        resolved.publishDefaultForFutureShares(in: self)
                    }
                    try await APIKey.readInBackground(clear)
                }
                configurationRecoveryError = nil
            } catch {
                configurationRecoveryError = (error as? DefaultBotSelection.SelectionError)?.localizedDescription
                    ?? "暂时无法完成配置导入恢复。请在会话列表重试。"
            }
        }
        configurationRecoveryTask = task
        return task
    }

    private func withConfigurationImportLock(_ action: () throws -> Void) throws {
        let lock = try ConfigurationImportLock(file: file)
        defer { lock.unlock() }
        try action()
    }

    private func finishPendingConfigurationImport() throws {
        do {
            if let pending = try APIKey.pendingConfigurationImport() {
                try pending.finish(in: self, publish: APIKey.publishConfiguration,
                                   writePreferences: { try $0.persistPreferences() },
                                   clear: APIKey.clearConfigurationImport)
            }
            configurationRecoveryError = nil
        } catch {
            let message = "暂时无法完成配置导入恢复。请在会话列表重试。"
            configurationRecoveryError = message
            throw ChatClient.ClientError.message(message)
        }
    }
}

private final class ConfigurationImportLock {
    private let descriptor: Int32

    init(file: URL) throws {
        let path = file.deletingLastPathComponent().appending(path: "configuration-import.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ChatClient.ClientError.message("应用配置或授权正在保存，请稍后重试。")
        }
        self.descriptor = descriptor
    }

    func unlock() {
        _ = flock(descriptor, LOCK_UN)
    }

    deinit { close(descriptor) }
}
