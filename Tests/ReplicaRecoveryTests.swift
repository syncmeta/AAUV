import CloudKit
import Foundation

@main
struct ReplicaRecoveryTests {
    @MainActor static func main() async throws {
        try await verifyStartupRetry()
        try await verifyLocalEditBetweenCloudBatches()
        let folder = try PrivateTemporaryDirectory()
        let file = folder.url.appending(path: "conversations.json")
        let store = ConversationStore(file: file)
        let id = try store.create()
        let messageID = UUID()
        let bytes = Data([42, 21, 0])
        let attachment = Attachment(name: "fixture.bin", fileName: UUID().uuidString, size: bytes.count)
        let message = ChatMessage(id: messageID, role: .user, content: "原始文件", attachments: [attachment])
        let current = try packet(message, in: id, revision: "0000000000000000002",
                                 files: [attachment.fileName: bytes])
        try store.applyReplicaPayload(.inline(current))
        let saved = try store.attachmentURL(attachment)
        let content = try Data(contentsOf: saved)
        precondition(content == bytes)

        // A stale payload may contain data that would conflict with the saved file.
        let stale = try packet(message, in: id, revision: "0000000000000000001",
                               files: [attachment.fileName: Data([0, 0, 0])])
        try store.applyReplicaPayload(.inline(stale))
        let preserved = try Data(contentsOf: saved)
        precondition(preserved == bytes)

        // The exact current replay is allowed to repair a missing local file.
        let cloudAsset = try ReplicaAsset.create(record: current.record, attachments: store.attachmentDirectory,
                                                 hasAttachments: true)
        try store.reloadReplica()
        let complete = await store.missingReplicaAttachmentRecords()
        precondition(complete.isEmpty)
        try FileManager.default.removeItem(at: saved)
        let missing = await store.missingReplicaAttachmentRecords()
        precondition(missing == [current.record.name])
        try store.applyReplicaPayload(.inline(stale))
        precondition(!FileManager.default.fileExists(atPath: saved.path))
        try store.applyReplicaPayload(ReplicaPayload.read(cloudAsset.url))
        let repaired = try Data(contentsOf: saved)
        precondition(repaired == bytes)
        let stillMissing = await store.missingReplicaAttachmentRecords()
        precondition(stillMissing.isEmpty)

        let replacementBytes = Data([1, 3, 5, 7])
        let replacement = Attachment(name: "replacement.bin", fileName: UUID().uuidString, size: replacementBytes.count)
        let updated = ChatMessage(id: messageID, role: .user, content: "新版正文", date: message.date, attachments: [replacement])
        let newPacket = try packet(updated, in: id, revision: "0000000000000000003",
                                   files: [replacement.fileName: replacementBytes])
        try store.applyReplicaPayload(.inline(newPacket))
        try store.applyReplicaPayload(.inline(current))
        try store.reloadReplica()
        let visible = store.conversations.first?.messages.first
        precondition(visible?.id == messageID && visible?.content == updated.content)
        precondition(visible?.attachments?.first?.fileName == replacement.fileName)
        let replacementURL = try store.attachmentURL(replacement)
        let syncedReplacement = try Data(contentsOf: replacementURL)
        precondition(syncedReplacement == replacementBytes)
        try store.requeueReplicaRecord(newPacket.record.name)
        let page = try store.pendingReplicaPage(after: nil)
        let count = try store.pendingReplicaCount()
        precondition(page.count == 2 && count == page.count)
        guard let position = page.first(where: { $0.name == newPacket.record.name }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let requeued = try store.pendingReplicaRecord(position)
        precondition(requeued?.revision == newPacket.record.revision && requeued?.payload == newPacket.record.payload)

        var deferrals = CloudUploadDeferrals()
        deferrals.insert(position, issue: "fixture attachment missing")
        precondition(page.filter { !deferrals.contains($0) }.map(\.name) == page.filter { $0.name != position.name }.map(\.name))
        let newer = ReplicaPosition(name: position.name, revision: "0000000000000000004")
        precondition(!deferrals.contains(newer))
        try deferrals.removeObsolete(using: store.pendingReplicaRevision)
        precondition(deferrals.contains(position) && deferrals.issue == "fixture attachment missing")
        let stillPending = try store.pendingReplicaRecord(position)
        precondition(stillPending?.payload == newPacket.record.payload)
        let manualRetry = CloudUploadDeferrals()
        precondition(!manualRetry.contains(position))

        try store.acknowledgeReplica(name: position.name, revision: position.revision)
        let acknowledged = try store.pendingReplicaRecord(position)
        let pendingRevision = try store.pendingReplicaRevision(position.name)
        precondition(acknowledged == nil && pendingRevision == nil)
        try deferrals.removeObsolete(using: store.pendingReplicaRevision)
        precondition(deferrals.issue == nil)

        // A message unseen before deletion must neither reappear nor leave a file.
        try store.delete(id)
        let lateAttachment = Attachment(name: "late.bin", fileName: UUID().uuidString, size: bytes.count)
        let late = try packet(ChatMessage(role: .user, content: "延迟送达", attachments: [lateAttachment]),
                              in: id, revision: "0000000000000000010", files: [lateAttachment.fileName: bytes])
        try store.applyReplicaPayload(.inline(late))
        try store.reloadReplica()
        let lateURL = try store.attachmentURL(lateAttachment)
        precondition(store.conversations.isEmpty && !FileManager.default.fileExists(atPath: lateURL.path))

        // The account reset checkpoint survives a new sync coordinator.
        let resetFile = folder.url.appending(path: "cloudkit-zone-state")
        try Data(#"{"zone":"encryptedReset","owner":"fixture-account"}"#.utf8).write(to: resetFile)
        let localCopy = try store.create()
        let reopened = ConversationStore(file: file)
        let sync = CloudSync(store: reopened)
        precondition(sync.syncLocked && !sync.recoveryRequired && reopened.conversations.first?.id == localCopy)

        // A corrupt or temporarily unreadable checkpoint must never be treated as a fresh library.
        let suite = "com.pendingname.aauv.fixture.cloud.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        defer { defaults.removePersistentDomain(forName: suite) }
        try Data("incomplete-checkpoint".utf8).write(to: resetFile)
        let paused = CloudSync(store: reopened, defaults: defaults)
        precondition(paused.status.contains("无法读取本机 iCloud 同步状态"))
        defaults.set(true, forKey: "cloudSyncEnabled")
        try FileManager.default.removeItem(at: resetFile)
        await paused.syncNow()
        precondition(paused.status.contains("无法读取本机 iCloud 同步状态") && !paused.busy)
        try Data(#"{"zone":"encryptedReset","owner":"fixture-account"}"#.utf8).write(to: resetFile)
        await paused.syncNow()
        precondition(paused.syncLocked && paused.status.contains("加密数据已重置"))
        precondition(reopened.conversations.first?.id == localCopy)
        print("Replica recovery passed: startup retry, offline edits, attachments, stale payloads, deletion, deferred uploads and unreadable checkpoints.")
    }

    @MainActor private static func verifyStartupRetry() async throws {
        let folder = try PrivateTemporaryDirectory()
        let suite = "com.pendingname.aauv.fixture.cloud-retry.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "cloudSyncEnabled")
        let store = ConversationStore(file: folder.url.appending(path: "conversations.json"))
        let id = try store.create()
        let queued = try store.pendingReplicaRevision("c-\(id.uuidString)")

        let fixture = StartupRetryFixture()
        let sync = CloudSync(store: store, defaults: defaults, openContainer: fixture.open, sleepBeforeRetry: fixture.wait)
        await sync.syncNow()
        try await fixture.until { fixture.delays == [.seconds(2)] }
        precondition(sync.waitingToRetry && !sync.busy)

        fixture.advance()
        try await fixture.until { fixture.delays == [.seconds(2), .seconds(37)] }
        await sync.syncNow()
        precondition(fixture.attempts == 2 && sync.waitingToRetry)

        fixture.advance()
        try await fixture.until { fixture.attempts == 3 && !sync.busy }
        precondition(!sync.waitingToRetry && sync.status.contains("同步暂停"))
        await sync.accountStatusDidChange()
        precondition(fixture.attempts == 4 && !sync.waitingToRetry && sync.status.contains("同步暂停"))

        await sync.syncNow()
        try await fixture.until { fixture.delays.count == 3 }
        precondition(fixture.delays.last == .seconds(2))
        await sync.stop()
        fixture.advance()
        try await fixture.until { fixture.cancelledSleep }
        precondition(!sync.waitingToRetry && fixture.attempts == 5)
        let remaining = try store.pendingReplicaRevision("c-\(id.uuidString)")
        precondition(queued != nil && remaining == queued && store.conversations.first?.id == id)
        precondition(!FileManager.default.fileExists(atPath: folder.url.appending(path: "cloudkit-zone-state").path))
    }

    @MainActor private final class StartupRetryFixture {
        private(set) var attempts = 0
        private(set) var delays: [Duration] = []
        private(set) var cancelledSleep = false
        private var sleeper: CheckedContinuation<Void, Never>?

        func open() async throws -> CKContainer {
            attempts += 1
            switch attempts {
            case 1, 5: throw CKError(.networkUnavailable)
            case 2: throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 37.0])
            case 3: throw CKError(.accountTemporarilyUnavailable)
            default: throw CKError(.badContainer)
            }
        }

        func wait(_ delay: Duration) async throws {
            delays.append(delay)
            await withCheckedContinuation { sleeper = $0 }
            cancelledSleep = Task.isCancelled
        }

        func advance() {
            let pending = sleeper
            sleeper = nil
            pending?.resume()
        }

        func until(_ ready: () -> Bool) async throws {
            for _ in 0..<200 {
                if ready() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Startup retry fixture timed out. Attempts \(attempts), delays \(delays), cancelled \(cancelledSleep)."
            ])
        }
    }

