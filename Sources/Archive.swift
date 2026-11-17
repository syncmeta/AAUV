import AAUVCore
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let aauvBackup = UTType(exportedAs: "com.pendingname.aauv.backup", conformingTo: .zip)
}

final class PrivateTemporaryDirectory: Sendable {
    let url: URL

    init(replacementFor destination: URL? = nil) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        let files = FileManager.default
        if let destination {
            let directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
            do { try files.setAttributes(attributes, ofItemAtPath: directory.path) }
            catch {
                try? files.removeItem(at: directory)
                throw error
            }
            url = directory
        } else {
            url = files.temporaryDirectory.appending(path: "AAUV-\(UUID())")
            try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: attributes)
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func hasZIPSignature(_ url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.read(upToCount: 4) == Data([0x50, 0x4B, 0x03, 0x04])
}

struct BackupFile: Transferable {
    private let directory: PrivateTemporaryDirectory
    var url: URL { directory.url.appending(path: "AAUV-backup.aauvbackup") }

    static func create(snapshot: PortableArchive, attachments: URL) throws -> Self {
        let manifest = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        let file = Self(directory: try PrivateTemporaryDirectory())
        var error: NSError?
        guard AauvcoreWriteBackupZIP(file.url.path, attachments.path, manifest, &error) else {
            if let error { throw error }
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .aauvBackup) { file in
            SentTransferredFile(file.url)
        }
        .suggestedFileName { $0.url.lastPathComponent }
    }
}

enum PreparedBackup {
    case legacy(PortableArchive)
    case zip(PortableArchive, PrivateTemporaryDirectory)

    var archive: PortableArchive {
        switch self {
        case .legacy(let archive), .zip(let archive, _): archive
        }
    }

