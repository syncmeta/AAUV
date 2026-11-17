import Foundation

private enum FixtureFailure: Error { case missing }

@main @MainActor
struct MessageDeletionTests {
    static func main() async throws {
        let root = try PrivateTemporaryDirectory()
        try testLocalAndStaleWriters(root.url)
        try testSynchronization(root.url)
        try testUserAndOrphanReferences(root.url)
        try testCleanupRetry(root.url)
        try await testBackupCopiesWithOrphanReplies(root.url)
        print("MessageDeletionTests passed local user/assistant deletion, activity invalidation, stale SQLite writers, selection/attempt/compression cleanup, tombstone replay/opaque asset safety, shared/orphan file references, cleanup retry, chronological surviving-answer context and new-identity orphan backup copies. Synthetic SQLite/files only.")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String = "Fixture assertion failed", file: StaticString = #fileID, line: UInt = #line) throws {
        let passed = try condition()
        precondition(passed, message, file: file, line: line)
    }

    private static func store(_ root: URL, _ name: String) -> ConversationStore {
        ConversationStore(file: root.appending(path: name).appending(path: "conversations.json"))
    }

    private static func attachment(_ store: ConversationStore, name: String, bytes: Data) throws -> Attachment {
        let result = Attachment(name: name, fileName: UUID().uuidString, size: bytes.count)
        try FileManager.default.createDirectory(at: store.attachmentDirectory, withIntermediateDirectories: true)
        try bytes.write(to: store.attachmentURL(result))
        return result
    }

    private static func conversation(_ store: ConversationStore, _ id: UUID) throws -> Conversation {
        guard let result = store.conversations.first(where: { $0.id == id }) else { throw FixtureFailure.missing }
        return result
    }

    private static func compression(_ message: ChatMessage) -> ContextCompression {
        .init(fingerprint: "window2:synthetic", summary: "synthetic old summary", compressedSamples: [.init(message)],
              historicalSamples: [.init(message)], throughID: message.id.uuidString, throughChars: 40,
              checkpoint: .init(scope: "synthetic", planKey: "synthetic-plan", completedBatches: 1, summary: "old checkpoint"))
    }

    private static func rejected(_ label: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection: " + label) }
        catch { }
    }

    private static func fixture(_ store: ConversationStore) throws -> (UUID, ChatMessage, ChatMessage, ChatMessage, Attachment, Attachment) {
        let shared = try attachment(store, name: "shared.bin", bytes: Data([1, 3, 5]))
        let unique = try attachment(store, name: "deleted-only.bin", bytes: Data([2, 4, 6]))
        let now = Date()
        var prompt = ChatMessage(role: .user, content: "question", date: now, attachments: [shared])
        let original = ChatMessage(role: .assistant, content: "original reply", date: now.addingTimeInterval(1), replyTo: prompt.id)
        let alternate = ChatMessage(role: .assistant, content: "DO-NOT-SEND-DELETED-REPLY", date: now.addingTimeInterval(2),
                                    attachments: [shared, unique], replyTo: prompt.id, isAlternative: true)
        prompt.selectedReplyID = alternate.id
        var value = Conversation()
        value.messages = [prompt, original, alternate]
        value.selectedReplies = [prompt.id.uuidString: alternate.id]
        value.compression = compression(alternate)
        value.replyAttempts = [.init(userMessageID: prompt.id, phase: .failed, partial: "old partial")]
        try store.insert(value)
        return (value.id, prompt, original, alternate, shared, unique)
    }

