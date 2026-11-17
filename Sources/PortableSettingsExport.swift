import Foundation

// Export starts with one immutable public snapshot. Public files/links/backups
// never inspect the credential vault; opted-in credentials are read separately.
enum PortableSettingsExport {
    struct Snapshot: Sendable {
        let settings: PortableSettings
        let endpoints: [URL]
        let registrations: [String]
        let activeRegistration: String?
        let cachedRegistration: String?

        @MainActor init(settings: PortableSettings, profiles: [BotSnapshot], currentEndpoint: String,
                        defaults: UserDefaults = .standard) throws {
            guard settings.key == nil, settings.oauth == nil, settings.credentials == nil, settings.nodeLinks == nil else {
                throw Failure.invalidPublicSnapshot
            }
            self.settings = try settings.validated()
            let referenced = profiles + (self.settings.modelServices ?? []).map {
                $0.botSnapshot(name: $0.name, model: $0.models.first?.id ?? "")
            }
            var addresses = Set(referenced.filter { $0.loginMethod == .byok }.compactMap { try? ChatClient.baseURL($0.endpoint) })
            addresses.insert(try ChatClient.baseURL(currentEndpoint))
            endpoints = addresses.sorted { $0.absoluteString < $1.absoluteString }
            registrations = Set(referenced.filter { $0.loginMethod == .chatgpt }.compactMap(\.chatGPTClientID)).sorted()
            // nil is the legacy imported-default route, even if the same CID
            // also has native credentials. Public metadata must never select it.
            activeRegistration = defaults.string(forKey: ChatGPTPlanSession.selectionKey).flatMap { $0.isEmpty ? nil : $0 }
            cachedRegistration = ImportedBotMetadataCache.read(defaults: defaults)?.chatGPTClientID
        }

        func samePublicSettings(as other: Self) throws -> Bool {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(settings) == encoder.encode(other.settings)
                && endpoints == other.endpoints && registrations == other.registrations
                && activeRegistration == other.activeRegistration && cachedRegistration == other.cachedRegistration
        }
    }

    @MainActor static func publicBackupSettings(method: LoginMethod, bots: [LocalBot],
                                                defaults: UserDefaults = .standard) throws -> BackupSettings {
        let imported = ImportedBotMetadataCache.read(defaults: defaults)?.configuration
        let endpoint = defaults.string(forKey: "endpoint") ?? "https://api.openai.com/v1"
        let selectedChatGPT = defaults.string(forKey: "chatGPTModel").flatMap { $0.isEmpty ? nil : $0 }
            ?? ((defaults.string(forKey: ChatGPTPlanSession.selectionKey).flatMap { $0.isEmpty ? nil : $0 }) == nil
                && imported?.loginMethod == .chatgpt ? imported?.model : nil) ?? ""
        let policy = ContextPolicy(threshold: defaults.object(forKey: "contextThreshold") as? Int ?? 100000,
                                   hours: defaults.object(forKey: "contextHours") as? Int ?? 24,
                                   samples: defaults.object(forKey: "contextSamples") as? Int ?? 10)
        let preferences = try PortableAppPreferences.capture(defaults: defaults)
        let providers = ProviderDefaults(byokEndpoint: endpoint, byokModel: defaults.string(forKey: "model") ?? "",
                                         byokProtocol: defaults.string(forKey: "apiProtocol") ?? "responses",
                                         chatGPTModel: selectedChatGPT, copilotModel: defaults.string(forKey: "githubCopilotModel") ?? "",
                                         byokHostedTools: DefaultHostedTools.byok(at: endpoint, imported: imported, defaults: defaults),
                                         chatGPTHostedTools: DefaultHostedTools.chatGPT(imported: imported, defaults: defaults))
        return BackupSettings(loginMethod: method, providerDefaults: providers, contextPolicy: (try? policy.validated()) ?? .init(),
                              realtimeModel: try? RealtimeVoice.modelName(defaults.string(forKey: "realtimeModel") ?? RealtimeVoice.defaultModel),
                              automaticConversationTitles: defaults.bool(forKey: ConversationTitleRequest.enabledKey),
                              localToolsEnabled: LocalToolPreference.enabled(in: defaults),
                              defaultBotSelection: try DefaultBotSelection.capture(bots: bots, defaults: defaults),
                              selectedProxyNode: preferences.selectedProxyNode, proxyRequiresTunnel: preferences.proxyRequiresTunnel,
                              githubCopilotClientID: preferences.githubCopilotClientID, cloudSyncEnabled: preferences.cloudSyncEnabled,
                              localProfile: preferences.localProfile, modelServices: preferences.modelServices)
    }

