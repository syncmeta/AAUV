import Foundation

@main
struct DefaultBotMetadataTests {
    @MainActor static func main() async throws {
        let suite = "com.pendingname.aauv.fixture.default-bot.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ImportedBotMetadataCache(defaults: defaults)
        let old = try PortableSettings(endpoint: "https://example.invalid/v1", model: "old-model",
                                        loginMethod: .byok, key: "synthetic-private-key",
                                        nodeLinks: ["socks5://synthetic-node-secret@127.0.0.1:1080"],
                                        hostedTools: ["web_search", "code_interpreter"]).validated()
        let serialized = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        defaults.set(old.endpoint, forKey: "endpoint")
        defaults.set(old.model, forKey: "model")
        defaults.set("responses", forKey: "apiProtocol")

        // Seed old-version metadata on the background startup path. New and
        // discarded-journal recovery both need the previously effective vault.
        let loaded: ConfigurationImport? = try await APIKey.readInBackground {
            try APIKey.startupConfigurationImport(readPending: { nil }, readConfiguration: {
                precondition(!Thread.isMainThread)
                return try cache.readConfiguration { serialized }
            })
        }
        precondition(loaded == nil)
        let initial = BotSnapshot.activeDefaults(defaults: defaults)
        precondition(initial.model == "old-model" && initial.hostedTools == ["web_search", "code_interpreter"])
        let metadata = String(decoding: defaults.data(forKey: ImportedBotMetadataCache.key)!, as: UTF8.self)
        precondition(!metadata.contains("synthetic-private-key") && !metadata.contains("synthetic-node-secret"))
        precondition(!metadata.contains("credentials") && !metadata.contains("nodeLinks"))

        // A denied write cannot publish new defaults; successful publication
        // records them only after the vault was written.
        var replacement = old
        replacement.model = "new-model"
        replacement.hostedTools = []
        do {
            try cache.publish(replacement) { _ in throw CocoaError(.fileWriteNoPermission) }
            preconditionFailure("A failed vault write published metadata")
        } catch is CocoaError {}
        precondition(ImportedBotMetadataCache.read(defaults: defaults)?.model == "old-model")
        try cache.publish(replacement) { payload in
            precondition(payload.contains("synthetic-private-key"))
            precondition(ImportedBotMetadataCache.read(defaults: defaults)?.model == "old-model")
        }
        precondition(ImportedBotMetadataCache.read(defaults: defaults)?.model == "new-model")

        // A keychain read that began before a newer publish may return old
        // bytes. It must not overwrite the newer non-secret metadata.
        let release = DispatchSemaphore(value: 0)
        let stream = AsyncStream<Void>.makeStream()
        let delayed = Task {
            try await APIKey.readInBackground {
                try cache.readConfiguration {
                    stream.continuation.yield(())
                    precondition(release.wait(timeout: .now() + 5) == .success,
                                 "An old default-bot read blocked the main actor")
                    return serialized
                }
            }
        }
        for await _ in stream.stream.prefix(1) {}
        var latest = replacement
        latest.model = "latest-model"
        try cache.publish(latest) { _ in }
        // These UI-path lookups run while the credential actor is blocked.
        _ = BotSnapshot.activeDefaults(defaults: defaults)
        _ = BotSnapshot(name: "BYOK", endpoint: old.endpoint, model: old.model, loginMethod: .byok)
            .boundForNewChat(defaults: defaults)
        _ = BotSnapshot(name: "ChatGPT", endpoint: "https://api.openai.com/v1", model: "fixture", loginMethod: .chatgpt)
            .boundForNewChat(defaults: defaults)
        release.signal()
        _ = try await delayed.value
        precondition(ImportedBotMetadataCache.read(defaults: defaults)?.model == "latest-model")

        let first = OAuthCredentials(flow: .chatgptPlan, accessToken: "synthetic-access-1",
                                     refreshToken: "synthetic-refresh-1", clientID: "oaiapp_first")
        let second = OAuthCredentials(flow: .chatgptPlan, accessToken: "synthetic-access-2", clientID: "oaiapp_second")
        let plan = try PortableSettings(endpoint: "https://api.openai.com/v1", model: "legacy-plan-model",
                                         loginMethod: .chatgpt, hostedTools: ["web_search"],
                                         credentials: PortableCredentials(chatGPT: [first, second], preferredChatGPTClientID: second.clientID))
            .validated()
        cache.record(plan)
        defaults.set("chatgpt", forKey: "loginMethod")
        let legacyPlan = BotSnapshot.activeDefaults(defaults: defaults)
        precondition(legacyPlan.model == "legacy-plan-model" && legacyPlan.chatGPTClientID == second.clientID)
        precondition(legacyPlan.hostedTools == ["web_search"])
        defaults.set("oaiapp_native", forKey: ChatGPTPlanSession.selectionKey)
        let active = BotSnapshot.activeDefaults(defaults: defaults)
        precondition(active.chatGPTClientID == "oaiapp_native" && active.model.isEmpty)
        defaults.set("native-plan-model", forKey: "chatGPTModel")
        precondition(BotSnapshot.activeDefaults(defaults: defaults).model == "native-plan-model")
        let original = BotSnapshot(name: "Original", endpoint: plan.endpoint, model: "original-model",
                                   loginMethod: .chatgpt, chatGPTClientID: first.clientID)
        precondition(original.boundForNewChat(defaults: defaults).chatGPTClientID == first.clientID)
        var unbound = original
        unbound.chatGPTClientID = nil
        precondition(unbound.boundForNewChat(defaults: defaults).chatGPTClientID == "oaiapp_native")
        unbound.chatGPTClientID = ""
        precondition(unbound.boundForNewChat(defaults: defaults).chatGPTClientID == "oaiapp_native")
        let planMetadata = String(decoding: defaults.data(forKey: ImportedBotMetadataCache.key)!, as: UTF8.self)
        precondition(!planMetadata.contains("synthetic-access") && !planMetadata.contains("synthetic-refresh"))

        let pending = try ConfigurationImport(settings: old, vault: old, previous: nil, incoming: old.loginCredentials())
        let existing: ConfigurationImport? = try await APIKey.readInBackground {
            try APIKey.startupConfigurationImport(readPending: { pending }, readConfiguration: {
                try cache.readConfiguration { serialized }
            })
        }
        precondition(existing?.id == pending.id && ImportedBotMetadataCache.read(defaults: defaults)?.model == "old-model")
        do {
            _ = try APIKey.startupConfigurationImport(readPending: { nil }, readConfiguration: {
                throw CocoaError(.fileReadNoPermission)
            })
            preconditionFailure("Startup swallowed a failed legacy-vault read")
        } catch is CocoaError {}
        _ = try cache.readConfiguration { "" }
        precondition(ImportedBotMetadataCache.read(defaults: defaults) == nil)
        print("Default bot metadata kept secrets in Keychain, preserved account binding and legacy tools, and rejected stale reads without blocking UI lookups.")
    }
}