    private static func testLocalAndStaleWriters(_ root: URL) throws {
        let current = store(root, "local")
        let (id, prompt, original, alternate, shared, unique) = try fixture(current)
        let unrelated = try attachment(current, name: "in-flight-unreferenced.bin", bytes: Data([11]))
        let stale = ConversationStore(file: current.file)
        let peerActivity = try stale.beginActivity(.reply, in: id)
        var peerCancellations = 0
        stale.setCancellation(for: peerActivity) { peerCancellations += 1 }
        let (activity, captured, _, attempt) = try current.beginReply(in: id, to: prompt.id, regenerating: true)
        let scope = try ConversationReplyScope(store: current, activity: activity, conversation: captured, attempt: attempt)
        var canceled = 0
        current.setCancellation(for: activity) {
            precondition(current.activities[id] == nil, "Activity must be invalid before cancellation callback")
            canceled += 1
        }
        var changes = 0
        current.onLocalChange = { changes += 1 }
        try current.deleteMessage(alternate.id, in: id)
        let updated = try conversation(current, id)
        try require(canceled == 1 && changes == 1 && current.activities[id] == nil)
        try require(updated.messages.map(\.id) == [prompt.id, original.id])
        try require(updated.messages.first?.selectedReplyID == nil)
        try require(updated.selectedReplies?.values.contains(alternate.id) != true)
        try require(updated.replyAttempts?.isEmpty != false && updated.compression == nil)
        try require(updated.historyRevision?.isEmpty == false)
        rejected("invalidated reply scope") { try scope.validate() }
        try require(!FileManager.default.fileExists(atPath: try current.attachmentURL(unique).path))
        try require(FileManager.default.fileExists(atPath: try current.attachmentURL(shared).path))
        try require(FileManager.default.fileExists(atPath: try current.attachmentURL(unrelated).path), "Never sweep unrelated files")
        let revision = updated.historyRevision
        rejected("fresh header reusing deleted message ID") { try current.append(alternate, to: id) }
        try require(!((try conversation(current, id)).messages.contains { $0.id == alternate.id }))
        rejected("old SQLite compression header") { try stale.saveCompression(compression(alternate), to: id) }
        rejected("old SQLite attempt header") { try stale.saveAttempt(attempt, to: id) }
        rejected("old SQLite message append") { try stale.append(.init(role: .assistant, content: "stale late answer"), to: id) }
        let reopened = ConversationStore(file: current.file)
        let persisted = try conversation(reopened, id)
        try require(persisted.messages.map(\.id) == updated.messages.map(\.id) && persisted.compression == nil)
        try require(persisted.historyRevision == revision && persisted.replyAttempts?.isEmpty != false)
        try stale.reloadReplica()
        try require(stale.activities[id] == nil && peerCancellations == 1, "Another SQLite handle's deletion must invalidate on snapshot reload")
        try stale.append(.init(role: .user, content: "new legal question", date: prompt.date!.addingTimeInterval(5)), to: id)
        try current.reloadReplica()
        try require(try conversation(current, id).messages.last?.content == "new legal question")
    }

    private static func packet(_ record: ReplicaRecord, from store: ConversationStore) throws -> ReplicaPayload {
        var files: [String: Data] = [:]
        for item in try store.replicaAttachments(record) {
            files[item.fileName] = try Data(contentsOf: store.attachmentURL(item))
        }
        return .inline(ReplicaPacket(record: record, files: files))
    }

    private static func testSynchronization(_ root: URL) throws {
        let source = store(root, "sync-source")
        let peer = store(root, "sync-peer")
        let (id, prompt, _, alternate, _, unique) = try fixture(source)
        let before = try source.pendingReplica()
        guard let oldMessage = before.first(where: { $0.name == "m-" + alternate.id.uuidString }) else { throw FixtureFailure.missing }
        let stalePayload = try packet(oldMessage, from: source)
        for record in before { try peer.applyReplicaPayload(packet(record, from: source)) }
        try peer.reloadReplica()
        let (oldActivity, _, _, _) = try peer.beginReply(in: id, to: prompt.id, regenerating: true)
        var cancellations = 0
        peer.setCancellation(for: oldActivity) { cancellations += 1 }
        try source.deleteMessage(alternate.id, in: id)
        guard let deleted = try source.pendingReplica().first(where: { $0.name == oldMessage.name && $0.kind == "message_deleted" }) else { throw FixtureFailure.missing }
        try require(deleted.payload.isEmpty && (try source.replicaAttachments(deleted)).isEmpty)
        let asset = try ReplicaAsset.create(record: deleted, attachments: source.attachmentDirectory, hasAttachments: false)
        let bytes = try Data(contentsOf: asset.url)
        let json = String(decoding: bytes, as: UTF8.self)
        try require(!json.contains(alternate.content) && !json.contains(unique.fileName))
        let encodedPacket = try JSONDecoder().decode(ReplicaPacket.self, from: bytes)
        try require(encodedPacket.files.isEmpty && encodedPacket.record.payload.isEmpty)
        try peer.applyReplicaPayload(ReplicaPayload.read(asset.url))
        let after = try conversation(peer, id)
        try require(cancellations == 1 && peer.activities[id] == nil && after.replyAttempts?.isEmpty != false)
        try require(after.compression == nil && !after.messages.contains(where: { $0.id == alternate.id }))
        try require(!FileManager.default.fileExists(atPath: try peer.attachmentURL(unique).path))
        let (next, _, _, _) = try peer.beginReply(in: id, to: prompt.id, regenerating: true)
        peer.setCancellation(for: next) { cancellations += 1 }
        try peer.applyReplicaPayload(.inline(ReplicaPacket(record: deleted, files: [:])))
        try require(peer.activities[id] == next && cancellations == 1, "Exact replay must not cancel a new request")
        let newer = ReplicaRecord(name: deleted.name, kind: deleted.kind, conversation: deleted.conversation,
                                  revision: "9000000000000000002", payload: "")
        try peer.applyReplicaPayload(.inline(ReplicaPacket(record: newer, files: [:])))
        try require(peer.activities[id] == next && cancellations == 1, "Same tombstone name must not change history semantics")
        let sameHistory = try conversation(peer, id)
        try require(sameHistory.historyRevision == after.historyRevision)
        try require(sameHistory.replyAttempts?.contains(where: { $0.id == next.id }) == true)
        try peer.applyReplicaPayload(stalePayload)
        if case .inline(let stalePacket) = stalePayload {
            let future = ReplicaRecord(name: oldMessage.name, kind: "message", conversation: oldMessage.conversation,
                                       revision: "9000000000000000003", payload: oldMessage.payload)
            try peer.applyReplicaPayload(.inline(.init(record: future, files: stalePacket.files)))
        }
        try require(!FileManager.default.fileExists(atPath: try peer.attachmentURL(unique).path), "Stale file bytes must not be copied")
        try require(!((try conversation(peer, id)).messages.contains { $0.id == alternate.id }))
        let bodyForgery = ReplicaRecord(name: deleted.name, kind: deleted.kind, conversation: deleted.conversation,
                                        revision: deleted.revision, payload: oldMessage.payload)
        rejected("tombstone body on send") { _ = try ReplicaAsset.create(record: bodyForgery, attachments: source.attachmentDirectory, hasAttachments: false) }
        rejected("tombstone asset on send") { _ = try ReplicaAsset.create(record: deleted, attachments: source.attachmentDirectory, hasAttachments: true) }
        rejected("tombstone old files on receive") { try peer.applyReplicaPayload(.inline(ReplicaPacket(record: deleted, files: [unique.fileName: Data([2,4,6])]))) }
        rejected("tombstone old body on receive") { try peer.applyReplicaPayload(.inline(ReplicaPacket(record: bodyForgery, files: [:]))) }
        try require(peer.activities[id] == next && cancellations == 1)
        peer.endActivity(next)
    }