    @MainActor static func allowsMutation(in store: ConversationStore) -> Bool {
        store.loadError == nil && !store.restoringBackup && !store.configurationUnavailable
    }

    @MainActor static func validateAccess(to store: ConversationStore, includeCredentials: Bool) throws {
        guard store.loadError == nil, !store.restoringBackup,
              !includeCredentials || allowsMutation(in: store) else { throw Failure.changed }
    }

    @MainActor static func snapshot(store: ConversationStore, method: LoginMethod? = nil,
                                    defaults: UserDefaults = .standard) throws -> Snapshot {
        try validateAccess(to: store, includeCredentials: false)
        let selected = method ?? LoginMethod(rawValue: defaults.string(forKey: "loginMethod") ?? "") ?? .byok
        var settings = try publicBackupSettings(method: selected, bots: store.bots, defaults: defaults).portableSettings()
        settings.botInstructions = try store.readInstructions()
        settings.bots = store.bots.isEmpty ? nil : store.bots
        let profiles = store.bots.map(\.configuration) + store.conversations.compactMap(\.bot)
            + (settings.defaultBotSelection?.credentialSnapshots(bots: store.bots) ?? [])
        return try Snapshot(settings: settings, profiles: profiles,
                            currentEndpoint: defaults.string(forKey: "endpoint") ?? "https://api.openai.com/v1", defaults: defaults)
    }

    struct Readers: Sendable {
        var imported: @Sendable () throws -> PortableSettings? = { try APIKey.importedConfiguration() }
        var byok: @Sendable (URL) throws -> String = { try APIKey.read(for: $0) }
        var chatGPT: @MainActor @Sendable (String?) async throws -> ChatGPTPlanSession.Selection? = {
            try await ChatGPTPlanSession.selectionForRequest(clientID: $0)
        }
        var copilot: @Sendable () throws -> OAuthCredentials? = { try APIKey.copilotCredentials() }
    }

    struct Prepared: Sendable {
        let data: Data
        let validate: @MainActor @Sendable () throws -> Void
    }

