import Foundation

private enum ExportFixtureError: Error { case denied }

private final class ExportFixtureCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ name: String) { lock.lock(); counts[name, default: 0] += 1; lock.unlock() }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name, default: 0] }
}

private final class ExportFixtureGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    init() { let stream = AsyncStream<Void>.makeStream(); events = stream.stream; started = stream.continuation }
    func read() throws -> PortableSettings? {
        precondition(!Thread.isMainThread, "Credential export blocked the UI thread")
        started.yield(())
        precondition(release.wait(timeout: .now() + 5) == .success, "Background read could not be released")
        return nil
    }
}

@main @MainActor struct PortableSettingsExportTests {
    nonisolated private static let first = OAuthCredentials(flow: .chatgptPlan, accessToken: "SYNTHETIC_PLAN_ACCESS_A",
        refreshToken: "SYNTHETIC_PLAN_REFRESH_A", clientID: "oaiapp_export_a", verifiedSubject: "PRIVATE_SUBJECT")
    nonisolated private static let second = OAuthCredentials(flow: .chatgptPlan, accessToken: "SYNTHETIC_PLAN_ACCESS_B",
        refreshToken: "SYNTHETIC_PLAN_REFRESH_B", clientID: "oaiapp_export_b")
    nonisolated private static let copilot = OAuthCredentials(flow: .githubCopilot, accessToken: "SYNTHETIC_COPILOT",
        refreshToken: "SYNTHETIC_COPILOT_REFRESH", clientID: "ORIGINAL_GRANT_CLIENT")
    private static let node = "socks5://fixture:SYNTHETIC_NODE_SECRET@127.0.0.1:1080"
    nonisolated private static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, file: file, line: line) }
    private static func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid export was accepted") } catch {}
    }
    private static func settings() -> PortableSettings {
        PortableSettings(endpoint: "https://synthetic.invalid/v1", model: "synthetic", loginMethod: .byok, apiProtocol: "responses")
    }
    private static func snapshot(_ defaults: UserDefaults, profiles: [BotSnapshot] = []) throws -> PortableSettingsExport.Snapshot {
        try .init(settings: settings(), profiles: profiles, currentEndpoint: "https://synthetic.invalid/v1", defaults: defaults)
    }
    private static func noSecrets(_ settings: PortableSettings) -> Bool {
        settings.key == nil && settings.oauth == nil && settings.credentials == nil && settings.nodeLinks == nil
    }
    private static func emptyReaders() -> PortableSettingsExport.Readers {
        .init(imported: { nil }, byok: { _ in "" }, chatGPT: { _ in nil }, copilot: { nil })
    }

    static func main() async throws {
        let suite = "com.pendingname.aauv.synthetic.portable-export." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try PrivateTemporaryDirectory()
        let store = ConversationStore(file: directory.url.appending(path: "chats.json"))
        let byok = LocalBot(configuration: .init(name: "fixture", endpoint: "https://synthetic.invalid/v1", model: "synthetic", loginMethod: .byok, apiProtocol: "responses"))
        let plan = LocalBot(configuration: .init(name: "plan fixture", endpoint: ChatGPTPlanSession.endpoint.absoluteString,
                                             model: "plan-model", loginMethod: .chatgpt, chatGPTClientID: second.clientID))
        try store.saveBots([byok, plan])
        try DefaultBotSelection.profile(plan.id).persist(snapshot: plan.snapshot, defaults: defaults)
        defaults.set("https://synthetic.invalid/v1", forKey: "endpoint")
        defaults.set("synthetic", forKey: "model")
        defaults.set(50000, forKey: "contextThreshold")
        defaults.set(12, forKey: "contextHours")
        defaults.set(7, forKey: "contextSamples")
        defaults.set("synthetic-voice", forKey: "realtimeModel")
        defaults.set("PUBLIC_NEW_CLIENT", forKey: "githubCopilotClientID")
        defaults.set(String(repeating: "a", count: 64), forKey: "selectedProxyNode")
        defaults.set(true, forKey: "proxyRequiresTunnel")
        defaults.set(true, forKey: "cloudSyncEnabled")
        defaults.set(true, forKey: ConversationTitleRequest.enabledKey)
        defaults.set(false, forKey: LocalToolPreference.enabledKey)
        let imported = PortableSettings(endpoint: ChatGPTPlanSession.endpoint.absoluteString, model: "imported-plan-model",
            loginMethod: .chatgpt, nodeLinks: [node], oauth: first, hostedTools: ["web_search"])
        ImportedBotMetadataCache(defaults: defaults).record(imported)

        // These default readers would inspect Keychain if executed. Public
        // snapshots/preparation must never call any reader, even a denied vault.
        // The production View invokes this entrance guard. A locked recovery
        // journal must not prevent credential-free configuration or data rescue.
        store.configurationRecoveryError = "synthetic denied storage"
        try PortableSettingsExport.validateAccess(to: store, includeCredentials: false)
        check(!PortableSettingsExport.allowsMutation(in: store))
        rejected { try PortableSettingsExport.validateAccess(to: store, includeCredentials: true) }
        let captured = try PortableSettingsExport.snapshot(store: store, defaults: defaults)
        let denied = PortableSettingsExport.Readers(imported: { throw ExportFixtureError.denied },
            byok: { _ in throw ExportFixtureError.denied }, chatGPT: { _ in throw ExportFixtureError.denied },
            copilot: { throw ExportFixtureError.denied })
        let publicFile = try await PortableSettingsExport.prepare(captured, includeCredentials: false, defaults: defaults, readers: denied, validate: {})
        // A saved service with no robot still participates in explicit credential
        // export scope; public export remains independent of all secret readers.
        var serviceSettings = settings()
        serviceSettings.modelServices = [
            ModelService(name: "Unused BYOK service", loginMethod: .byok,
                         endpoint: "https://catalog-only.invalid/v1", models: [ServiceModel(id: "catalog-model")]),
            ModelService(name: "Unused ChatGPT connection", loginMethod: .chatgpt,
                         endpoint: ChatGPTPlanSession.endpoint.absoluteString, chatGPTClientID: second.clientID,
                         models: [ServiceModel(id: "plan-catalog-model")])
        ]
        let serviceSnapshot = try PortableSettingsExport.Snapshot(settings: serviceSettings, profiles: [],
            currentEndpoint: "https://synthetic.invalid/v1", defaults: defaults)
        check(serviceSnapshot.endpoints.contains { $0.host == "catalog-only.invalid" })
        check(serviceSnapshot.registrations.contains(second.clientID!))
        let serviceFile = try await PortableSettingsExport.prepare(serviceSnapshot, includeCredentials: false,
            defaults: defaults, readers: denied, validate: {})
        let publicServices = try PortableSettings.decode(serviceFile.data)
        check(noSecrets(publicServices) && publicServices.modelServices?.count == 2)
        let decoded = try PortableSettings.decode(publicFile.data)
        check(noSecrets(decoded)); check(decoded.bots?.count == 2)
        check(decoded.defaultBotSelection?.profileID == plan.id && decoded.bots?.first(where: { $0.id == plan.id })?.configuration.chatGPTClientID == second.clientID)
        check(decoded.providerDefaults?.chatGPTModel == "imported-plan-model" && decoded.providerDefaults?.chatGPTHostedTools == ["web_search"])
        check(decoded.contextPolicy == .init(threshold: 50000, hours: 12, samples: 7))
        check(decoded.realtimeModel == "synthetic-voice" && decoded.automaticConversationTitles == true && decoded.localToolsEnabled == false)
        check(decoded.selectedProxyNode == String(repeating: "a", count: 64) && decoded.proxyRequiresTunnel == true && decoded.cloudSyncEnabled == true)
        let publicLink = try ConfigurationLink.encode(publicFile.data)
        check(noSecrets(try PortableSettings.decode(ConfigurationLink.decode(publicLink))))
        check(!String(decoding: publicFile.data, as: UTF8.self).contains("SYNTHETIC_NODE_SECRET"))
        let backupSettings = try PortableSettingsExport.publicBackupSettings(method: .chatgpt, bots: store.bots, defaults: defaults)
        check(try backupSettings.portableSettings().model == "imported-plan-model")
        let zip = try BackupFile.create(snapshot: store.backupSnapshot(settings: backupSettings), attachments: store.attachmentDirectory)
        let restored = try PreparedBackup.read(zip.url)
        check(try restored.archive.settings?.portableSettings().credentials == nil)
        check(restored.archive.settings?.defaultBotSelection?.profileID == plan.id)
        check(store.configurationRecoveryError != nil)
        store.configurationRecoveryError = nil
        store.configurationRecovering = true
        try PortableSettingsExport.validateAccess(to: store, includeCredentials: false)
        check(!PortableSettingsExport.allowsMutation(in: store))
        rejected { try PortableSettingsExport.validateAccess(to: store, includeCredentials: true) }
        store.configurationRecovering = false
        check(PortableSettingsExport.allowsMutation(in: store))
        store.restoringBackup = true
        rejected { try PortableSettingsExport.validateAccess(to: store, includeCredentials: false) }
        check(!PortableSettingsExport.allowsMutation(in: store))
        store.restoringBackup = false

        // Malformed legacy history is not part of the exported configuration.
        // It used to be skipped by the credential collector and remains skipped.
        let badHistory = BotSnapshot(name: "legacy history", endpoint: "file:///old-invalid", model: "old", loginMethod: .byok)
        let legacySnapshot = try snapshot(defaults, profiles: [badHistory])
        _ = try await PortableSettingsExport.prepare(legacySnapshot, includeCredentials: false, defaults: defaults, readers: denied, validate: {})
        check(legacySnapshot.endpoints.count == 1)

        // nil active selection is the original imported-default route. An
        // imported public CID must not turn it into an explicit native route.
        defaults.set([first.clientID!], forKey: "preferredNativeChatGPTRegistrations")
        let routing = ExportFixtureCalls()
        let nilRoute = try snapshot(defaults)
        check(nilRoute.activeRegistration == nil && nilRoute.cachedRegistration == first.clientID)
        let readers = PortableSettingsExport.Readers(imported: {
            precondition(!Thread.isMainThread); routing.record("imported"); return imported
        }, byok: { address in
            precondition(!Thread.isMainThread); routing.record("byok"); check(address.host == "synthetic.invalid"); return "SYNTHETIC_BYOK"
        }, chatGPT: { id in
            check(id == nil)
            return try await ChatGPTPlanSession.selectionForRequest(clientID: id, defaults: defaults, native: { _ in
                routing.record("native"); return first
            }, imported: { requested in
                routing.record("plan-imported"); check(requested == nil)
                var value = first; value.accessToken = "SYNTHETIC_IMPORTED_ORIGINAL"; return value
            })
        }, copilot: { precondition(!Thread.isMainThread); return copilot })
        let secretFile = try await PortableSettingsExport.prepare(nilRoute, includeCredentials: true, defaults: defaults, readers: readers, validate: {})
        let secret = try PortableSettings.decode(secretFile.data)
        check(routing.count("native") == 0 && routing.count("plan-imported") == 1)
        check(secret.credentials?.chatGPT?.first?.accessToken == "SYNTHETIC_IMPORTED_ORIGINAL")
        check(secret.credentials?.chatGPT?.first?.clientID == first.clientID && secret.credentials?.chatGPT?.first?.verifiedSubject == nil)
        check(secret.credentials?.copilot?.clientID == "ORIGINAL_GRANT_CLIENT" && secret.githubCopilotClientID == nil)
        check(secret.nodeLinks == [node] && secret.credentials?.byokKeys?["https://synthetic.invalid/v1"] == "SYNTHETIC_BYOK")
        check(try PortableSettings.decode(ConfigurationLink.decode(ConfigurationLink.encode(secretFile.data))).credentials?.copilot?.accessToken == copilot.accessToken)

        // All explicitly bound registrations are retained without rerouting a
        // profile to the active account. The public login-form App ID cannot
        // replace the original client_id inside an existing Copilot grant.
        var multiReaders = emptyReaders()
        let selectedIDs = ExportFixtureCalls()
        multiReaders.chatGPT = { id in
            selectedIDs.record(id ?? "default")
            return .init(credentials: id == second.clientID ? second : first, source: .imported)
        }
        multiReaders.copilot = { copilot }
        let multi = try await PortableSettingsExport.prepare(captured, includeCredentials: true, defaults: defaults, readers: multiReaders, validate: {})
        let multiSettings = try PortableSettings.decode(multi.data)
        check(Set(multiSettings.credentials?.chatGPT?.compactMap(\.clientID) ?? []) == [first.clientID!, second.clientID!])
        check(selectedIDs.count("default") == 1 && selectedIDs.count(second.clientID!) == 1)
        check(multiSettings.githubCopilotClientID == "PUBLIC_NEW_CLIENT" && multiSettings.credentials?.copilot?.clientID == "ORIGINAL_GRANT_CLIENT")
        for failingProvider in 0..<2 {
            var failing = multiReaders
            if failingProvider == 0 { failing.imported = { throw ExportFixtureError.denied } }
            else { failing.copilot = { throw ExportFixtureError.denied } }
            do { _ = try await PortableSettingsExport.prepare(captured, includeCredentials: true, defaults: defaults, readers: failing, validate: {}); preconditionFailure("Denied credential source silently omitted") } catch {}
        }

        // Known grant absence/reauthorization, explicit read failures, and CID
        // substitution are surfaced instead of silently dropping credentials.
        for mode in 0..<4 {
            var failing = emptyReaders()
            failing.chatGPT = { _ in
                if mode == 0 { return nil }
                if mode == 1 { throw ExportFixtureError.denied }
                if mode == 2 { var value = first; value.accessToken = ""; value.refreshToken = nil; value.reauthorizationRequired = true; return .init(credentials: value, source: .imported) }
                return .init(credentials: second, source: .native)
            }
            defaults.set(first.clientID, forKey: ChatGPTPlanSession.selectionKey)
            do {
                _ = try await PortableSettingsExport.prepare(snapshot(defaults), includeCredentials: true, defaults: defaults, readers: failing, validate: {})
                preconditionFailure("Incomplete or mismatched secret export succeeded")
            } catch {}
        }
        defaults.removeObject(forKey: ChatGPTPlanSession.selectionKey)
        var deniedReaders = emptyReaders(); deniedReaders.chatGPT = { _ in .init(credentials: first, source: .imported) }
        deniedReaders.byok = { _ in throw ExportFixtureError.denied }
        do { _ = try await PortableSettingsExport.prepare(snapshot(defaults), includeCredentials: true, defaults: defaults, readers: deniedReaders, validate: {}); preconditionFailure("Denied key silently omitted") } catch {}

        // A completed secret result also becomes unusable after any relevant
        // source/account/configuration change, before a clipboard or save action.
        for key in [APIKey.revisionKey, APIKey.byokRevisionKey, APIKey.copilotRevisionKey, ProxyNodes.revisionKey,
                    ChatGPTPlanSession.selectionKey, "preferredNativeChatGPTRegistrations", "native-version"] {
            defaults.removeObject(forKey: ChatGPTPlanSession.selectionKey)
            defaults.set([first.clientID!], forKey: "preferredNativeChatGPTRegistrations")
            var current = emptyReaders(); current.chatGPT = { _ in .init(credentials: first, source: .imported) }
            let prepared = try await PortableSettingsExport.prepare(snapshot(defaults), includeCredentials: true, defaults: defaults, readers: current, validate: {})
            if key == "native-version" { APIKey.announceNativeChatGPTWrite(clientID: first.clientID!, defaults: defaults) }
            else if key == "preferredNativeChatGPTRegistrations" { defaults.set([], forKey: key) }
            else { defaults.set(UUID().uuidString, forKey: key) }
            rejected { try prepared.validate() }
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: ChatGPTPlanSession.selectionKey)
        defaults.set([], forKey: "preferredNativeChatGPTRegistrations")
        defaults.set(true, forKey: APIKey.copilotSignOutPendingKey)
        do { _ = try await PortableSettingsExport.prepare(snapshot(defaults), includeCredentials: true, defaults: defaults, readers: emptyReaders(), validate: {}); preconditionFailure("Export during sign-out accepted") } catch {}
        defaults.removeObject(forKey: APIKey.copilotSignOutPendingKey)

        // The unavoidable synchronous storage wait runs off the main thread.
        // Cancellation, replacement intent and a changed account/version each
        // reject the old late result; no stale secret is presented.
        for mutation in 0..<5 {
            let gate = ExportFixtureGate()
            var gated = emptyReaders(); gated.chatGPT = { _ in .init(credentials: first, source: .imported) }; gated.imported = { try gate.read() }
            let readers = gated
            let coordinator = PortableExportCoordinator()
            let ticket = coordinator.begin(.link)
            var published = false
            let oldSnapshot = try snapshot(defaults)
            let task = Task { @MainActor in
                do {
                    let prepared = try await PortableSettingsExport.prepare(oldSnapshot, includeCredentials: true, defaults: defaults, readers: readers) { try coordinator.validate(ticket) }
                    try prepared.validate(); published = true
                } catch {}
                coordinator.finish(ticket)
            }
            coordinator.attach(task, to: ticket)
            for await _ in gate.events.prefix(1) {}
            var heartbeat = false; let pulse = Task { @MainActor in heartbeat = true }; await pulse.value; check(heartbeat)
            if mutation == 0 { coordinator.cancel() }
            if mutation == 1 { _ = coordinator.begin(.configurationFile) }
            if mutation == 2 { defaults.set(UUID().uuidString, forKey: APIKey.byokRevisionKey) }
            if mutation == 3 { defaults.set(second.clientID, forKey: ChatGPTPlanSession.selectionKey) }
            if mutation == 4 { APIKey.announceNativeChatGPTWrite(clientID: first.clientID!, defaults: defaults) }
            gate.release.signal(); await task.value
            check(!published)
            if mutation == 1 { check(coordinator.kind == .configurationFile) }
            defaults.removeObject(forKey: APIKey.byokRevisionKey)
            defaults.removeObject(forKey: ChatGPTPlanSession.selectionKey)
        }

        let firstSnapshot = try PortableSettingsExport.snapshot(store: store, defaults: defaults)
        defaults.set("changed-model", forKey: "model")
        check(try !firstSnapshot.samePublicSettings(as: PortableSettingsExport.snapshot(store: store, defaults: defaults)))
        var illegal = settings(); illegal.nodeLinks = [node]
        rejected { _ = try PortableSettingsExport.Snapshot(settings: illegal, profiles: [], currentEndpoint: "https://synthetic.invalid/v1", defaults: defaults) }
        print("Portable export passed: public config/link/ZIP snapshots without credential reads, legacy history skip, nil imported-default routing, strict original CID retention, background storage wait, cancel/new intent/account/provider/config/source/nonce invalidation, no stale secret publication; synthetic only.")
    }
}