    static func read(_ source: URL) throws -> Self {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Self, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            result = Result { try readCoordinated(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private static func readCoordinated(_ source: URL) throws -> Self {
        let properties = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard properties.isRegularFile == true else { throw CocoaError(.fileReadCorruptFile) }
        if try hasZIPSignature(source) || source.pathExtension.lowercased() == "zip" {
            let stage = try PrivateTemporaryDirectory()
            var error: NSError?
            let manifest = AauvcoreReadBackupZIP(source.path, stage.url.path, &error)
            if let error { throw error }
            let archive = try JSONDecoder().decode(PortableArchive.self, from: Data(manifest.utf8))
            guard archive.version == 2, archive.files == nil else { throw CocoaError(.fileReadCorruptFile) }
            return .zip(archive, stage)
        }
        guard let size = properties.fileSize, size <= 64 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return .legacy(try JSONDecoder().decode(PortableArchive.self, from: Data(contentsOf: source)))
    }

    func validate() throws {
        let archive = self.archive
        if let bots = archive.bots { _ = try LocalBot.validateBatch(bots) }
        if let instructions = archive.instructions { _ = try instructions.validated() }
        if let settings = archive.settings { _ = try settings.portableSettings() }
        if case .legacy = self {
            guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            for attachment in archive.conversations.flatMap(\.allAttachments) {
                guard UUID(uuidString: attachment.fileName) != nil,
                      let bytes = archive.files?[attachment.fileName], bytes.count == attachment.size else {
                    throw ChatClient.ClientError.message("备份缺少附件，或附件信息损坏。")
                }
            }
        }
    }

    func configurationForRestore(botIDMapping: [UUID: UUID]) throws -> PortableSettings? {
        guard let settings = archive.settings else { return nil }
        var configuration = try settings.portableSettings()
        configuration.defaultBotSelection = try configuration.defaultBotSelection?.remappingProfile(botIDMapping)
        return configuration
    }

    fileprivate func stageRestore(to destination: URL) throws -> StagedBackupRestore {
        try validate()
        try Task.checkCancellation()
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let directory = try PrivateTemporaryDirectory(replacementFor: destination)
        var restored = archive
        // Disk names change for independent copies; logical IDs remain valid
        // in history references and conversation-scoped read_attachment calls.
        var names: [String: String] = [:]
        func copy(_ attachments: [Attachment]?) throws -> [Attachment]? {
            try attachments?.map { attachment in
                try Task.checkCancellation()
                if let name = names[attachment.fileName] {
                    return Attachment(id: attachment.id, name: attachment.name, fileName: name, size: attachment.size)
                }
                guard UUID(uuidString: attachment.fileName) != nil else { throw CocoaError(.fileReadCorruptFile) }
                let name = UUID().uuidString
                let target = directory.url.appending(path: name)
                switch self {
                case .legacy(let original):
                    guard let bytes = original.files?[attachment.fileName] else { throw CocoaError(.fileReadCorruptFile) }
                    try bytes.write(to: target, options: [.withoutOverwriting])
                case .zip(_, let source):
                    try files.copyItem(at: source.url.appending(path: attachment.fileName), to: target)
                }
                let properties = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.fileSize == attachment.size else {
                    throw ChatClient.ClientError.message("备份缺少附件，或附件信息损坏。")
                }
                #if os(iOS)
                try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
                #endif
                names[attachment.fileName] = name
                return Attachment(id: attachment.id, name: attachment.name, fileName: name, size: attachment.size)
            }
        }
        for index in restored.conversations.indices {
            let attachments = restored.conversations[index].attachments
            restored.conversations[index].attachments = try copy(attachments)
            for message in restored.conversations[index].messages.indices {
                let attachments = restored.conversations[index].messages[message].attachments
                restored.conversations[index].messages[message].attachments = try copy(attachments)
            }
        }
        restored.files = nil
        return StagedBackupRestore(archive: restored, directory: directory, fileNames: Array(names.values))
    }
}

fileprivate struct StagedBackupRestore {
    let archive: PortableArchive
    let directory: PrivateTemporaryDirectory
    let fileNames: [String]
}

struct BackupSettings: Codable {
    let loginMethod: LoginMethod
    let providerDefaults: ProviderDefaults
    let contextPolicy: ContextPolicy
    let realtimeModel: String?
    var automaticConversationTitles: Bool? = nil
    var localToolsEnabled: Bool? = nil
    var defaultBotSelection: DefaultBotSelection? = nil
    var selectedProxyNode: String? = nil
    var proxyRequiresTunnel: Bool? = nil
    var githubCopilotClientID: String? = nil
    var cloudSyncEnabled: Bool? = nil
    var localProfile: LocalDisplayProfile? = nil
    var modelServices: [ModelService]? = nil

    var appPreferences: PortableAppPreferences {
        .init(selectedProxyNode: selectedProxyNode, proxyRequiresTunnel: proxyRequiresTunnel,
              githubCopilotClientID: githubCopilotClientID, cloudSyncEnabled: cloudSyncEnabled,
              localProfile: localProfile, modelServices: modelServices)
    }

    func portableSettings() throws -> PortableSettings {
        let endpoint: String
        let model: String
        switch loginMethod {
        case .byok:
            endpoint = providerDefaults.byokEndpoint ?? "https://api.openai.com/v1"
            model = providerDefaults.byokModel ?? ""
        case .chatgpt:
            endpoint = ChatGPTPlanSession.endpoint.absoluteString
            model = providerDefaults.chatGPTModel ?? ""
        case .copilot:
            endpoint = "https://github.com"
            model = providerDefaults.copilotModel ?? ""
        }
        var settings = PortableSettings(endpoint: endpoint, model: model, loginMethod: loginMethod,
                                        apiProtocol: loginMethod == .byok ? providerDefaults.byokProtocol : "responses",
                                        contextPolicy: contextPolicy, realtimeModel: realtimeModel,
                                        automaticConversationTitles: automaticConversationTitles, providerDefaults: providerDefaults,
                                        localToolsEnabled: localToolsEnabled, defaultBotSelection: defaultBotSelection,
                                        selectedProxyNode: selectedProxyNode, proxyRequiresTunnel: proxyRequiresTunnel,
                                        githubCopilotClientID: githubCopilotClientID, cloudSyncEnabled: cloudSyncEnabled,
                                        localProfile: localProfile, modelServices: modelServices)
        if loginMethod == .byok, settings.apiProtocol == "responses" { settings.hostedTools = providerDefaults.byokHostedTools }
        if loginMethod == .chatgpt { settings.hostedTools = providerDefaults.chatGPTHostedTools }
        return try settings.validated()
    }
}

extension ConversationStore {
    func backupSnapshot(settings: BackupSettings? = nil) throws -> PortableArchive {
        let instructions = try readInstructions()
        if let settings { _ = try settings.portableSettings() }
        let snapshot = conversations.map { conversation in
            var copy = conversation
            copy.compression = conversation.compression?.finalized()
            return copy
        }
        return PortableArchive(version: 2, conversations: snapshot, bots: bots.isEmpty ? nil : bots,
                               instructions: instructions == BotInstructions() ? nil : instructions, settings: settings)
    }

    func importBackup(_ backup: PreparedBackup, restoreInstructions: Bool = true, restoreSettings: Bool = false,
                      sharedImportID: UUID? = nil) async throws {
        guard !restoringBackup else { throw ChatClient.ClientError.message("已有备份正在恢复。") }
        let restorePreferences = restoreSettings && backup.archive.settings != nil
        if !restorePreferences, let sharedImportID, try sharedImportCommitted(sharedImportID) { return }
        restoringBackup = true
        defer { restoringBackup = false }
        let destination = attachmentDirectory
        let worker = Task.detached(priority: .userInitiated) { try backup.stageRestore(to: destination) }
        let staged = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        if !restorePreferences, let sharedImportID, try sharedImportCommitted(sharedImportID) { return }

        let archive = staged.archive
        var reserved = Set(bots.map(\.id) + (archive.bots ?? []).map(\.id))
        var botIDMapping: [UUID: UUID] = [:]
        for bot in archive.bots ?? [] {
            var copied = UUID()
            while reserved.contains(copied) { copied = UUID() }
            reserved.insert(copied)
            botIDMapping[bot.id] = copied
        }
        let copiedProfiles = (archive.bots ?? []).map { original in
            var copy = original
            copy.id = botIDMapping[original.id]!
            return copy
        }
        var created: [URL] = []
        var inserted = false
        defer {
            if !inserted { for url in created { try? FileManager.default.removeItem(at: url) } }
        }
        func insert(_ configurationImportID: UUID?) throws {
            for name in staged.fileNames {
                let url = destination.appending(path: name)
                try FileManager.default.moveItem(at: staged.directory.url.appending(path: name), to: url)
                created.append(url)
            }
            inserted = try importCopies(archive.conversations, bots: archive.bots ?? [],
                                        botIDMapping: botIDMapping,
                                        instructions: restoreInstructions ? archive.instructions : nil,
                                        configurationImportID: configurationImportID, sharedImportID: sharedImportID)
        }
        if restoreSettings, let settings = try backup.configurationForRestore(botIDMapping: botIDMapping) {
            do {
                try commitConfiguration(settings, sharedImportID: sharedImportID, selectionBots: copiedProfiles) { id in try insert(id) }
            } catch {
                if inserted {
                    throw ChatClient.ClientError.message("会话、机器人和附件已恢复。请在会话列表继续完成配置恢复。")
                }
                throw error
            }
        } else {
            try insert(nil)
        }
    }
}