    @MainActor private static func verifyLocalEditBetweenCloudBatches() async throws {
        let folder = try PrivateTemporaryDirectory()
        let source = ConversationStore(file: folder.url.appending(path: "source/conversations.json"))
        let peerFile = folder.url.appending(path: "peer/conversations.json")
        let peer = ConversationStore(file: peerFile)
        let id = try source.create()
        for record in try source.pendingReplica() {
            try peer.applyReplicaBatch([.success(.inline(ReplicaPacket(record: record, files: [:])))])[0].get()
            try source.acknowledgeReplica(name: record.name, revision: record.revision)
        }
        precondition(peer.conversations.first?.title == "新对话")

        try source.rename(id, to: "远端改名")
        let bytes = Data([2, 3, 5, 7])
        let file = Attachment(name: "fixture.bin", fileName: UUID().uuidString, size: bytes.count)
        try FileManager.default.createDirectory(at: source.attachmentDirectory, withIntermediateDirectories: true)
        try bytes.write(to: source.attachmentURL(file))
        let remote = ChatMessage(role: .user, content: "远端附带文件", attachments: [file])
        try source.append(remote, to: id)
        let records = try source.pendingReplica()
        precondition(records.map(\.kind) == ["conversation", "message"])
        let header = try ReplicaAsset.create(record: records[0], attachments: source.attachmentDirectory, hasAttachments: false)
        let asset = try ReplicaAsset.create(record: records[1], attachments: source.attachmentDirectory, hasAttachments: true)
        let malformed = folder.url.appending(path: "malformed")
        try Data("corrupt packet".utf8).write(to: malformed)
        let incoming = [malformed, header.url, asset.url]

        let first = await Task.detached { ReplicaPayload.readBatch(incoming) }.value
        precondition(first.count == 2) // Leave the ZIP staged separately.
        let applied = try peer.applyReplicaBatch(first)
        guard case .failure = applied[0] else { throw CocoaError(.fileReadCorruptFile) }
        try applied[1].get()
        let local = ChatMessage(role: .user, content: "补取附件期间在本机发送")
        try peer.append(local, to: id)
        precondition(peer.conversations.first?.title == "远端改名")
        let pending = try peer.pendingReplica()
        precondition(pending.map(\.name) == ["m-\(local.id.uuidString)"])

        let second = await Task.detached { ReplicaPayload.readBatch(Array(incoming.dropFirst(first.count))) }.value
        precondition(second.count == 1)
        try peer.applyReplicaBatch(second)[0].get()
        let reopened = ConversationStore(file: peerFile)
        precondition(reopened.conversations.first?.title == "远端改名")
        precondition(reopened.conversations.first?.messages.map(\.id) == [remote.id, local.id])
        let received = try Data(contentsOf: reopened.attachmentURL(file))
        precondition(received == bytes)
    }

    private static func packet(_ message: ChatMessage, in conversation: UUID, revision: String,
                               files: [String: Data]) throws -> ReplicaPacket {
        let payload = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        let record = ReplicaRecord(name: "m-\(message.id.uuidString)", kind: "message",
                                   conversation: conversation.uuidString, revision: revision, payload: payload)
        return ReplicaPacket(record: record, files: files)
    }
}
