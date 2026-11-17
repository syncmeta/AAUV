import Foundation
import CoreTransferable

@main
struct PortableDataTests {
    @MainActor
    static func main() async throws {
        let data = Data(#"{"format":"aauv-config","version":2,"endpoint":"https://example.invalid/v1","model":"test","loginMethod":"byok","key":"example-only"}"#.utf8)
        let link = try ConfigurationLink.encode(data)
        let decoded = try ConfigurationLink.decode(link)
        precondition(decoded == data)
        let settings = try JSONDecoder().decode(PortableSettings.self, from: decoded).validated()
        precondition(settings.key == "example-only")
        precondition(settings.loginMethod == .byok)
        let oauth = OAuthCredentials(flow: .chatgptPlan, accessToken: "fake-access-token",
                                     refreshToken: "fake-refresh-token", clientID: "test-client",
                                     expiresAt: 2_000_000_000, scopes: ["chatgpt.tokens.use.direct"])
        let oauthSettings = try PortableSettings(endpoint: "https://api.openai.com/v1",
                                                model: "test", loginMethod: .chatgpt, oauth: oauth).validated()
        let oauthLink = try ConfigurationLink.encode(JSONEncoder().encode(oauthSettings))
        let restoredSettings = try JSONDecoder().decode(PortableSettings.self, from: ConfigurationLink.decode(oauthLink))
        precondition(restoredSettings.oauth?.refreshToken == oauth.refreshToken)
        precondition(restoredSettings.oauth?.clientID == oauth.clientID)
        var mismatched = oauthSettings
        mismatched.loginMethod = .copilot
        precondition((try? mismatched.validated()) == nil)
        let old = Data(#"{"version":1,"endpoint":"https://example.invalid/v1","model":"test","offline":true}"#.utf8)
        _ = try JSONDecoder().decode(PortableSettings.self, from: old).validated()
        precondition((try? ConfigurationLink.decode("aauv://import?v=2&v=2&c=none#e30")) == nil)
        precondition((try? ConfigurationLink.decode("aauv://import?v=999&c=none#e30")) == nil)
        precondition((try? ConfigurationLink.decode("aauv://import?v=2&c=zlib#e30")) == nil)
        let huge = Data(repeating: 65, count: ConfigurationLink.maximumBytes + 1)
        precondition((try? ConfigurationLink.encode(huge)) == nil)

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "sample.unknown-extension")
        let original = Data([0, 255, 42, 128, 12])
        try original.write(to: source)
        let store = ConversationStore(file: root.appending(path: "original/conversations.json"))
        let bot = BotSnapshot(name: "Test bot", endpoint: "https://example.invalid/v1", model: "test",
                              loginMethod: .byok, apiProtocol: "responses",
                              instructions: BotInstructions(prompt: "机器人专用提示词", skills: ""))
        let profile = LocalBot(configuration: bot)
        try store.saveBots([profile])
        let stagedSource = try await store.stageFileOpen(source)
        let id = try store.openFile(stagedSource, bot: profile.snapshot)
        let conversation = store.conversations.first!
        precondition(conversation.id == id && conversation.bot?.name == bot.name)
        // The native SwiftUI Transferable exporter constructs a FileWrapper.
        // A valid ZIP URL alone does not supply suggested filename metadata.
        if #available(macOS 15.2, iOS 18.2, *) {
            let transferredBackup = try BackupFile.create(snapshot: store.backupSnapshot(), attachments: store.attachmentDirectory)
            precondition(transferredBackup.suggestedFilename == transferredBackup.url.lastPathComponent)
            let originalZIP = try Data(contentsOf: transferredBackup.url)
            let roundTripZIP = root.appending(path: "transfer-roundtrip.aauvbackup")
            try await transferredBackup.withExportedFile(contentType: .aauvBackup) { file in
                let wrapper = try FileWrapper(url: file, options: .immediate)
                guard let name = transferredBackup.suggestedFilename, !name.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                wrapper.preferredFilename = name
                try wrapper.write(to: roundTripZIP, options: .atomic, originalContentsURL: nil)
            }
            let transferredBytes = try Data(contentsOf: roundTripZIP)
            precondition(transferredBytes == originalZIP)
            try PreparedBackup.read(roundTripZIP).validate()
            print("Backup Transferable supplied the actual ZIP basename; Foundation FileWrapper export preserved valid ZIP bytes.")
        }
        try FileManager.default.removeItem(at: source)
        let user = ChatMessage(role: .user, content: "生成文件")
        try store.append(user, to: id)
        let attempt = ReplyAttempt(userMessageID: user.id, phase: .submitted)
        try store.saveAttempt(attempt, to: id)
        let generated = Data([80, 78, 71, 10, 0, 255])
        let answer = ChatMessage(role: .assistant, content: "已生成", unavailableAttachments: 2)
        try store.complete(answer, attempt: attempt, in: id)
        try store.saveReplyAttachments(.init(files: [.init(name: "../plots\\plot.png", data: generated)], unavailable: 1),
                                       to: answer.id, in: id)
        let generatedMessage = store.conversations.first!.messages.last!
        let generatedAttachment = generatedMessage.attachments!.first!
        precondition(generatedAttachment.name == "plot.png" && generatedMessage.unavailableAttachments == 1)
        precondition(store.conversations.first?.replyAttempts?.isEmpty == true)
        let archive = PortableArchive(conversations: store.conversations,
                                      files: [conversation.attachments!.first!.fileName: original,
                                              generatedAttachment.fileName: generated], bots: store.bots)
        let archiveData = try JSONEncoder().encode(archive)
        let imported = try JSONDecoder().decode(PortableArchive.self, from: archiveData)
        let destination = ConversationStore(file: root.appending(path: "restored/conversations.json"))
        try await destination.importBackup(.legacy(imported))
        let recovered = destination.conversations.first!.attachments!.first!
        let recoveredData = try Data(contentsOf: destination.attachmentURL(recovered))
        precondition(recoveredData == original)
        let restoredMessage = destination.conversations.first!.messages.last!
        let restoredFile = restoredMessage.attachments!.first!
        precondition(restoredMessage.id != generatedMessage.id && restoredFile.fileName != generatedAttachment.fileName)
        let restoredBytes = try Data(contentsOf: destination.attachmentURL(restoredFile))
        precondition(restoredBytes == generated && restoredFile.name == "plot.png")
        precondition(destination.conversations.first!.id != id)
        let restoredBot = destination.bots.first!
        precondition(restoredBot.id != profile.id && restoredBot.configuration == bot)
        precondition(destination.conversations.first?.bot?.profileID == restoredBot.id)
        var changed = restoredBot
        changed.configuration.name = "重命名机器人"
        try destination.saveBots([changed], expected: restoredBot)
        precondition(destination.conversations.first?.bot?.name == bot.name)
        var broken = imported
        broken.files = [:]
        let rejectedLegacy: Void? = try? await destination.importBackup(.legacy(broken))
        precondition(rejectedLegacy == nil)
        precondition(destination.conversations.count == 1)
        let reopened = ConversationStore(file: root.appending(path: "restored/conversations.json"))
        precondition(reopened.conversations.first?.attachments?.first?.name == source.lastPathComponent)
        precondition(reopened.bots.first?.configuration.name == "重命名机器人")
        try reopened.deleteBot(restoredBot.id)
        precondition(reopened.bots.isEmpty && reopened.conversations.first?.bot?.profileID == restoredBot.id)
        let newPrompt = BotInstructions(prompt: "导入失败时不应替换提示词")
        precondition((try? reopened.saveBots([restoredBot], instructions: newPrompt)) == nil)
        let instructionsAfterFailure = try reopened.readInstructions()
        precondition(instructionsAfterFailure == BotInstructions() && reopened.bots.isEmpty)
        print("Bot profiles, independent chat snapshots and archive ID remapping passed.")
        let instructions = BotInstructions(prompt: "本地提示词", skills: "## 技能")
        let legacy = store.file.deletingLastPathComponent().appending(path: "bot-instructions.json")
        try JSONEncoder().encode(instructions).write(to: legacy)
        try store.prepareReplica()
        let records = try store.pendingReplica()
        let replica = ConversationStore(file: root.appending(path: "replica/conversations.json"))
        let conversationRecords = records.filter { $0.conversation == id.uuidString }
        for record in conversationRecords.reversed() {
            let hasAttachments = try !store.replicaAttachments(record).isEmpty
            let asset = try ReplicaAsset.create(record: record, attachments: store.attachmentDirectory, hasAttachments: hasAttachments)
            try replica.applyReplicaPayload(ReplicaPayload.read(asset.url))
        }
        try replica.reloadReplica()
        let syncedMessage = replica.conversations.first!.messages.first { $0.id == generatedMessage.id }!
        let syncedBytes = try Data(contentsOf: replica.attachmentURL(syncedMessage.attachments!.first!))
        precondition(syncedBytes == generated && syncedMessage.unavailableAttachments == 1)
        print("Generated files survived archive import and out-of-order replica delivery.")
        let legacyRecord = conversationRecords.first { $0.kind == "conversation" }!
        let legacyPacket = ReplicaPacket(record: legacyRecord, files: [conversation.attachments!.first!.fileName: original])
        let legacyURL = root.appending(path: "legacy-packet.json")
        try JSONEncoder().encode(legacyPacket).write(to: legacyURL)
        let legacyReplica = ConversationStore(file: root.appending(path: "legacy-replica/conversations.json"))
        try legacyReplica.applyReplicaPayload(ReplicaPayload.read(legacyURL))
        try legacyReplica.reloadReplica()
        let legacyFile = legacyReplica.conversations.first!.attachments!.first!
        let legacyBytes = try Data(contentsOf: legacyReplica.attachmentURL(legacyFile))
        precondition(legacyBytes == original)
        let instructionsRecord = records.first { $0.kind == "instructions" }!
        try reopened.applyReplicaPayload(.inline(ReplicaPacket(record: instructionsRecord, files: [:])))
        let synchronized = try reopened.readInstructions()
        precondition(synchronized == instructions)
        let stale = BotInstructions(prompt: "较早打开的编辑器")
        precondition((try? reopened.saveInstructions(stale, expected: BotInstructions())) == nil)
        precondition(FileManager.default.fileExists(atPath: legacy.path))
        print("Legacy instruction migration, record sync and stale-editor protection passed.")
        print("Configuration codec, legacy import, malformed payload, arbitrary-file copy, archive round-trip, and failed-import preservation passed.")
        print("Sample configuration JSON \(data.count) bytes; link \(link.utf8.count) characters.")

        let promptFile = root.appending(path: "Prompt.txt")
        let skillFile = root.appending(path: "格式.md")
        let disabledFile = root.appending(path: "停用.md")
        try Data("\u{FEFF}导入后的提示词".utf8).write(to: promptFile)
        try Data("正文指令".utf8).write(to: skillFile)
        try Data("不要注入这条".utf8).write(to: disabledFile)
        let importedPrompt = try InstructionFile.importing([promptFile], kind: .prompt, into: instructions)
        var shared = try InstructionFile.importing([skillFile, disabledFile], kind: .skills, into: importedPrompt)
        precondition(shared.skillEntries?.map(\.enabled) == [false, false])
        shared.skillEntries?[0].enabled = true
        precondition(shared.requestInstructions == "导入后的提示词\n\n## 技能\n\n### 格式\n正文指令")
        try store.saveInstructions(shared, expected: instructions)
        let skillRecord = try store.pendingReplica().first { $0.kind == "instructions" }!
        try replica.applyReplicaPayload(.inline(ReplicaPacket(record: skillRecord, files: [:])))
        let copiedInstructions = try replica.readInstructions()
        precondition(copiedInstructions == shared)
        var withSkills = PortableSettings(endpoint: "https://example.invalid/v1", model: "test")
        withSkills.botInstructions = shared
        let skillsLink = try ConfigurationLink.encode(JSONEncoder().encode(withSkills))
        let skillsSettings = try JSONDecoder().decode(PortableSettings.self, from: ConfigurationLink.decode(skillsLink)).validated()
        precondition(skillsSettings.botInstructions == shared)
        var editedBot = store.bots.first!
        editedBot.configuration.instructions = shared
        try store.saveBots([editedBot])
        print("Imported prompt and named skills preserved enablement in requests, SQLite replication and configuration links.")

        let langfuseFile = root.appending(path: "langfuse-export.json")
        func importLangfuse(_ json: String) throws -> BotInstructions {
            try Data(json.utf8).write(to: langfuseFile)
            return try InstructionFile.importing([langfuseFile], kind: .langfuse, into: shared)
        }
        let productionPrompt = try importLangfuse(#"""
            [
                {"type":"text","name":"system/zh","version":1,"labels":["production"],"prompt":"保留 {{变量}} 和换行\n正文。","config":{"model":"fixture"}},
                {"type":"text","name":"system/zh","version":2,"labels":["latest"],"prompt":"未上线的新版"},
                {"type":"chat","name":"unrelated","prompt":[{"role":"user","content":"测试"}]}
            ]
            """#)
        precondition(productionPrompt.prompt == "保留 {{变量}} 和换行\n正文。")
        precondition(productionPrompt.skills == shared.skills && productionPrompt.skillEntries == shared.skillEntries)
        let singlePrompt = try importLangfuse(#"{"type":"text","name":"other","version":7,"prompt":"指定版本"}"#)
        precondition(singlePrompt.prompt == "指定版本")
        let ambiguous = #"[{"type":"text","name":"system/zh","labels":["production"],"prompt":"A"},{"type":"text","name":"system/zh","labels":["production"],"prompt":"B"}]"#
        precondition((try? importLangfuse(ambiguous)) == nil)
        precondition((try? importLangfuse(#"[{"type":"text","name":"system/zh","labels":["latest"],"prompt":"草稿"}]"#)) == nil)
        precondition((try? importLangfuse(#"{"type":"chat","name":"system/zh","prompt":[]}"#)) == nil)
        precondition((try? importLangfuse(#"{"type":"text","name":"system/zh","prompt":" "}"#)) == nil)
        print("Langfuse text import selected the production system prompt and preserved local skills.")

        let large = root.appending(path: "large.unknown")
        let largeSize = 34 * 1024 * 1024
        try original.write(to: large)
        let writer = try FileHandle(forWritingTo: large)
        try writer.seek(toOffset: UInt64(largeSize - original.count))
        try writer.write(contentsOf: original)
        try writer.close()
        let stagedLarge = try await store.stageFileOpen(large)
        let largeID = try store.openFile(stagedLarge, bot: profile.snapshot)
        let backupSettings = BackupSettings(
            loginMethod: .byok, providerDefaults: .init(byokEndpoint: "https://backup.example.invalid/v1/",
                                                       byokModel: "restore-model", byokProtocol: "responses",
                                                       byokHostedTools: ["web_search"]),
            contextPolicy: .init(threshold: 50000, hours: 48, samples: 12), realtimeModel: "realtime-fixture",
            automaticConversationTitles: true, localToolsEnabled: false
        )
        let backupFile = try BackupFile.create(snapshot: store.backupSnapshot(settings: backupSettings),
                                               attachments: store.attachmentDirectory)
        let backup = try PreparedBackup.read(backupFile.url)
        precondition(backup.archive.version == 2 && backup.archive.files == nil)
        guard let portable = try backup.archive.settings?.portableSettings() else { throw CocoaError(.fileReadCorruptFile) }
        let backupCredentials = try portable.loginCredentials()
        precondition(portable.endpoint == "https://backup.example.invalid/v1" && portable.model == "restore-model" &&
                     portable.contextPolicy == backupSettings.contextPolicy && portable.hostedTools == ["web_search"] &&
                     portable.realtimeModel == "realtime-fixture" && portable.automaticConversationTitles == true &&
                     backupCredentials.isEmpty && portable.nodeLinks == nil)
        let titlesLink = try ConfigurationLink.encode(JSONEncoder().encode(portable))
        let titlesSettings = try JSONDecoder().decode(PortableSettings.self, from: ConfigurationLink.decode(titlesLink))
        let titlesImport = ConfigurationImport(settings: titlesSettings, vault: titlesSettings, previous: nil, incoming: .init())
        precondition(titlesImport.automaticConversationTitles == true)
        precondition(portable.localToolsEnabled == false && titlesSettings.localToolsEnabled == false &&
                     titlesImport.localToolsEnabled == false)
        let zipDestination = ConversationStore(file: root.appending(path: "zip-restored/conversations.json"))
        let sharedBackup = UUID()
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await zipDestination.importBackup(backup, sharedImportID: sharedBackup)
        }
        do {
            try await cancelled.value
            fatalError("A cancelled restore committed its data")
        } catch is CancellationError {}
        let wasCommitted = try zipDestination.sharedImportCommitted(sharedBackup)
        precondition(zipDestination.conversations.isEmpty && !zipDestination.restoringBackup && !wasCommitted)
        let unavailable = ConversationStore(file: root.appending(path: "zip-unavailable/conversations.json"))
        try unavailable.requireDatabase().close()
        let rejectedRestore: Void? = try? await unavailable.importBackup(backup)
        precondition(rejectedRestore == nil && !unavailable.restoringBackup)
        let rolledBackFiles = try FileManager.default.contentsOfDirectory(atPath: unavailable.attachmentDirectory.path)
        precondition(rolledBackFiles.isEmpty && unavailable.conversations.isEmpty)
        try await zipDestination.importBackup(backup, sharedImportID: sharedBackup)
        let resumedBackup = ConversationStore(file: zipDestination.file)
        let backupCommitted = try resumedBackup.sharedImportCommitted(sharedBackup)
        precondition(backupCommitted)
        try await resumedBackup.importBackup(backup, sharedImportID: sharedBackup)
        precondition(resumedBackup.conversations.map(\.id) == zipDestination.conversations.map(\.id))
        precondition(resumedBackup.bots == zipDestination.bots)
        let largeRestored = zipDestination.conversations.first { $0.title == "large.unknown" }!.attachments!.first!
        let reader = try FileHandle(forReadingFrom: zipDestination.attachmentURL(largeRestored))
        let start = try reader.read(upToCount: original.count)
        try reader.seek(toOffset: UInt64(largeSize - original.count))
        let end = try reader.readToEnd()
        try reader.close()
        precondition(largeRestored.size == largeSize && start == original && end == original)
        let zipGenerated = zipDestination.conversations.flatMap(\.messages).last!.attachments!.first!
        let zipGeneratedBytes = try Data(contentsOf: zipDestination.attachmentURL(zipGenerated))
        precondition(zipGeneratedBytes == generated && zipDestination.bots.count == 1)
        let restoredInstructions = try zipDestination.readInstructions()
        precondition(restoredInstructions == shared && zipDestination.bots.first?.configuration.instructions == shared)
        let keepLocal = ConversationStore(file: root.appending(path: "zip-keep-local/conversations.json"))
        try keepLocal.saveInstructions(instructions)
        try await keepLocal.importBackup(PreparedBackup.read(backupFile.url), restoreInstructions: false)
        let unchangedInstructions = try keepLocal.readInstructions()
        precondition(unchangedInstructions == instructions && keepLocal.bots.first?.configuration.instructions == shared)
        print("ZIP cancellation and rollback left no committed data, shared restore replay created no extra copies, and a 34 MiB attachment was restored.")

        let oldBackup = root.appending(path: "legacy.aauvbackup")
        try archiveData.write(to: oldBackup)
        guard case .legacy(let oldArchive) = try PreparedBackup.read(oldBackup) else { throw CocoaError(.fileReadCorruptFile) }
        precondition(oldArchive.settings == nil && oldArchive.conversations.count == archive.conversations.count)
        var untrusted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backupSettings)) as! [String: Any]
        untrusted["key"] = "fixture-secret"
        untrusted["nodeLinks"] = ["socks5://fixture.invalid:9999"]
        let parsed = try JSONDecoder().decode(BackupSettings.self, from: JSONSerialization.data(withJSONObject: untrusted))
        let safe = try parsed.portableSettings()
        let safeCredentials = try safe.loginCredentials()
        precondition(safeCredentials.isEmpty && safe.nodeLinks == nil)
        print("Backup preferences round-tripped without credential fields; legacy JSON with the backup extension opened.")

        let largeRecord = try store.pendingReplica().first { $0.conversation == largeID.uuidString }!
        let largeAsset = try ReplicaAsset.create(record: largeRecord, attachments: store.attachmentDirectory, hasAttachments: true)
        try replica.applyReplicaPayload(ReplicaPayload.read(largeAsset.url))
        // Retrying the same record verifies and reuses the already materialized file.
        try replica.applyReplicaPayload(ReplicaPayload.read(largeAsset.url))
        try replica.reloadReplica()
        let syncedLarge = replica.conversations.first { $0.id == largeID }!.attachments!.first!
        let syncedLargeURL = try replica.attachmentURL(syncedLarge)
        let restoredLargeURL = try zipDestination.attachmentURL(largeRestored)
        precondition(FileManager.default.contentsEqual(atPath: syncedLargeURL.path, andPath: restoredLargeURL.path))
        try FileManager.default.removeItem(at: syncedLargeURL)
        let missing = await replica.missingReplicaAttachmentRecords()
        precondition(missing == [largeRecord.name])
        try replica.applyReplicaPayload(ReplicaPayload.read(largeAsset.url))
        precondition(FileManager.default.contentsEqual(atPath: syncedLargeURL.path, andPath: restoredLargeURL.path))
        print("Streaming sync packet restored a 34 MiB attachment, survived duplicate delivery, and retained legacy JSON compatibility.")

        let originalOutbox = try store.pendingReplica()
        for record in originalOutbox {
            try store.acknowledgeReplica(name: record.name, revision: record.revision)
        }
        try store.requeueReplica()
        let rebuilt = try store.pendingReplica()
        precondition(rebuilt.map(\.name) == originalOutbox.map(\.name))
        let replacement = ConversationStore(file: root.appending(path: "new-zone/conversations.json"))
        for record in rebuilt.reversed() {
            let hasAttachments = try !store.replicaAttachments(record).isEmpty
            let asset = try ReplicaAsset.create(record: record, attachments: store.attachmentDirectory,
                                                hasAttachments: hasAttachments)
            try replacement.applyReplicaPayload(ReplicaPayload.read(asset.url))
        }
        try replacement.reloadReplica()
        let rebuiltAttachment = replacement.conversations.first { $0.id == largeID }!.attachments!.first!
        let rebuiltURL = try replacement.attachmentURL(rebuiltAttachment)
        let prompt = try replacement.readInstructions()
        precondition(FileManager.default.contentsEqual(atPath: syncedLargeURL.path, andPath: rebuiltURL.path))
        precondition(prompt == shared && replacement.bots.first?.configuration.instructions == shared)
        let state = store.file.deletingLastPathComponent().appending(path: "cloudkit-zone-state")
        try Data(#"{"zone":"recovery","owner":"fixture-account"}"#.utf8).write(to: state)
        precondition(CloudSync(store: store).recoveryRequired)
        print("Rebuilding the replica retained acknowledged records, a 34 MiB attachment and the recovery checkpoint.")
    }
}
