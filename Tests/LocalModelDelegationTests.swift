import Foundation

@main @MainActor struct LocalModelDelegationTests {
    static func main() throws {
        let directory = try PrivateTemporaryDirectory()
        let store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
        let suite = "com.pendingname.aauv.fixture.delegation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let parent = BotSnapshot(name: "Parent", endpoint: "https://parent.invalid/v1", model: "parent",
                                 loginMethod: .byok, apiProtocol: "responses")
        let first = LocalBot(configuration: .init(name: "First", endpoint: "https://first.invalid/v1", model: "shared",
                                                   loginMethod: .byok, apiProtocol: "responses"))
        let second = LocalBot(configuration: .init(name: "Second", endpoint: "https://second.invalid/v1", model: "shared",
                                                    loginMethod: .byok, apiProtocol: "chat_completions"))
        let reserved = LocalBot(configuration: .init(name: "Reserved", endpoint: "https://reserved.invalid/v1", model: "reserved",
                                                      loginMethod: .byok, apiProtocol: "anthropic_messages"))
        try store.saveBots([first, second, reserved])
        defaults.set("chatgpt", forKey: "loginMethod")
        defaults.set("https://default.invalid/v1", forKey: "endpoint")
        defaults.set("inactive-byok", forKey: "model")
        defaults.set("responses", forKey: "apiProtocol")
        defaults.set("inactive-chatgpt", forKey: "chatGPTModel")
        defaults.set("synthetic-registration", forKey: ChatGPTPlanSession.selectionKey)
        let routing = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        let inactiveBYOK = try routing.resolve("inactive-byok")
        let inactiveChatGPT = try routing.resolve("inactive-chatgpt")
        let parentTarget = try routing.resolve("parent")
        precondition(inactiveBYOK.bot.loginMethod == .byok && inactiveChatGPT.bot.loginMethod == .chatgpt)
        precondition(parentTarget.bot.endpoint == parent.endpoint)
        for input in ["unconfigured", "reserved", "https://model-provided.invalid/v1", "bot:" + UUID().uuidString] {
            do { _ = try routing.resolve(input); fatalError("Unconfigured route accepted") }
            catch LocalModelDelegation.SelectionError.notConfigured {}
        }
        do { _ = try routing.resolve("shared"); fatalError("Ambiguous route silently selected") }
        catch LocalModelDelegation.SelectionError.ambiguous {}
        let selected = try routing.resolve("bot:" + second.id.uuidString.lowercased())
        precondition(selected.bot.endpoint == second.configuration.endpoint && selected.bot.apiProtocol == "chat_completions")
        try routing.validate(selected)
        precondition(routing.manifest.contains("bot:" + first.id.uuidString.lowercased()))
        precondition(!routing.manifest.contains("https://") && !routing.manifest.contains("synthetic-registration"))

        var edited = second
        edited.configuration.endpoint = "https://changed.invalid/v1"
        try store.saveBots([edited], expected: second)
        do { try routing.validate(selected); fatalError("Changed target route accepted") }
        catch LocalCloudTools.ScopeError.staleScope {}
        let selectedDefault = try routing.resolve("inactive-byok")
        defaults.set("https://changed-default.invalid/v1", forKey: "endpoint")
        do { try routing.validate(selectedDefault); fatalError("Changed default route accepted") }
        catch LocalCloudTools.ScopeError.staleScope {}

        // Equivalent routes from multiple saved bots must not cause ambiguity.
        let duplicate = LocalBot(configuration: first.configuration)
        try store.saveBots([duplicate])
        try store.deleteBot(second.id)
        let deduplicated = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        let uniqueTarget = try deduplicated.resolve("shared")
        precondition(uniqueTarget.bot.endpoint == first.configuration.endpoint)