    private static func testUserAndOrphanReferences(_ root: URL) throws {
        let current = store(root, "user-and-orphans")
        let (id, prompt, original, alternate, shared, _) = try fixture(current)
        let headerID = try current.create()
        let headerShared = try conversation(current, headerID)
        var header = headerShared
        header.attachments = [shared]
        // Use the store's normal header update via a replica, including real file bytes.
        let encodedHeader = String(decoding: try JSONEncoder().encode(header), as: UTF8.self)
        let headerRecord = ReplicaRecord(name: "c-" + headerID.uuidString, kind: "conversation", conversation: headerID.uuidString,
                                         revision: "9000000000000000001", payload: encodedHeader)
        try current.applyReplicaPayload(packetFor(headerRecord, attachment: shared, in: current))
        try current.reloadReplica()
        let orphanParent = UUID()
        let orphan = ChatMessage(role: .user, content: "orphan sync file reference", attachments: [shared])
        let orphanRecord = ReplicaRecord(name: "m-" + orphan.id.uuidString, kind: "message", conversation: orphanParent.uuidString,
                                         revision: "0000000000000000007", payload: String(decoding: try JSONEncoder().encode(orphan), as: UTF8.self))
        try current.applyReplicaPayload(packetFor(orphanRecord, attachment: shared, in: current))
        try current.deleteMessage(prompt.id, in: id)
        let after = try conversation(current, id)
        try require(after.messages.map(\.id) == [original.id, alternate.id], "Single user deletion must retain replies as explicit orphans")
        try require(after.turns.count == 2 && after.contextMessages().map(\.id) == [original.id, alternate.id], "Deleting a prompt must retain surviving answers in context")
        try require(after.replyAttempts?.isEmpty != false && after.compression == nil)
        rejected("save attempt for deleted question") { try current.saveAttempt(.init(userMessageID: prompt.id), to: id) }
        try require(FileManager.default.fileExists(atPath: try current.attachmentURL(shared).path), "Other header and orphan replica references retain shared files")
        try current.deleteMessage(alternate.id, in: id)
        try require(FileManager.default.fileExists(atPath: try current.attachmentURL(shared).path))
    }

    private static func packetFor(_ record: ReplicaRecord, attachment: Attachment, in store: ConversationStore) throws -> ReplicaPayload {
        .inline(.init(record: record, files: [attachment.fileName: try Data(contentsOf: store.attachmentURL(attachment))]))
    }

