import Foundation

@main @MainActor
struct DefaultBotSelectionTests {
    private enum Interruption: Error { case preferences }
    private static func expect(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(condition, file: file, line: line)
    }
    private static func custom(_ name: String = "Independent") -> BotSnapshot {
        .init(name: name, endpoint: "https://independent.invalid/v1", model: "independent-model", loginMethod: .byok,
              apiProtocol: "responses", instructions: .init(prompt: "Independent instructions"))
    }
    private static func settings(_ choice: DefaultBotSelection?) -> PortableSettings {
        var value = PortableSettings(endpoint: "https://default.invalid/v1", model: "default-model", loginMethod: .byok)
        value.defaultBotSelection = choice
        return value
    }
    private static func reject(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Invalid selection or copy mapping was accepted") } catch {}
    }

    static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        let suite = "com.pendingname.aauv.default-selection-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("byok", forKey: "loginMethod")
        defaults.set("https://fallback.invalid/v1", forKey: "endpoint")
        defaults.set("fallback-model", forKey: "model")
        try roundTripsAndCredentialReferences(defaults: defaults)
        try journalAndLatestProfile(in: directory.url, defaults: defaults)
        try await backupProfileCopies(in: directory.url, defaults: defaults)
        try invalidCopyMappings(in: directory.url)
        try await queuedShareKeepsEntranceSnapshot(in: directory.url, defaults: defaults)
        print("Default bot selection preserved optional legacy behavior, profile/latest/custom/fallback semantics, configuration/link/backup round trips, credential dependency references, journal recovery with private defaults, remapped profile copies, rejected invalid mappings without mutation, and entrance-time shared-file snapshots.")
    }

    private static func roundTripsAndCredentialReferences(defaults: UserDefaults) throws {
        let independent = custom()
        DefaultBotSelection.remember(independent, bots: [], defaults: defaults)
        let captured = try DefaultBotSelection.capture(bots: [], defaults: defaults)
        expect(captured == .custom(independent))
        var spaced = independent
        spaced.name = "  Canonical name  "
        spaced.endpoint = " https://canonical.invalid/v1/ "
        let canonical = try DefaultBotSelection.custom(spaced).validated()
        expect(canonical.snapshot?.name == "Canonical name" && canonical.snapshot?.endpoint == "https://canonical.invalid/v1")
        expect(canonical.credentialSnapshots(bots: []).first?.endpoint == "https://canonical.invalid/v1")
        let portable = try settings(captured).validated()
        let encoded = try JSONEncoder().encode(portable)
        let decoded = try PortableSettings.decode(ConfigurationLink.decode(ConfigurationLink.encode(encoded)))
        expect(decoded.defaultBotSelection == captured)
        expect(decoded.credentials == nil && decoded.key == nil && decoded.oauth == nil)
        let refs = decoded.defaultBotSelection!.credentialSnapshots(bots: [])
        let fakeKeys = [independent.endpoint: "fixture-selected-key"]
        let exported = Dictionary(uniqueKeysWithValues: refs.filter { $0.loginMethod == .byok }.compactMap { bot in
            fakeKeys[bot.endpoint].map { (bot.endpoint, $0) }
        })
        expect(exported[independent.endpoint] == "fixture-selected-key")
        expect(!String(decoding: encoded, as: UTF8.self).contains("fixture-selected-key"))
        var withKeys = decoded
        withKeys.credentials = .init(byokKeys: exported)
        let keyed = try PortableSettings.decode(JSONEncoder().encode(withKeys))
        expect(keyed.credentials?.byokKeys?[independent.endpoint] == "fixture-selected-key")

        var plan = custom("Original ChatGPT")
        plan.loginMethod = .chatgpt
        plan.endpoint = "https://api.openai.com/v1"
        plan.chatGPTClientID = "original-registration"
        plan.endpoint = "https://must-not-be-used.invalid/v1"
        plan.hostedTools = ["web_search", "code_interpreter", "image_generation"]
        let planChoice = try DefaultBotSelection.custom(plan).validated()
        expect(planChoice.snapshot?.endpoint == "https://api.openai.com/v1" && planChoice.snapshot?.hostedTools == ["web_search"])
        let plans = planChoice.credentialSnapshots(bots: []).compactMap(\.chatGPTClientID)
        expect(plans == ["original-registration"])
        let fakeOAuth = OAuthCredentials(flow: .chatgptPlan, accessToken: "fixture-selected-oauth", clientID: plans[0])
        var planExport = settings(planChoice)
        planExport.credentials = .init(chatGPT: [fakeOAuth])
        let planDecoded = try PortableSettings.decode(JSONEncoder().encode(planExport))
        expect(planDecoded.defaultBotSelection?.snapshot?.chatGPTClientID == "original-registration")
        expect(planDecoded.credentials?.chatGPT?.first?.accessToken == "fixture-selected-oauth")
        expect(!planChoice.preview(bots: []).contains("original-registration"))
        plan.chatGPTClientID = nil
        reject { _ = try DefaultBotSelection.custom(plan).validated() }
        let unbound = LocalBot(configuration: plan)
        reject { _ = try DefaultBotSelection.profile(unbound.id).resolvingProfiles([unbound]) }

        var legacy = independent
        legacy.apiProtocol = nil
        expect(try DefaultBotSelection.custom(legacy).validated().snapshot?.apiProtocol == "chat_completions")
        let missing = UUID()
        defaults.set(try JSONEncoder().encode(BotSnapshot(name: "Gone", endpoint: independent.endpoint, model: "gone",
                                                         loginMethod: .byok, profileID: missing)), forKey: "recentBot")
        expect(DefaultBotSelection.currentBot(bots: [], defaults: defaults).model == "fallback-model")
        expect(try DefaultBotSelection.capture(bots: [], defaults: defaults) == .providerDefault)
        for text in [#"{"mode":"custom"}"#, #"{"mode":"defaults","profileID":"ABCDEF01-0000-4000-8000-000000000000"}"#] {
            reject { _ = try JSONDecoder().decode(DefaultBotSelection.self, from: Data(text.utf8)).validated() }
        }
    }

    private static func journalAndLatestProfile(in root: URL, defaults: UserDefaults) throws {
        let store = ConversationStore(file: root.appending(path: "configuration/conversations.json"))
        let profile = LocalBot(configuration: custom("Saved profile"))
        try store.saveBots([profile])
        let original = custom("Keep until committed")
        DefaultBotSelection.remember(original, bots: store.bots, defaults: defaults)
        let before = defaults.data(forKey: "recentBot")
        let incoming = try store.settingsResolvingBotSelection(settings(.profile(profile.id)))
        let data = try JSONEncoder().encode(incoming)
        let selectionJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let pointer = selectionJSON["defaultBotSelection"] as! [String: Any]
        expect(pointer["snapshot"] == nil && pointer["resolvedProfile"] == nil)
        let pending = ConfigurationImport(settings: incoming, vault: incoming, previous: nil, incoming: .init())
        let journal = try JSONDecoder().decode(ConfigurationImport.self, from: JSONEncoder().encode(pending))
        expect(journal.selectedBotSnapshot == profile.snapshot)
        var cleared = false
        try journal.finish(in: store, publish: { _ in fatalError("Uncommitted vault published") },
                           writePreferences: { _ in fatalError("Uncommitted selection published") }, clear: { cleared = true })
        expect(cleared && defaults.data(forKey: "recentBot") == before)
        try store.saveBots([profile], configurationImportID: pending.id)
        var latest = profile
        latest.configuration.name = "Latest profile version"
        latest.configuration.model = "latest-model"
        try store.saveBots([latest], expected: profile)
        do {
            try journal.finish(in: store, publish: { _ in }, writePreferences: { _ in throw Interruption.preferences }, clear: {})
            fatalError("Interrupted preference publication returned success")
        } catch Interruption.preferences {}
        expect(defaults.data(forKey: "recentBot") == before)
        try journal.finish(in: store, publish: { _ in }, writePreferences: { try $0.persistDefaultBotSelection(defaults: defaults) }, clear: {})
        expect(DefaultBotSelection.currentBot(bots: store.bots, defaults: defaults) == latest.snapshot)
        var another = latest
        another.configuration.model = "profile-edited-again"
        try store.saveBots([another], expected: latest)
        expect(DefaultBotSelection.currentBot(bots: store.bots, defaults: defaults).model == "profile-edited-again")
        let selected = defaults.data(forKey: "recentBot")
        let legacy = ConfigurationImport(settings: settings(nil), vault: settings(nil), previous: nil, incoming: .init())
        try legacy.persistDefaultBotSelection(defaults: defaults)
        expect(defaults.data(forKey: "recentBot") == selected)
        reject { _ = try store.settingsResolvingBotSelection(settings(.profile(UUID()))) }
        try store.deleteBot(profile.id)
        reject { _ = try store.settingsResolvingBotSelection(settings(.profile(profile.id))) }
        reject { _ = try journal.resolvingDefaultBotSelection(bots: store.bots) }
        expect(DefaultBotSelection.currentBot(bots: store.bots, defaults: defaults).model == "fallback-model")
        try DefaultBotSelection.providerDefault.persist(snapshot: nil, defaults: defaults)
        expect(defaults.data(forKey: "recentBot") == nil)
        let oldJSON = Data(#"{"version":1,"endpoint":"https://default.invalid/v1","model":"legacy"}"#.utf8)
        expect(try PortableSettings.decode(oldJSON).defaultBotSelection == nil)
    }

    private static func backupProfileCopies(in root: URL, defaults: UserDefaults) async throws {
        let source = ConversationStore(file: root.appending(path: "backup-source/conversations.json"))
        let profile = LocalBot(configuration: custom("Backed-up profile"))
        try source.saveBots([profile])
        _ = try source.create(bot: profile.snapshot)
        let backupSettings = BackupSettings(loginMethod: .byok, providerDefaults: .init(byokEndpoint: profile.configuration.endpoint,
                                                                                     byokModel: profile.configuration.model),
                                            contextPolicy: .init(), realtimeModel: nil, defaultBotSelection: .profile(profile.id))
        let archive = try source.backupSnapshot(settings: backupSettings)
        let zip = try BackupFile.create(snapshot: archive, attachments: source.attachmentDirectory)
        let decoded = try PreparedBackup.read(zip.url)
        expect(decoded.archive.settings?.defaultBotSelection == .profile(profile.id))
        let target = ConversationStore(file: root.appending(path: "backup-target/conversations.json"))
        let copiedID = UUID()
        let mapping = [profile.id: copiedID]
        let restored = try decoded.configurationForRestore(botIDMapping: mapping)!
        var copiedProfile = profile
        copiedProfile.id = copiedID
        let prepared = try target.settingsResolvingBotSelection(restored, extraBots: [copiedProfile])
        let pending = ConfigurationImport(settings: prepared, vault: prepared, previous: nil, incoming: .init())
        expect(try target.importCopies(decoded.archive.conversations, bots: decoded.archive.bots ?? [], botIDMapping: mapping,
                                       configurationImportID: pending.id))
        let reopened = ConversationStore(file: target.file)
        try pending.finish(in: reopened, publish: { _ in }, writePreferences: { try $0.persistDefaultBotSelection(defaults: defaults) }, clear: {})
        expect(DefaultBotSelection.currentBot(bots: reopened.bots, defaults: defaults).profileID == copiedID)
        expect(reopened.conversations.first?.bot?.profileID == copiedID && copiedID != profile.id)
        reject { _ = try decoded.configurationForRestore(botIDMapping: [:]) }
        var legacyArchive = archive
        legacyArchive.version = 1
        legacyArchive.files = [:]
        let legacyData = try JSONEncoder().encode(legacyArchive)
        let legacyDecoded = try JSONDecoder().decode(PortableArchive.self, from: legacyData)
        expect(try PreparedBackup.legacy(legacyDecoded).configurationForRestore(botIDMapping: mapping)?.defaultBotSelection == .profile(copiedID))
        let before = defaults.data(forKey: "recentBot")
        let withoutSettings = ConversationStore(file: root.appending(path: "backup-ignore-settings/conversations.json"))
        try await withoutSettings.importBackup(decoded, restoreSettings: false)
        expect(defaults.data(forKey: "recentBot") == before)
    }

    private static func invalidCopyMappings(in root: URL) throws {
        let store = ConversationStore(file: root.appending(path: "invalid-maps/conversations.json"))
        let existing = LocalBot(configuration: custom("Existing"))
        try store.saveBots([existing])
        let first = LocalBot(configuration: custom("First"))
        let second = LocalBot(configuration: custom("Second"))
        let duplicate = UUID()
        let bad: [[UUID: UUID]] = [
            [first.id: UUID()],
            [first.id: duplicate, second.id: duplicate],
            [first.id: existing.id, second.id: UUID()],
            [first.id: first.id, second.id: UUID()]
        ]
        let pending = try store.pendingReplicaCount()
        for map in bad {
            reject { _ = try store.importCopies([], bots: [first,second], botIDMapping: map) }
            expect(store.bots == [existing] && store.conversations.isEmpty)
            expect(try store.pendingReplicaCount() == pending)
        }
    }

    private static func queuedShareKeepsEntranceSnapshot(in root: URL, defaults: UserDefaults) async throws {
        let inbox = ShareInbox(root: root.appending(path: "private-inbox"))
        let entered = custom("At file entrance")
        let enteredData = try JSONEncoder().encode(entered)
        let input = root.appending(path: "queued.bin")
        try Data([0,255,42]).write(to: input)
        let stage = try inbox.begin(botSnapshot: enteredData)
        try inbox.copy(input, name: "queued.bin", index: 0, into: stage)
        try inbox.publish(stage)
        let replacement = custom("Imported later")
        try DefaultBotSelection.custom(replacement).persist(snapshot: replacement, defaults: defaults)
        try inbox.rememberBotSnapshot(JSONEncoder().encode(replacement))
        let item = try inbox.pending()[0]
        expect(item.botSnapshot == enteredData)
        let store = ConversationStore(file: root.appending(path: "queued-target/conversations.json"))
        let staged = try await store.stageFileOpen(item.file)
        let id = try store.openFile(staged, bot: replacement, capturedBot: item.botSnapshot)
        expect(store.conversations.first(where: { $0.id == id })?.bot == entered)
    }
}