        // Provider defaults in the nonsecret metadata survive while inactive.
        let imported = PortableSettings(endpoint: "https://selected.invalid/v1", model: "selected",
                                         loginMethod: .chatgpt, providerDefaults: .init(
                                            byokEndpoint: "https://imported.invalid/v1", byokModel: "imported-inactive",
                                            byokProtocol: "chat_completions"))
        let cache = ImportedBotMetadataCache(defaults: defaults)
        cache.record(imported)
        defaults.removeObject(forKey: "model")
        defaults.removeObject(forKey: "endpoint")
        defaults.removeObject(forKey: "apiProtocol")
        let importedRouting = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        let importedTarget = try importedRouting.resolve("imported-inactive")
        precondition(importedTarget.bot.endpoint == "https://imported.invalid/v1" && importedTarget.bot.apiProtocol == "chat_completions")
        try modelServiceRegression()
        print("Saved-service catalog routing, account isolation, endpoint/protocol identity, stale/ABA/corrupt catalog checks passed. Cloud delegation resolved captured saved/inactive/imported routes, rejected ambiguity and changed targets, and kept endpoints/registrations out of model metadata without reading credentials.")
    }
    static func modelServiceRegression() throws {
        var assertions = 0
        func check(_ value: Bool) { precondition(value); assertions += 1 }
        let directory = try PrivateTemporaryDirectory()
        let store = ConversationStore(file: directory.url.appending(path: "conversations.json"))
        let suite = "com.pendingname.aauv.fixture.service-delegation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let parent = BotSnapshot(name: "Parent", endpoint: "https://parent.invalid/v1", model: "parent",
                                 loginMethod: .byok, apiProtocol: "responses")
        var a = try ModelService(name: "Service A", loginMethod: .byok, endpoint: "https://service-a.invalid/v1/",
                                 apiProtocol: "responses", models: [.init(id: "catalog-only"), .init(id: "shared-service")]).validated()
        let b = try ModelService(name: "Service B", loginMethod: .byok, endpoint: "https://service-b.invalid/v1",
                                 apiProtocol: "chat_completions", models: [.init(id: "shared-service")]).validated()
        let c = try ModelService(name: "Service C", loginMethod: .byok, endpoint: a.endpoint,
                                 apiProtocol: "chat_completions", models: [.init(id: "shared-service")]).validated()
        let accountA = try ModelService(name: "Account A", loginMethod: .chatgpt, endpoint: "https://api.openai.com/v1",
                                        chatGPTClientID: "oaiapp_FixtureA", models: [.init(id: "account-model")]).validated()
        let accountB = try ModelService(name: "Account B", loginMethod: .chatgpt, endpoint: "https://api.openai.com/v1",
                                        chatGPTClientID: "oaiapp_FixtureB", models: [.init(id: "account-model")]).validated()
        let reserved = try ModelService(name: "Reserved service", loginMethod: .byok, endpoint: "https://reserved.invalid/v1",
                                        apiProtocol: "anthropic_messages", models: [.init(id: "reserved-service")]).validated()
        let copilot = try ModelService(name: "Copilot service", loginMethod: .copilot, endpoint: "https://github.com",
                                       models: [.init(id: "copilot-catalog")]).validated()
        let longModel = String(repeating: "x", count: 512)
        let long = try ModelService(name: "Long", loginMethod: .byok, endpoint: "https://long.invalid/v1",
                                    models: [.init(id: longModel, name: "Long model")]).validated()
        let services = [a, b, c, accountA, accountB, reserved, copilot, long]
        try ModelServices.replace(services, defaults: defaults)
        defaults.set("oaiapp_FixtureB", forKey: ChatGPTPlanSession.selectionKey)
        defaults.set("active-only", forKey: "chatGPTModel")
        defaults.set("https://default.invalid/v1", forKey: "endpoint")
        defaults.set("default-only", forKey: "model")
        defaults.set("responses", forKey: "apiProtocol")
        let captured = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        let only = try captured.resolve("catalog-only")
        check(only.bot.endpoint == a.endpoint && only.bot.model == "catalog-only")
        check(only.bot.apiProtocol == "responses" && only.bot.hostedTools == nil && only.bot.instructions == nil)
        try captured.validate(only)
        try captured.validate(captured.resolve("parent"))
        try captured.validate(captured.resolve("default-only"))
        for ambiguous in ["shared-service", "account-model"] {
            do { _ = try captured.resolve(ambiguous); fatalError("Catalog silently selected ambiguous route") }
            catch LocalModelDelegation.SelectionError.ambiguous {}
        }
        func entries(_ routing: LocalModelDelegation) throws -> [[String: String]] {
            let text = routing.manifest
            let start = text.range(of: "<aauv_delegation_metadata>\n")!.upperBound
            let end = text.range(of: "\n</aauv_delegation_metadata>")!.lowerBound
            return try JSONDecoder().decode([[String: String]].self, from: Data(text[start..<end].utf8))
        }
        func slug(_ routing: LocalModelDelegation, _ service: ModelService, _ model: String) throws -> String {
            let name = String((service.name + " · " + (service.models.first(where: { $0.id == model })!.name)).prefix(80))
            return try entries(routing).first(where: { $0["name"] == name && $0["model"] == model })!["model_slug"]!
        }
        let aliases = try [a, b, c].map { try slug(captured, $0, "shared-service") }
        check(Set(aliases).count == 3 && aliases.allSatisfy { $0.hasPrefix("service:") && $0.utf16.count <= 512 })
        for (service, alias) in zip([a, b, c], aliases) {
            let selected = try captured.resolve(alias)
            check(selected.bot.endpoint == service.endpoint && selected.bot.apiProtocol == service.apiProtocol)
            try captured.validate(selected)
        }
        let accountAliases = try [accountA, accountB].map { try slug(captured, $0, "account-model") }
        check(accountAliases[0] != accountAliases[1])
        for (service, alias) in zip([accountA, accountB], accountAliases) {
            let selected = try captured.resolve(alias)
            check(selected.bot.chatGPTClientID == service.chatGPTClientID && selected.bot.loginMethod == .chatgpt)
        }
        let longAlias = try slug(captured, long, longModel)
        let longTarget = try captured.resolve(longAlias)
        check(longAlias.utf16.count <= 512 && longTarget.bot.model == longModel)
        check(!captured.manifest.contains("https://") && !captured.manifest.contains("oaiapp_Fixture"))
        check(!captured.manifest.contains("reserved-service"))
        do { _ = try captured.resolve("reserved-service"); fatalError("Reserved protocol became delegatable") }
        catch LocalModelDelegation.SelectionError.notConfigured {}
        if CopilotClient.available {
            check(try captured.resolve("copilot-catalog").bot.loginMethod == .copilot)
        } else {
            do { _ = try captured.resolve("copilot-catalog"); fatalError("Unavailable Copilot became delegatable") }
            catch LocalModelDelegation.SelectionError.notConfigured {}
        }
        do { _ = try captured.resolve("service:" + String(repeating: "0", count: 64)); fatalError("Invented service route accepted") }
        catch LocalModelDelegation.SelectionError.notConfigured {}
        // The new alias namespace must not override an existing literal model ID.
        let collision = LocalBot(configuration: .init(name: "Literal alias", endpoint: "https://literal.invalid/v1", model: aliases[0],
                                                       loginMethod: .byok, apiProtocol: "responses"))
        let prefixed = LocalBot(configuration: .init(name: "Literal prefix", endpoint: "https://prefix.invalid/v1", model: "service:literal-model",
                                                      loginMethod: .byok, apiProtocol: "responses"))
        try store.saveBots([collision, prefixed])
        let colliding = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        do { _ = try colliding.resolve(aliases[0]); fatalError("Service alias overrode a literal model route") }
        catch LocalModelDelegation.SelectionError.ambiguous {}
        check(try colliding.resolve("bot:" + collision.id.uuidString.lowercased()).bot.endpoint == collision.configuration.endpoint)
        check(try colliding.resolve("service:literal-model").bot.endpoint == prefixed.configuration.endpoint)
        try store.deleteBot(collision.id)
        try store.deleteBot(prefixed.id)
        func stale(_ routing: LocalModelDelegation, _ target: LocalModelDelegation.Target) {
            do { try routing.validate(target); fatalError("Changed catalog target accepted") }
            catch LocalCloudTools.ScopeError.staleScope {} catch { fatalError("Unexpected stale catalog error: \(error)") }
        }
        // Changing the global active account cannot redirect an explicitly pinned service account.
        defaults.set("oaiapp_AnotherActive", forKey: ChatGPTPlanSession.selectionKey)
        let pinned = try captured.resolve(accountAliases[0])
        try captured.validate(pinned)
        check(pinned.bot.chatGPTClientID == accountA.chatGPTClientID)
        // An account, endpoint, protocol or model-list edit invalidates the captured route.
        for mutation in 0..<4 {
            try ModelServices.replace(services, defaults: defaults)
            let routing = LocalModelDelegation(store: store, current: parent, defaults: defaults)
            let target = try routing.resolve("catalog-only")
            var changed = a
            switch mutation {
            case 0: changed.endpoint = "https://edited.invalid/v1"
            case 1: changed.apiProtocol = "anthropic_messages"
            case 2: changed.models.removeAll { $0.id == "catalog-only" }
            default: changed.name = "Renamed"
            }
            try ModelServices.upsert(changed, replacing: a.id, defaults: defaults)
            stale(routing, target)
        }
        try ModelServices.replace(services, defaults: defaults)
        let accountRouting = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        let accountTarget = try accountRouting.resolve(accountAliases[0])
        var changedAccount = accountA; changedAccount.chatGPTClientID = "oaiapp_Replacement"
        try ModelServices.upsert(changedAccount, replacing: accountA.id, defaults: defaults)
        stale(accountRouting, accountTarget)
        try ModelServices.replace(services, defaults: defaults)
        let beforeDelete = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        let removed = try beforeDelete.resolve("catalog-only")
        let exactBytes = defaults.data(forKey: ModelServices.storageKey)
        try ModelServices.remove(id: a.id, defaults: defaults)
        stale(beforeDelete, removed)
        // Even restored catalog bytes cannot revive an in-flight deleted target.
        try ModelServices.upsert(a, defaults: defaults)
        defaults.set(exactBytes, forKey: ModelServices.storageKey)
        stale(beforeDelete, removed)
        // Stable aliases depend on route and model, not labels, ordering or the active provider.
        a.name = "Renamed A"
        var reordered = services.reversed().map { $0.id == a.id ? a : $0 }
        try ModelServices.replace(reordered, defaults: defaults)
        let renamed = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        check(try slug(renamed, a, "shared-service") == aliases[0])
        // Corrupt optional catalog data never prevents current/saved/default delegation.
        let saved = LocalBot(configuration: .init(name: "Independent", endpoint: "https://saved.invalid/v1", model: "saved-independent",
                                                   loginMethod: .byok, apiProtocol: "responses"))
        try store.saveBots([saved])
        let corruptValues: [Any] = [Data("broken".utf8), "wrong type", Data(repeating: 0, count: 4 * 1024 * 1024 + 1)]
        for badValue in corruptValues {
            defaults.set(badValue, forKey: ModelServices.storageKey)
            stale(renamed, try renamed.resolve("catalog-only"))
            let fallback = LocalModelDelegation(store: store, current: parent, defaults: defaults)
            try fallback.validate(fallback.resolve("parent"))
            try fallback.validate(fallback.resolve("bot:" + saved.id.uuidString.lowercased()))
            try fallback.validate(fallback.resolve("default-only"))
            do { _ = try fallback.resolve("catalog-only"); fatalError("Damaged catalog route accepted") }
            catch LocalModelDelegation.SelectionError.notConfigured {}
            if let bytes = badValue as? Data { check(defaults.data(forKey: ModelServices.storageKey) == bytes) }
            else { check(defaults.string(forKey: ModelServices.storageKey) == badValue as? String) }
        }
        // A catalog duplicate of an independently configured route adds no raw-name ambiguity.
        reordered = [try ModelService.from(parent).validated()]
        try ModelServices.replace(reordered, defaults: defaults)
        let equivalent = LocalModelDelegation(store: store, current: parent, defaults: defaults)
        check(try equivalent.resolve("parent").bot.endpoint == parent.endpoint)
        print("Saved-service positive assertions passed: \(assertions); all explicit rejection branches also passed.")
    }

}