    private static func testCleanupRetry(_ root: URL) throws {
        let current = store(root, "cleanup-retry")
        let item = try attachment(current, name: "retry.bin", bytes: Data([3,1,4]))
        let message = ChatMessage(role: .user, content: "delete despite cleanup failure", attachments: [item])
        var value = Conversation();value.messages=[message]
        try current.insert(value)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: current.attachmentDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.attachmentDirectory.path) }
        try current.deleteMessage(message.id, in: value.id)
        try require(try conversation(current, value.id).messages.isEmpty)
        try require(FileManager.default.fileExists(atPath: try current.attachmentURL(item).path), "The fixture must really fail file removal")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.attachmentDirectory.path)
        try require(current.retryDeletedAttachmentCleanup() == 0)
        try require(!FileManager.default.fileExists(atPath: try current.attachmentURL(item).path))
    }

    private static func testBackupCopiesWithOrphanReplies(_ root: URL) async throws {
        let current = store(root, "orphan-backup")
        let bytes = Data([7, 2, 5])
        let item = try attachment(current, name: "orphan.bin", bytes: bytes)
        let now = Date()
        let first = ChatMessage(role: .user, content: "retained first prompt", date: now)
        let firstAnswer = ChatMessage(role: .assistant, content: "retained first answer", date: now.addingTimeInterval(1), replyTo: first.id)
        let deleted = ChatMessage(role: .user, content: "DELETE-ONLY-THIS-QUESTION", date: now.addingTimeInterval(2))
        let orphan = ChatMessage(role: .assistant, content: "retained orphan original", date: now.addingTimeInterval(3), attachments: [item], replyTo: deleted.id)
        let alternate = ChatMessage(role: .assistant, content: "retained orphan alternate", date: now.addingTimeInterval(4), replyTo: deleted.id, isAlternative: true)
        let last = ChatMessage(role: .user, content: "retained final prompt", date: now.addingTimeInterval(5))
        let lastAnswer = ChatMessage(role: .assistant, content: "retained final answer", date: now.addingTimeInterval(6), replyTo: last.id)
        var value = Conversation()
        value.messages = [first, firstAnswer, deleted, orphan, alternate, last, lastAnswer]
        try current.insert(value)
        try current.deleteMessage(deleted.id, in: value.id)
        let surviving = try conversation(current, value.id)
        let expected = [first.content, firstAnswer.content, orphan.content, alternate.content, last.content, lastAnswer.content]
        try require(surviving.turns.map(\.id) == [first.id, orphan.id, alternate.id, last.id], "Missing-parent answers must remain at their original chronological position")
        try require(surviving.contextMessages().map(\.content) == expected, "Context must remove only the deleted question")
        try require(surviving.unansweredPrompt == nil)
        let file = try BackupFile.create(snapshot: current.backupSnapshot(settings: nil), attachments: current.attachmentDirectory)
        let prepared = try PreparedBackup.read(file.url)
        var original = surviving
        original.historyRevision = "untrusted-backup-epoch"
        original.compression = compression(orphan)
        original.replyAttempts = [.init(userMessageID: deleted.id, phase: .failed, partial: "stale absent prompt")]
        var reserved = Set(value.messages.map(\.id) + [value.id])
        func verify(_ copy: Conversation, copiedFiles: Bool) throws {
            try require(!reserved.contains(copy.id) && copy.id != value.id)
            let visible = Set(copy.messages.map(\.id))
            try require(visible.count == surviving.messages.count && visible.isDisjoint(with: reserved))
            let a = copy.messages.first { $0.content == orphan.content }!
            let b = copy.messages.first { $0.content == alternate.content }!
            let parent = a.replyTo!
            try require(parent == b.replyTo && !visible.contains(parent) && !reserved.contains(parent), "One absent source parent must map to one fresh absent parent per copy")
            try require(copy.historyRevision == nil && copy.compression == nil && copy.replyAttempts?.isEmpty != false)
            try require(copy.contextMessages().map(\.content) == expected)
            try require(!copy.messages.contains { $0.content == deleted.content })
            let retainedQuestion = copy.messages.first { $0.content == first.content }!
            let retainedAnswer = copy.messages.first { $0.content == firstAnswer.content }!
            try require(retainedAnswer.replyTo == retainedQuestion.id)
            let restoredFile = a.attachments!.first!
            try require(restoredFile.id == item.id && (try Data(contentsOf: current.attachmentURL(restoredFile))) == bytes)
            if copiedFiles { try require(restoredFile.fileName != item.fileName) }
            reserved.formUnion(visible)
            reserved.insert(parent)
            reserved.insert(copy.id)
        }
        try require(try current.importCopies([original]))
        try verify(current.conversations.first!, copiedFiles: false)
        try await current.importBackup(prepared, restoreInstructions: false, restoreSettings: false)
        try verify(current.conversations.first!, copiedFiles: true)
        try await current.importBackup(prepared, restoreInstructions: false, restoreSettings: false)
        try verify(current.conversations.first!, copiedFiles: true)
        let reopened = store(root, "orphan-backup")
        try require(reopened.conversations.count == 4)
        for copy in reopened.conversations where copy.id != value.id {
            try require(copy.contextMessages().map(\.content) == expected && copy.historyRevision == nil && copy.compression == nil)
        }
    }
}
