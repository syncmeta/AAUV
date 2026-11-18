import AAUVCore
import Foundation

@main
struct SyncedChatGPTEnrollmentTests {
    @MainActor static func main() throws {
        let a = "oaiapp_synthetic_A"
        let b = "oaiapp_synthetic_B"
        let c = "oaiapp_synthetic_C"
        for invalid in ["", "dynamic_agent_client", "oaiapp_", "OAIAPP_wrong", " oaiapp_space", "oaiapp_a/b",
                        "oaiapp_a\n", "oaiapp_中文", "oaiapp_" + String(repeating: "a", count: 250)] {
            precondition(!APIKey.isNativeRegistrationID(invalid))
        }
        precondition(APIKey.isNativeRegistrationID(a))
        func snapshot(_ id: String?, _ name: String = "Fixture bot", method: LoginMethod = .chatgpt) -> BotSnapshot {
            BotSnapshot(name: name, endpoint: "https://api.openai.com/v1", model: "fixture", loginMethod: method,
                        apiProtocol: "responses", chatGPTClientID: id)
        }
        func conversation(_ id: String?, _ title: String, method: LoginMethod = .chatgpt) -> Conversation {
            Conversation(title: title, bot: snapshot(id, method: method))
        }
        let firstBot = LocalBot(configuration: snapshot(a, "  Research bot  "))
        let bots = [firstBot, firstBot, LocalBot(configuration: snapshot(a, "Second bot")),
                    LocalBot(configuration: snapshot(b, "Other registration")),
                    LocalBot(configuration: snapshot("invalid", "Invalid")),
                    LocalBot(configuration: snapshot(a, "BYOK reference", method: .byok))]
        let firstChat = conversation(a, "Research notes")
        let chats = [firstChat, firstChat, conversation(a, "Later notes"), conversation(c, "Orphaned chat"),
                     conversation(nil, "Unbound legacy chat"), conversation("oaiapp_", "Invalid empty suffix"),
                     conversation(b, "Copilot", method: .copilot)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let originalBots = try encoder.encode(bots)
        let originalChats = try encoder.encode(chats)
        let references = SyncedChatGPTEnrollment.references(bots: bots, conversations: chats)
        precondition(Set(references.map(\.clientID)) == [a, b, c])
        let referenceA = references.first { $0.clientID == a }!
        precondition(referenceA.botCount == 2 && referenceA.conversationCount == 2)
        precondition(referenceA.botNames.contains("Research bot") && referenceA.conversationTitles == ["Later notes", "Research notes"])
        let orphan = references.first { $0.clientID == c }!
        precondition(orphan.botCount == 0 && orphan.conversationCount == 1)
        precondition(references.allSatisfy { $0.displayName?.contains($0.clientID) != true })
        precondition(SyncedChatGPTEnrollment.missingReferences(references, knownLocalRegistrations: nil) == nil)
        let unknownTarget = SyncedChatGPTEnrollment.requestedClientID(a, references: references, knownLocalRegistrations: nil)
        precondition(unknownTarget == nil)
        let emptyLocal = SyncedChatGPTEnrollment.missingReferences(references, knownLocalRegistrations: [])!
        precondition(emptyLocal.count == 3)
        let missing = SyncedChatGPTEnrollment.missingReferences(references, knownLocalRegistrations: [a])!
        precondition(Set(missing.map(\.clientID)) == [b, c])
        // A saved registration with cleared/expired tokens remains represented
        // by its ID and continues through the existing reauthorization UI.
        let localReauthorizationRecord = ChatGPTPlanSession.Account(id: a, email: nil)
        let existing = Set([localReauthorizationRecord.id, b, c])
        precondition(SyncedChatGPTEnrollment.missingReferences(references, knownLocalRegistrations: existing)?.isEmpty == true)
        precondition(SyncedChatGPTEnrollment.requestedClientID(a, references: references, knownLocalRegistrations: [a]) == nil)
        precondition(SyncedChatGPTEnrollment.requestedClientID("oaiapp_not_referenced", references: references, knownLocalRegistrations: []) == nil)
        let target = SyncedChatGPTEnrollment.requestedClientID(a, references: references, knownLocalRegistrations: [b])
        precondition(target == a) // Another local registration never substitutes for this exact reference.
        let unchangedBots = try encoder.encode(bots)
        let unchangedChats = try encoder.encode(chats)
        precondition(originalBots == unchangedBots && originalChats == unchangedChats)

        // A model catalog can arrive before any bot/chat, without credentials.
        let serviceOnlyID = "oaiapp_service_only"
        let catalog = ModelService(name: "Synced service", loginMethod: .chatgpt,
                                   endpoint: "https://api.openai.com/v1", chatGPTClientID: serviceOnlyID,
                                   models: [ServiceModel(id: "synthetic-model")])
        let serviceOnly = try SyncedChatGPTEnrollment.references(bots: [], conversations: [], services: [catalog])
        precondition(serviceOnly.count == 1 && serviceOnly[0].clientID == serviceOnlyID)
        precondition(serviceOnly[0].serviceCount == 1 && serviceOnly[0].botCount == 0 && serviceOnly[0].conversationCount == 0)
        precondition(serviceOnly[0].displayName == "Synced service")
        var sharedService = catalog; sharedService.chatGPTClientID = a
        let mixed = try SyncedChatGPTEnrollment.references(bots: bots, conversations: chats, services: [sharedService, catalog])
        precondition(mixed.filter { $0.clientID == a }.count == 1)
        precondition(mixed.first { $0.clientID == a }!.serviceCount == 1)
        precondition(mixed.first { $0.clientID == a }!.botCount == referenceA.botCount)
        let byokService = ModelService(name: "BYOK", loginMethod: .byok, endpoint: "https://example.com/v1")
        let excludedServices = try SyncedChatGPTEnrollment.references(bots: [], conversations: [], services: [byokService])
        precondition(excludedServices.isEmpty)
        var latestServices = [catalog]
        func freshReferences() throws -> [SyncedChatGPTEnrollment.Reference] {
            try SyncedChatGPTEnrollment.references(bots: [], conversations: [], services: latestServices)
        }
        let resumedService = try SyncedChatGPTEnrollment.requestedClientID(serviceOnlyID, knownLocalRegistrations: [a], latestReferences: freshReferences)
        precondition(resumedService == serviceOnlyID) // Never substitute another local account.
        latestServices = []
        let staleDeleted = try SyncedChatGPTEnrollment.requestedClientID(serviceOnlyID, knownLocalRegistrations: [], latestReferences: freshReferences)
        precondition(staleDeleted == nil) // Click must re-read, not trust the shown row.
        latestServices = [sharedService]
        let staleReplaced = try SyncedChatGPTEnrollment.requestedClientID(serviceOnlyID, knownLocalRegistrations: [], latestReferences: freshReferences)
        precondition(staleReplaced == nil)
        var damaged = catalog; damaged.chatGPTClientID = "invalid_registration"
        latestServices = [damaged]
        do {
            _ = try SyncedChatGPTEnrollment.requestedClientID(serviceOnlyID, knownLocalRegistrations: [], latestReferences: freshReferences)
            preconditionFailure("A damaged catalog must surface an error, not an empty registry or stale authorization target")
        } catch { }
        latestServices = [catalog]
        let unknownCredentials = try SyncedChatGPTEnrollment.requestedClientID(serviceOnlyID, knownLocalRegistrations: nil, latestReferences: freshReferences)
        precondition(unknownCredentials == nil)

        let directory = try PrivateTemporaryDirectory()
        let storeA = ConversationStore(file: directory.url.appending(path: "a/conversations.json"))
        let storeB = ConversationStore(file: directory.url.appending(path: "b/conversations.json"))
        try storeA.saveBots([firstBot])
        let id = try storeA.create(bot: firstBot.snapshot)
        try storeA.append(ChatMessage(role: .user, content: "synthetic question"), to: id)
        try storeA.prepareReplica()
        for record in try storeA.pendingReplica() {
            try storeB.applyReplicaPayload(.inline(ReplicaPacket(record: record, files: [:])))
            try storeA.acknowledgeReplica(name: record.name, revision: record.revision)
        }
        try storeB.reloadReplica()
        let savedBots = try encoder.encode(storeB.bots)
        let savedChats = try encoder.encode(storeB.conversations)
        let before = try storeB.pendingReplicaCount()
        let synced = SyncedChatGPTEnrollment.references(bots: storeB.bots, conversations: storeB.conversations)
        precondition(synced.count == 1 && synced[0].botCount == 1 && synced[0].conversationCount == 1)
        let resumed = SyncedChatGPTEnrollment.requestedClientID(a, references: synced, knownLocalRegistrations: [b])
        precondition(resumed == a)
        let after = try storeB.pendingReplicaCount()
        let currentBots = try encoder.encode(storeB.bots)
        let currentChats = try encoder.encode(storeB.conversations)
        precondition(before == after && savedBots == currentBots && savedChats == currentChats)
        precondition(storeB.conversations.first?.bot?.chatGPTClientID == a)
        if CommandLine.arguments.contains("--loopback") {
            try verifyExistingCoreResume(resumed!)
            print("Synced registration collection, unknown/local account filtering, unchanged SQLite replicas and same-CID new-host authorization construction passed.")
        } else {
            print("Synced registration collection, unknown/local account filtering and unchanged SQLite replicas passed; loopback construction was not requested.")
        }
    }

    private static func verifyExistingCoreResume(_ client: String) throws {
        let originalHost = "urn:uuid:11111111-1111-4111-8111-111111111111"
        let host = "urn:uuid:22222222-2222-4222-8222-222222222222"
        var originalError: NSError?
        guard let originalAttempt = AauvcoreBeginChatGPTSignIn(originalHost, client, "", &originalError) else {
            throw originalError ?? CocoaError(.fileReadUnknown)
        }
        defer { originalAttempt.cancel() }
        let originalURL = URLComponents(string: originalAttempt.authorizationURL())!
        let originalQuery = Dictionary(uniqueKeysWithValues: (originalURL.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var error: NSError?
        guard let attempt = AauvcoreBeginChatGPTSignIn(host, client, "", &error) else {
            throw error ?? CocoaError(.fileReadUnknown)
        }
        defer { attempt.cancel() }
        let url = URLComponents(string: attempt.authorizationURL())!
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        precondition(url.scheme == "https" && url.host == "auth.openai.com")
        precondition(query["client_id"] == client && query["ext_agent_host_id"] == host)
        precondition(originalQuery["client_id"] == client && originalQuery["ext_agent_host_id"] == originalHost)
        precondition(query["ext_agent_host_id"] != originalQuery["ext_agent_host_id"])
        precondition(query["state"] != originalQuery["state"] && query["nonce"] != originalQuery["nonce"])
        precondition(query["code_challenge"] != originalQuery["code_challenge"])
        precondition(query["id_token_hint"] == nil && query["agent_name_hint"] == nil)
        precondition(query["code_challenge_method"] == "S256")
        let callback = URLComponents(string: query["redirect_uri"]!)!
        precondition(callback.scheme == "http" && callback.host == "127.0.0.1" && callback.path == "/auth/callback")
        // Deliberately do not open the URL, submit a callback or contact OpenAI.
    }
}
