import Foundation

@main @MainActor struct PortableAppPreferencesTests {
    private enum Interrupted: Error { case preferences }
    private static let node = String(repeating: "a", count: 64)
    private static let otherNode = String(repeating: "b", count: 64)
    private static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    private static func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid portable preferences were accepted") } catch {}
    }
    private static func settings(_ preferences: PortableAppPreferences) throws -> PortableSettings {
        try PortableSettings(endpoint: "https://synthetic.invalid/v1", model: "synthetic", loginMethod: .byok,
                             providerDefaults: .init(chatGPTModel: "synthetic-plan"),
                             selectedProxyNode: preferences.selectedProxyNode, proxyRequiresTunnel: preferences.proxyRequiresTunnel,
                             githubCopilotClientID: preferences.githubCopilotClientID, cloudSyncEnabled: preferences.cloudSyncEnabled,
                             localProfile: preferences.localProfile, modelServices: preferences.modelServices).validated()
    }
    private static func backup(_ preferences: PortableAppPreferences) -> BackupSettings {
        BackupSettings(loginMethod: .byok, providerDefaults: .init(byokEndpoint: "https://synthetic.invalid/v1", byokModel: "synthetic", chatGPTModel: "synthetic-plan"),
                       contextPolicy: .init(), realtimeModel: "synthetic-voice", selectedProxyNode: preferences.selectedProxyNode,
                       proxyRequiresTunnel: preferences.proxyRequiresTunnel, githubCopilotClientID: preferences.githubCopilotClientID,
                       cloudSyncEnabled: preferences.cloudSyncEnabled, localProfile: preferences.localProfile, modelServices: preferences.modelServices)
    }
    static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        let suite = "com.pendingname.aauv.portable-app-preferences." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = PortableAppPreferences(selectedProxyNode: otherNode, proxyRequiresTunnel: false,
                                              githubCopilotClientID: "PUBLIC_OLD_APP", cloudSyncEnabled: false)
        let incoming = PortableAppPreferences(selectedProxyNode: node, proxyRequiresTunnel: true,
                                              githubCopilotClientID: "PUBLIC_NEW_APP", cloudSyncEnabled: true,
                                              localProfile: .init(name: "景山", avatarSeed: "C844C916-4AC0-4F4F-9C6A-3E2EE2F097D5"),
                                              modelServices: [ModelService(name: "Saved fixture", loginMethod: .byok,
                                                endpoint: "https://unused-service.invalid/v1", models: [ServiceModel(id: "model-one", name: "Model One"), ServiceModel(id: "model-two")])])
        try original.persist(defaults: defaults)
        check(try PortableAppPreferences.capture(defaults: defaults) == original)
        LocalDisplayProfile.prepare(defaults: defaults)
        let generated = LocalDisplayProfile.read(defaults: defaults)
        check(generated != nil && UUID(uuidString: generated!.avatarSeed) != nil)
        LocalDisplayProfile.prepare(defaults: defaults)
        check(LocalDisplayProfile.read(defaults: defaults) == generated)
        // Restore the original snapshot before testing configuration import.
        defaults.removeObject(forKey: LocalDisplayProfile.storageKey)
        let portable = try settings(incoming)
        let encoded = try JSONEncoder().encode(portable)
        let link = try ConfigurationLink.encode(encoded)
        let decoded = try PortableSettings.decode(ConfigurationLink.decode(link))
        check(decoded.appPreferences == incoming)
        check(decoded.credentials == nil && decoded.key == nil && decoded.oauth == nil && decoded.nodeLinks == nil)
        let text = String(decoding: encoded, as: UTF8.self)
        check(!text.contains("socks5://") && !text.contains("SYNTHETIC_NODE_SECRET"))
        check(decoded.appPreferences.preview.joined().contains("iCloud") && decoded.appPreferences.preview.joined().contains("不会自动连接 VPN"))
        check(decoded.appPreferences.preview.joined().contains("已有 OAuth 授权仍使用原 Client ID"))

        let snapshot = try backup(incoming).portableSettings()
        check(snapshot.appPreferences == incoming && snapshot.nodeLinks == nil && snapshot.credentials == nil)
        let source = ConversationStore(file: directory.url.appending(path: "backup-source/chats.json"))
        _ = try source.create()
        let file = try BackupFile.create(snapshot: source.backupSnapshot(settings: backup(incoming)), attachments: source.attachmentDirectory)
        let prepared = try PreparedBackup.read(file.url)
        check(try prepared.configurationForRestore(botIDMapping: [:])?.appPreferences == incoming)

        // The public login-form Client ID never replaces an existing OAuth grant's original Client ID.
        let oauth = OAuthCredentials(flow: .githubCopilot, accessToken: "gho_SYNTHETIC", refreshToken: "SYNTHETIC_REFRESH",
                                     clientID: "ORIGINAL_GRANT_APP")
        let previous = PortableSettings(endpoint: "https://synthetic.invalid/v1", model: "old", credentials: .init(copilot: oauth))
        let vault = try APIKey.configurationToStore(portable, previous: previous)
        check(vault.credentials?.copilot?.clientID == "ORIGINAL_GRANT_APP" && vault.credentials?.copilot?.refreshToken == "SYNTHETIC_REFRESH")

        let pending = ConfigurationImport(settings: portable, vault: vault, previous: previous, incoming: .init())
        let reopened = try JSONDecoder().decode(ConfigurationImport.self, from: JSONEncoder().encode(pending))
        check(reopened.appPreferences == incoming)
        let store = ConversationStore(file: directory.url.appending(path: "journal/chats.json"))
        var cleared = false
        try reopened.finish(in: store, publish: { _ in preconditionFailure("Uncommitted preferences published") },
                            writePreferences: { _ in preconditionFailure("Uncommitted preferences applied") }, clear: { cleared = true })
        check(cleared); check(try PortableAppPreferences.capture(defaults: defaults) == original)
        try store.saveBots([], configurationImportID: reopened.id)
        cleared = false
        do {
            try reopened.finish(in: store, publish: { published in check(published.credentials?.copilot?.clientID == "ORIGINAL_GRANT_APP") },
                                writePreferences: { value in try value.persistAppPreferences(defaults: defaults); throw Interrupted.preferences },
                                clear: { cleared = true })
            preconditionFailure("Interrupted preference publication returned success")
        } catch Interrupted.preferences {}
        check(!cleared); check(try PortableAppPreferences.capture(defaults: defaults) == incoming)
        try reopened.finish(in: store, publish: { _ in }, writePreferences: { try $0.persistAppPreferences(defaults: defaults) }, clear: { cleared = true })
        check(cleared); check(try PortableAppPreferences.capture(defaults: defaults) == incoming)

        // A failed SQLite import receipt must not release any preference writes.
        let failedStore = ConversationStore(file: directory.url.appending(path: "rollback/chats.json"))
        let deletedBot = LocalBot(configuration: .init(name: "deleted synthetic", endpoint: "https://synthetic.invalid/v1",
                                                      model: "synthetic", loginMethod: .byok, apiProtocol: "responses"))
        try failedStore.saveBots([deletedBot])
        try failedStore.deleteBot(deletedBot.id)
        let failedJournal = ConfigurationImport(settings: portable, vault: vault, previous: previous, incoming: .init())
        rejected { try failedStore.saveBots([deletedBot], configurationImportID: failedJournal.id) }
        let beforeRollback = try PortableAppPreferences.capture(defaults: defaults)
        try failedJournal.finish(in: failedStore, publish: { _ in preconditionFailure("Rolled-back import published vault") },
                                 writePreferences: { _ in preconditionFailure("Rolled-back import published preferences") }, clear: {})
        check(try !failedStore.configurationImportCommitted(failedJournal.id))
        check(try PortableAppPreferences.capture(defaults: defaults) == beforeRollback)

        // Legacy configuration/journals/backups omit the group and preserve all local choices.
        let legacy = try settings(.init())
        check(legacy.appPreferences == .init())
        var legacyJournal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened)) as! [String: Any]
        for key in ["selectedProxyNode", "proxyRequiresTunnel", "githubCopilotClientID", "cloudSyncEnabled", "localProfile", "modelServices"] { legacyJournal.removeValue(forKey: key) }
        let legacyDecoded = try JSONDecoder().decode(ConfigurationImport.self, from: JSONSerialization.data(withJSONObject: legacyJournal))
        try legacyDecoded.persistAppPreferences(defaults: defaults)
        check(try PortableAppPreferences.capture(defaults: defaults) == incoming)
        let legacyBackup = BackupSettings(loginMethod: .byok, providerDefaults: .init(), contextPolicy: .init(), realtimeModel: nil)
        check(try legacyBackup.portableSettings().appPreferences == .init())

        // Validation is all-or-nothing before writes; node URIs cannot occupy the public SHA reference field.
        let invalid = PortableAppPreferences(selectedProxyNode: node, proxyRequiresTunnel: false,
                                             githubCopilotClientID: "INVALID CLIENT ID", cloudSyncEnabled: false)
        rejected { try invalid.persist(defaults: defaults) }
        check(try PortableAppPreferences.capture(defaults: defaults) == incoming)
        rejected { _ = try settings(.init(selectedProxyNode: "socks5://SYNTHETIC_NODE_SECRET")) }
        rejected { _ = try settings(.init(selectedProxyNode: String(repeating: "a", count: 63))) }
        rejected { _ = try settings(.init(githubCopilotClientID: String(repeating: "x", count: 129))) }
        rejected { try PortableAppPreferences(selectedProxyNode: otherNode,
            localProfile: .init(name: " ", avatarSeed: UUID().uuidString)).persist(defaults: defaults) }
        rejected { _ = try settings(.init(localProfile: .init(name: "测试", avatarSeed: "invalid"))) }
        check(try PortableAppPreferences.capture(defaults: defaults) == incoming)
        let uppercase = try settings(.init(selectedProxyNode: node.uppercased(), githubCopilotClientID: "  PUBLIC_APP  "))
        check(uppercase.selectedProxyNode == node && uppercase.githubCopilotClientID == "PUBLIC_APP")
        try PortableAppPreferences(selectedProxyNode: "", githubCopilotClientID: "").persist(defaults: defaults)
        check(defaults.string(forKey: "selectedProxyNode") == "" && defaults.string(forKey: "githubCopilotClientID") == "")
        check(defaults.bool(forKey: "proxyRequiresTunnel") && defaults.bool(forKey: "cloudSyncEnabled"))

        // A legacy import preserves the catalog; an explicit empty array clears it.
        let serviceTicket = try ModelServices.capture(incoming.modelServices!.first!, defaults: defaults)
        try PortableAppPreferences(modelServices: []).persist(defaults: defaults)
        check(try PortableAppPreferences.capture(defaults: defaults).modelServices == [])
        defaults.set("corrupt catalog", forKey: ModelServices.storageKey)
        rejected { _ = try PortableAppPreferences.capture(defaults: defaults) }
        try incoming.persist(defaults: defaults)
        rejected { try serviceTicket.validate() } // Same Data after clear/restore must not revive an old refresh.
        rejected { try PortableAppPreferences(selectedProxyNode: otherNode, modelServices: [
            ModelService(name: "Invalid endpoint", loginMethod: .byok,
                         endpoint: "https://secret@example.invalid/v1", models: [])
        ]).persist(defaults: defaults) }
        check(try PortableAppPreferences.capture(defaults: defaults) == incoming)

        #if os(macOS)
        // No process/listener/VPN is started. An existing request route must
        // observe a newly imported fail-closed intent on its next validation.
        try PortableAppPreferences(proxyRequiresTunnel: false).persist(defaults: defaults)
        let proxy = SingBox(defaults: defaults, checkLocalProxy: { _, _ in preconditionFailure("No proxy probe allowed") })
        let captured = try proxy.requestRoute()
        try PortableAppPreferences(proxyRequiresTunnel: true).persist(defaults: defaults)
        rejected { _ = try proxy.configurationForRequest() }
        rejected { try captured.validate() }
        rejected { _ = try proxy.copilotProxyURL() }
        try PortableAppPreferences(proxyRequiresTunnel: false).persist(defaults: defaults)
        check(try proxy.configurationForRequest() == nil)
        #endif
        // Explicit imported intent must survive a later process with a different
        // registered default, even when it matches this process's fallback.
        let toolSuite = "com.pendingname.aauv.tool-preference-persistence." + UUID().uuidString
        let toolDefaults = UserDefaults(suiteName: toolSuite)!
        defer { toolDefaults.removePersistentDomain(forName: toolSuite) }
        toolDefaults.register(defaults: [LocalToolPreference.enabledKey: false])
        check(toolDefaults.persistentDomain(forName: toolSuite)?[LocalToolPreference.enabledKey] == nil)
        check(!LocalToolPreference.enabled(in: toolDefaults))
        LocalToolPreference.save(false, in: toolDefaults)
        check(toolDefaults.synchronize())
        check(toolDefaults.persistentDomain(forName: toolSuite)?[LocalToolPreference.enabledKey] as? Bool == false)
        let nextProcessDefaults = UserDefaults(suiteName: toolSuite)!
        nextProcessDefaults.register(defaults: [LocalToolPreference.enabledKey: true])
        check(!LocalToolPreference.enabled(in: nextProcessDefaults))
        check(toolDefaults.string(forKey: LocalToolPreference.revisionKey) == nil)
        LocalToolPreference.save(true, in: toolDefaults)
        check(toolDefaults.synchronize())
        check(toolDefaults.persistentDomain(forName: toolSuite)?[LocalToolPreference.enabledKey] as? Bool == true)
        let changedRevision = toolDefaults.string(forKey: LocalToolPreference.revisionKey)
        check(changedRevision.flatMap(UUID.init(uuidString:)) != nil)
        LocalToolPreference.save(true, in: toolDefaults)
        check(toolDefaults.string(forKey: LocalToolPreference.revisionKey) == changedRevision)
        print("Portable public preferences and local profile passed config/link/ZIP backup and journal replay, legacy preserve/explicit clear, validation before mutation, original OAuth Client ID retention, no node-secret export, preview and dynamic fail-closed route intent; no VPN/CloudKit/provider/real-Keychain operations.")
    }
}
