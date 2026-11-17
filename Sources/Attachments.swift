import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct Attachment: Codable, Identifiable, Sendable {
    var id = UUID()
    let name: String
    let fileName: String
    let size: Int
}

struct DraftAttachment: Identifiable, Sendable {
    private let directory: PrivateTemporaryDirectory
    let attachment: Attachment
    var id: UUID { attachment.id }
    var url: URL { directory.url.appending(path: attachment.fileName) }

    init(_ source: URL, id: UUID = UUID(), replacementFor destination: URL? = nil, suggestedName: String? = nil) throws {
        let directory = try PrivateTemporaryDirectory(replacementFor: destination)
        let copied = try Attachment.copy(from: source, to: directory.url, id: id)
        attachment = Attachment(id: copied.id, name: suggestedName ?? copied.name, fileName: copied.fileName, size: copied.size)
        self.directory = directory
    }
}

private extension Attachment {
    static func copy(from source: URL, to directory: URL, id: UUID) throws -> Self {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let name = id.uuidString
        let destination = directory.appending(path: name)
        var coordinationError: NSError?
        var copyResult: Result<Self, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            copyResult = Result {
                let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ChatClient.ClientError.message("请选择文件。文件夹可以压缩后添加。")
                }
                try FileManager.default.copyItem(at: coordinated, to: destination)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                #endif
                guard let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw CocoaError(.fileReadUnknown)
                }
                return Self(id: id, name: source.lastPathComponent, fileName: name, size: size)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let copyResult else { throw CocoaError(.fileReadUnknown) }
        return try copyResult.get()
    }
}

struct RequestAttachment: Sendable {
    private static let inlineThreshold = 10 * 1024 * 1024
    let name: String
    let mediaType: String
    let url: URL
    let size: Int

    var fields: [String: String] { ["name": name, "media_type": mediaType] }

    static func fitsInline(_ files: [Self]) -> Bool {
        var remaining = inlineThreshold
        for file in files {
            guard (0...remaining).contains(file.size) else { return false }
            remaining -= file.size
        }
        return true
    }
}

struct AttachmentShare: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(file.url)
        }
        .suggestedFileName { $0.name }
    }
}

struct BotSnapshot: Codable, Equatable, Sendable {
    var name: String
    var endpoint: String
    var model: String
    var loginMethod: LoginMethod
    var apiProtocol: String?
    var hostedTools: [String]?
    var chatGPTClientID: String?
    var profileID: UUID?
    var instructions: BotInstructions?
}

extension ConversationStore {
    func stageFileOpen(_ source: URL, shareID: UUID? = nil) async throws -> DraftAttachment {
        let directory = attachmentDirectory
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try DraftAttachment(source, id: shareID ?? UUID(), replacementFor: directory)
        }.value
    }

    func openFile(_ staged: DraftAttachment, bot: BotSnapshot, shareID: UUID? = nil, capturedBot: Data? = nil) throws -> UUID {
        if let shareID {
            if try sharedImportCommitted(shareID) || conversations.contains(where: { $0.id == shareID }) { return shareID }
            guard staged.id == shareID else { throw CocoaError(.fileReadCorruptFile) }
        }
        let attachment = staged.attachment
        let destination = try attachmentURL(attachment)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard shareID != nil else { throw CocoaError(.fileWriteFileExists) }
            // An earlier import may have stopped between moving the file and committing its chat.
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: staged.url, to: destination)
        do {
            var conversation = Conversation()
            if let shareID { conversation.id = shareID }
            conversation.title = attachment.name
            let snapshot = capturedBot.flatMap { try? JSONDecoder().decode(BotSnapshot.self, from: $0) }
            conversation.bot = (snapshot ?? bot).boundForNewChat()
            conversation.attachments = [attachment]
            try insert(conversation, sharedImportID: shareID)
            return conversation.id
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    @discardableResult
    func appendUserMessage(_ content: String, files: [DraftAttachment], to id: UUID) throws -> UUID {
        try requireIdleConversation(id)
        guard conversations.contains(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        return try withStoredUserMessage(content, files: files) { message in
            try append(message, to: id)
            return message.id
        }
    }

    /// Commit the first message and its header together; a failed send leaves no empty row.
    @discardableResult
    func sendFirstMessage(_ content: String, files: [DraftAttachment], in preview: Conversation) throws -> UUID {
        try requireIdleConversation(preview.id)
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else {
            throw ChatClient.ClientError.message(String(localized: "请输入消息或添加附件。"))
        }
        guard !conversations.contains(where: { $0.id == preview.id }), preview.messages.isEmpty,
              !preview.isLetter, preview.attachments?.isEmpty != false else {
            throw ChatClient.ClientError.message(String(localized: "会话已更新，请查看最新消息后再重试。"))
        }
        return try withStoredUserMessage(text, files: files) { message in
            var conversation = preview
            conversation.messages = [message]
            if conversation.title == "新对话", conversation.automaticTitle != false {
                let title = message.content.prefix(160).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !title.isEmpty { conversation.title = String(title.prefix(40)) }
            }
            try insert(conversation)
            return message.id
        }
    }

    private func withStoredUserMessage(_ content: String, files: [DraftAttachment],
                                       commit: (ChatMessage) throws -> UUID) throws -> UUID {
        if files.isEmpty { return try commit(ChatMessage(role: .user, content: content)) }
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        var copied: [URL] = []
        do {
            for file in files {
                let destination = try attachmentURL(file.attachment)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                copied.append(destination)
                try FileManager.default.copyItem(at: file.url, to: destination)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                #endif
            }
            let message = ChatMessage(role: .user, content: content.isEmpty ? "请查看附件。" : content,
                                      attachments: files.map(\.attachment))
            return try commit(message)
        } catch {
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    func filesForReply(in conversation: Conversation, to message: ChatMessage) throws -> [RequestAttachment] {
        let current = conversation.isLetter && conversation.letterContext != nil ? [] : conversation.attachments ?? []
        return try filesForRequest(current + (message.attachments ?? []))
    }

    var attachmentDirectory: URL {
        file.deletingLastPathComponent().appending(path: "Attachments")
    }

    func attachmentURL(_ attachment: Attachment) throws -> URL {
        guard UUID(uuidString: attachment.fileName) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return attachmentDirectory.appending(path: attachment.fileName)
    }

    func saveGeneratedFile(_ file: ChatClient.GeneratedFiles.File) throws -> Attachment {
        let filename = file.name.replacingOccurrences(of: "\\", with: "/")
        let basename = filename.split(separator: "/").last.map(String.init) ?? ""
        let safeName = String(basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ["", ".", ".."].contains(safeName) ? "生成文件" : String(safeName.prefix(180))
        let attachment = Attachment(name: name, fileName: UUID().uuidString, size: file.data.count)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        try writeAttachment(file.data, to: attachmentURL(attachment))
        return attachment
    }

    func writeAttachment(_ bytes: Data, to destination: URL) throws {
        #if os(iOS)
        try bytes.write(to: destination, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: destination, options: .atomic)
        #endif
    }

    func filesForRequest(_ attachments: [Attachment]) throws -> [RequestAttachment] {
        try attachments.map { attachment in
            let url = try attachmentURL(attachment)
            let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  let size = properties.fileSize, size == attachment.size else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let type = UTType(filenameExtension: (attachment.name as NSString).pathExtension)
            return RequestAttachment(name: attachment.name, mediaType: type?.preferredMIMEType ?? "application/octet-stream",
                                     url: url, size: size)
        }
    }
}