    enum Failure: LocalizedError {
        case invalidPublicSnapshot, changed, missingChatGPT, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidPublicSnapshot: return String(localized: "公开配置快照包含凭证，请重新导出。")
            case .changed: return String(localized: "导出期间设置、账户或凭证已改变，请重新导出。")
            case .missingChatGPT: return String(localized: "此 ChatGPT 注册没有可导出的本机授权。可取消包含凭证后导出配置，并在新设备重新授权。")
            case .tooLarge: return String(localized: "配置超过可导入的文件大小，请减少机器人或技能后再导出。")
            }
        }
    }

    @MainActor static func prepare(_ snapshot: Snapshot, includeCredentials: Bool,
                                   defaults: UserDefaults = .standard, readers: Readers = .init(),
                                   validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> Prepared {
        try Task.checkCancellation(); try validate()
        let scope = includeCredentials ? CredentialScope(snapshot: snapshot, defaults: defaults) : nil
        let check: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation(); try validate(); try scope?.validate()
        }
        try check()
        var settings = snapshot.settings
        if includeCredentials {
            // Capture the original active registration before other awaits. The
            // account-aware reader pins its source while its storage read waits.
            let active = try await readers.chatGPT(snapshot.activeRegistration)
            try check()
            var plans: [OAuthCredentials] = []
            if let credentials = active?.credentials {
                guard let id = credentials.clientID,
                      snapshot.activeRegistration == nil || id == snapshot.activeRegistration,
                      credentials.reauthorizationRequired != true else { throw Failure.missingChatGPT }
                scope?.remember(id)
                plans.append(credentials.transferable)
            } else if snapshot.activeRegistration != nil || snapshot.cachedRegistration != nil { throw Failure.missingChatGPT }

            let imported = try await APIKey.readInBackground(readers.imported)
            try check()
            settings.nodeLinks = imported?.nodeLinks
            var keys: [String: String] = [:]
            for address in snapshot.endpoints {
                let key = try await APIKey.readInBackground { try readers.byok(address) }
                try check()
                if !key.isEmpty { keys[address.absoluteString] = key }
            }
            for id in snapshot.registrations where id != active?.credentials.clientID {
                guard let selected = try await readers.chatGPT(id), selected.credentials.clientID == id,
                      selected.credentials.reauthorizationRequired != true else { throw Failure.missingChatGPT }
                try check(); scope?.remember(id)
                plans.append(selected.credentials.transferable)
            }
            let copilot = try await APIKey.readInBackground(readers.copilot)
            try check()
            let bundle = PortableCredentials(byokKeys: keys, chatGPT: plans, copilot: copilot?.transferable,
                                             preferredChatGPTClientID: active?.credentials.clientID)
            if !bundle.isEmpty { settings.credentials = bundle }
        }
        let captured = settings
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(captured.validated())
            guard bytes.count <= PortableSettings.maximumFileBytes else { throw Failure.tooLarge }
            try Task.checkCancellation()
            return bytes
        }
        let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try check()
        return Prepared(data: data, validate: check)
    }

    @MainActor private final class CredentialScope {
        private struct Pin { let native: Bool; let revision: String? }
        private let defaults: UserDefaults
        private let global: String?
        private let byok: String?
        private let copilot: String?
        private let configuration: String?
        private let active: String?
        private var pins: [String: Pin] = [:]

        init(snapshot: Snapshot, defaults: UserDefaults) {
            self.defaults = defaults
            global = defaults.string(forKey: APIKey.revisionKey)
            byok = defaults.string(forKey: APIKey.byokRevisionKey)
            copilot = defaults.string(forKey: APIKey.copilotRevisionKey)
            configuration = defaults.string(forKey: ProxyNodes.revisionKey)
            active = defaults.string(forKey: ChatGPTPlanSession.selectionKey)
            for id in snapshot.registrations + [snapshot.activeRegistration, snapshot.cachedRegistration].compactMap({ $0 }) { remember(id) }
        }

        func remember(_ id: String) {
            if pins[id] == nil {
                pins[id] = Pin(native: ChatGPTPlanSession.prefersNativeSource(for: id, defaults: defaults),
                               revision: APIKey.nativeChatGPTReadRevision(clientID: id, defaults: defaults))
            }
        }

        func validate() throws {
            guard global == defaults.string(forKey: APIKey.revisionKey), byok == defaults.string(forKey: APIKey.byokRevisionKey),
                  copilot == defaults.string(forKey: APIKey.copilotRevisionKey), configuration == defaults.string(forKey: ProxyNodes.revisionKey),
                  active == defaults.string(forKey: ChatGPTPlanSession.selectionKey),
                  !defaults.bool(forKey: APIKey.copilotSignOutPendingKey) else { throw Failure.changed }
            for (id, pin) in pins {
                try ChatGPTPlanSession.requireNotSigningOut(id)
                guard pin.native == ChatGPTPlanSession.prefersNativeSource(for: id, defaults: defaults),
                      pin.revision == APIKey.nativeChatGPTReadRevision(clientID: id, defaults: defaults) else { throw Failure.changed }
            }
        }
    }
}

@MainActor final class PortableExportCoordinator {
    enum Kind { case configurationFile, link, backup }
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private(set) var kind: Kind?

    func begin(_ kind: Kind) -> UUID {
        cancel()
        self.kind = kind
        return generation
    }
    func isCurrent(_ ticket: UUID) -> Bool { generation == ticket }
    func validate(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(ticket) else { throw CancellationError() }
    }
    func attach(_ task: Task<Void, Never>, to ticket: UUID) {
        if isCurrent(ticket) { self.task = task } else { task.cancel() }
    }
    func finish(_ ticket: UUID) { if isCurrent(ticket) { task = nil; kind = nil } }
    @discardableResult func cancel() -> Kind? {
        let previous = kind
        generation = UUID(); task?.cancel(); task = nil; kind = nil
        return previous
    }
}
