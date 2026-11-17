import Foundation

@main @MainActor
struct BackupAttachmentIdentityTests {
    private static let shared = Attachment(id: UUID(uuidString: "ABCDEF01-2345-4678-8ABC-DEF012345678")!,
                                           name: "shared.bin", fileName: "01234567-89AB-4CDE-8F01-23456789ABCD", size: 6)
    private static let other = Attachment(id: UUID(uuidString: "ABCDEF02-2345-4678-8ABC-DEF012345678")!,
                                          name: "other.bin", fileName: "01234567-89AB-4CDE-8F01-23456789ABCE", size: 4)
    private static let sharedBytes = Data([0, 255, 12, 0, 42, 128])
    private static let otherBytes = Data([55, 0, 4, 9])
    private static func expect(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(condition, file: file, line: line)
    }

    static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        let source = ConversationStore(file: directory.url.appending(path: "source/conversations.json"))
        try FileManager.default.createDirectory(at: source.attachmentDirectory, withIntermediateDirectories: true)
        try sharedBytes.write(to: source.attachmentURL(shared))
        try otherBytes.write(to: source.attachmentURL(other))
        var original = Conversation()
        original.title = "Stable attachment IDs"
        original.attachments = [shared, other]
        original.messages = [
            ChatMessage(role: .user, content: "read_attachment \(shared.id.uuidString)", attachments: [shared]),
            ChatMessage(role: .assistant, content: "same logical attachment", attachments: [shared])
        ]
        try source.insert(original)
        let legacy = PortableArchive(version: 1, conversations: source.conversations,
                                     files: [shared.fileName: sharedBytes, other.fileName: otherBytes])
        let legacyURL = directory.url.appending(path: "legacy.aauvbackup")
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        let zip = try BackupFile.create(snapshot: source.backupSnapshot(), attachments: source.attachmentDirectory)
        for (format, url) in [("legacy", legacyURL), ("zip", zip.url)] {
            try await restoreTwice(PreparedBackup.read(url), format: format, in: directory.url)
        }
        expect(try Data(contentsOf: source.attachmentURL(shared)) == sharedBytes)
        print("ZIP and legacy backup restores retained logical attachment UUIDs across repeated message references, re-read files by original UUID, kept independent physical copies on repeated restore, preserved preexisting files, and survived SQLite reopen plus replica ZIP replay.")
    }

    private static func restored(_ store: ConversationStore) -> [Conversation] {
        store.conversations.filter { $0.title == "Stable attachment IDs" }
    }

    private static func verify(_ conversation: Conversation, in store: ConversationStore) throws -> Set<String> {
        let attachments = conversation.allAttachments
        expect(attachments.count == 4)
        expect(Set(attachments.map(\.id)) == [shared.id, other.id])
        let references = attachments.filter { $0.id == shared.id }
        expect(references.count == 3 && Set(references.map(\.fileName)).count == 1)
        expect(conversation.messages[0].content.contains(shared.id.uuidString))
        for file in attachments {
            expect(UUID(uuidString: file.fileName) != nil)
            expect(file.fileName != shared.fileName && file.fileName != other.fileName)
            let expected = file.id == shared.id ? sharedBytes : otherBytes
            let bytes = try Data(contentsOf: store.attachmentURL(file))
            expect(file.size == expected.count && bytes == expected)
        }
        return Set(attachments.map(\.fileName))
    }

    private static func restoreTwice(_ backup: PreparedBackup, format: String, in root: URL) async throws {
        let destination = ConversationStore(file: root.appending(path: "\(format)/conversations.json"))
        try FileManager.default.createDirectory(at: destination.attachmentDirectory, withIntermediateDirectories: true)
        // This live file deliberately collides with an archived physical name.
        // Restore must choose another name without changing its logical UUID.
        let existingBytes = Data([11, 11, 11])
        let existing = Attachment(name: "existing.bin", fileName: shared.fileName, size: existingBytes.count)
        try existingBytes.write(to: destination.attachmentURL(existing))
        var existingChat = Conversation()
        existingChat.title = "Existing target"
        existingChat.attachments = [existing]
        try destination.insert(existingChat)

        try await destination.importBackup(backup)
        expect(destination.conversations.count == 2 && restored(destination).count == 1)
        let first = restored(destination)[0]
        let firstNames = try verify(first, in: destination)
        let firstFiles = try firstNames.reduce(into: [String: Data]()) { files, name in
            files[name] = try Data(contentsOf: destination.attachmentDirectory.appending(path: name))
        }
        try await verifyOriginalIDCanBeRead(first, store: destination)
        try await destination.importBackup(backup)
        let copies = restored(destination)
        expect(destination.conversations.count == 3 && copies.count == 2 && copies[0].id != copies[1].id)
        let second = copies.first { $0.id != first.id }!
        let secondNames = try verify(second, in: destination)
        expect(firstNames.isDisjoint(with: secondNames))
        for (name, bytes) in firstFiles {
            expect(try Data(contentsOf: destination.attachmentDirectory.appending(path: name)) == bytes)
        }
        expect(try Data(contentsOf: destination.attachmentURL(existing)) == existingBytes)
        expect(try FileManager.default.contentsOfDirectory(atPath: destination.attachmentDirectory.path).count == 5)

        let reopened = ConversationStore(file: destination.file)
        expect(reopened.conversations.count == 3)
        for copy in restored(reopened) { _ = try verify(copy, in: reopened) }
        let retained = reopened.conversations.first { $0.id == existingChat.id }!.attachments!.first!
        expect(retained.id == existing.id && retained.fileName == existing.fileName)
        expect(try Data(contentsOf: reopened.attachmentURL(retained)) == existingBytes)

        // Replica payload/blob identity is physical fileName, so the same
        // logical UUID can safely occur in two independently restored chats.
        let replica = ConversationStore(file: root.appending(path: "\(format)-replica/conversations.json"))
        for record in try reopened.pendingReplica().reversed() {
            let hasAttachments = try !reopened.replicaAttachments(record).isEmpty
            let asset = try ReplicaAsset.create(record: record, attachments: reopened.attachmentDirectory,
                                                hasAttachments: hasAttachments)
            try replica.applyReplicaPayload(ReplicaPayload.read(asset.url))
        }
        try replica.reloadReplica()
        expect(replica.conversations.count == 3 && restored(replica).count == 2)
        for copy in restored(replica) { _ = try verify(copy, in: replica) }
    }

    private static func verifyOriginalIDCanBeRead(_ conversation: Conversation, store: ConversationStore) async throws {
        var uploads = 0
        let tools = LocalCloudTools(attachments: conversation.allAttachments, prepareAttachment: { attachment in
            try store.filesForRequest([attachment])[0]
        }, cloud: { question, files, model in
            expect(question == "Read the preserved reference" && files.count == 1 && model == nil)
            expect(try Data(contentsOf: files[0].url) == sharedBytes)
            uploads += 1
            return "Selected the original logical UUID"
        }, validateScope: {})
        let arguments = try JSONSerialization.data(withJSONObject: ["attachment_id": shared.id.uuidString,
                                                                   "question": "Read the preserved reference"])
        let result = try await tools.perform(.init(id: nil, callID: "read_preserved", name: "read_attachment", namespace: "",
                                                   arguments: String(decoding: arguments, as: UTF8.self)))
        let output = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
        expect(uploads == 1 && output["attachment_id"] as? String == shared.id.uuidString.lowercased())
    }
}
