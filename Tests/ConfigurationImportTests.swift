import Foundation

@main
struct ConfigurationImportTests {
    private enum Interruption: Error { case beforeVault, beforePreferences, beforeCleanup }

    @MainActor static func main() throws {
        let folder = try PrivateTemporaryDirectory()
        let file = folder.url.appending(path: "conversations.json")
        let bot = LocalBot(configuration: .init(name: "导入机器人", endpoint: "https://example.invalid/v1",
                                                 model: "fixture", loginMethod: .byok, apiProtocol: "responses"))
        let prompt = BotInstructions(prompt: "合成提示词")
        let policy = ContextPolicy(threshold: 50000, hours: 12, samples: 5)
        let settings = try PortableSettings(endpoint: bot.configuration.endpoint, model: bot.configuration.model,
                                            key: "fixture-secret", hostedTools: ["web_search", "code_interpreter"], contextPolicy: policy,
                                            botInstructions: prompt, bots: [bot], localToolsEnabled: false).validated()
        let retained = try APIKey.configurationToStore(settings, previous: nil)
        let staged = try ConfigurationImport(settings: settings, vault: retained, previous: nil,
                                              incoming: settings.loginCredentials())
        let encoded = try JSONEncoder().encode(staged)
        let reopenedJournal = try JSONDecoder().decode(ConfigurationImport.self, from: encoded)
        precondition(reopenedJournal.providerDefaults.byokHostedTools == ["web_search", "code_interpreter"])
        precondition(reopenedJournal.localToolsEnabled == false)
        let plan = OAuthCredentials(flow: .chatgptPlan, accessToken: "fixture-plan-token", clientID: "fixture-registration")
        let planSettings = try PortableSettings(endpoint: "https://api.openai.com/v1", model: "fixture",
                                                loginMethod: .chatgpt, oauth: plan).validated()
        let imported = try planSettings.loginCredentials()
        let planVault = try APIKey.configurationToStore(planSettings, previous: retained)
        let planJournal = ConfigurationImport(settings: planSettings, vault: planVault, previous: retained, incoming: imported)
        let planData = try JSONEncoder().encode(planJournal)
        let reopenedPlan = try JSONDecoder().decode(ConfigurationImport.self, from: planData)
        precondition(reopenedPlan.importedChatGPTRegistrations == ["fixture-registration"] && reopenedPlan.selectsImportedChatGPT)
        var legacyPlanJournal = try JSONSerialization.jsonObject(with: planData) as! [String: Any]
        legacyPlanJournal.removeValue(forKey: "importedChatGPTRegistrations")
        let decodedLegacyPlan = try JSONDecoder().decode(ConfigurationImport.self,
                                                         from: JSONSerialization.data(withJSONObject: legacyPlanJournal))
        precondition(decodedLegacyPlan.importedChatGPTRegistrations == nil && decodedLegacyPlan.selectsImportedChatGPT)
        let store = ConversationStore(file: file)
        var cleared = false
        try reopenedJournal.finish(in: store, publish: { _ in fatalError("Published an uncommitted import") },
                                   writePreferences: { _ in fatalError("Updated preferences before commit") },
                                   clear: { cleared = true })
        precondition(cleared && store.bots.isEmpty)

        let sharedID = UUID()
        try store.saveBots([bot], instructions: prompt, configurationImportID: staged.id, sharedImportID: sharedID)
        let resumed = ConversationStore(file: file)
        let committed = try resumed.configurationImportCommitted(staged.id)
        let importedPrompt = try resumed.readInstructions()
        let shareCommitted = try resumed.sharedImportCommitted(sharedID)
        precondition(committed && shareCommitted && resumed.bots == [bot] && importedPrompt == prompt)
        let records = try resumed.pendingReplica()
        precondition(records.allSatisfy { !$0.payload.contains("fixture-secret") })

        let updated = BotInstructions(prompt: "恢复前从另一设备更新的提示词")
        try resumed.saveInstructions(updated)
        var writes = 0
        for stop in [Interruption.beforeVault, .beforePreferences, .beforeCleanup] {
            cleared = false
            do {
                try reopenedJournal.finish(in: resumed, publish: { vault in
                    if stop == .beforeVault { throw stop }
                    precondition(vault.bots == nil && vault.botInstructions == nil &&
                                 vault.credentials?.byokKeys?[settings.endpoint] == "fixture-secret")
                    writes += 1
                }, writePreferences: { pending in
                    if stop == .beforePreferences { throw stop }
                    precondition(pending.contextPolicy == policy && pending.loginMethod == .byok)
                }, clear: {
                    if stop == .beforeCleanup { throw stop }
                    cleared = true
                })
                fatalError("Expected an interrupted recovery")
            } catch let error as Interruption {
                precondition(error == stop && !cleared)
            }
        }
        try reopenedJournal.finish(in: resumed, publish: { _ in writes += 1 }, writePreferences: { _ in },
                                   clear: { cleared = true })
        let currentPrompt = try resumed.readInstructions()
        precondition(writes == 3 && cleared && currentPrompt == updated && resumed.bots == [bot])

        let failedID = UUID()
        let failedShare = UUID()
        try resumed.deleteBot(bot.id)
        do {
            try resumed.saveBots([bot], instructions: prompt, configurationImportID: failedID, sharedImportID: failedShare)
            fatalError("Expected a tombstone to roll back the import")
        } catch {
            let failedWasCommitted = try resumed.configurationImportCommitted(failedID)
            let failedShareWasCommitted = try resumed.sharedImportCommitted(failedShare)
            let previousWasCommitted = try resumed.configurationImportCommitted(staged.id)
            let unchanged = try resumed.readInstructions()
            precondition(!failedWasCommitted && !failedShareWasCommitted && previousWasCommitted && unchanged == updated)
        }
        try resumed.saveBots([bot], instructions: prompt, configurationImportID: failedID, sharedImportID: sharedID)
        let stillUncommitted = try resumed.configurationImportCommitted(failedID)
        let stillUpdated = try resumed.readInstructions()
        precondition(!stillUncommitted && resumed.bots.isEmpty && stillUpdated == updated)
        let noProfilesID = UUID()
        try resumed.saveBots([], configurationImportID: noProfilesID)
        let noProfilesCommitted = try resumed.configurationImportCommitted(noProfilesID)
        precondition(noProfilesCommitted)
        print("Configuration import recovery passed interrupted staging, SQLite rollback, shared receipts and retried publication.")
    }
}
