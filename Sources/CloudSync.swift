import CloudKit
import Foundation
import Observation
#if os(macOS)
import Security
#endif

@MainActor @Observable
final class CloudSync: NSObject, CKSyncEngineDelegate {
    struct RunIntent: Equatable {
        let enabled: Bool
        let configurationUnavailable: Bool
        var allowed: Bool { enabled && !configurationUnavailable }
    }

    private enum ZoneState: String, Codable { case unknown, creating, joining, existing, recovery, encryptedReset }
    private struct Checkpoint: Codable, Equatable {
        let zone: ZoneState
        let owner: String
    }
    private static let recoveryMessage = "iCloud 同步区已删除或重置。本机数据已保留。"
    private static let encryptedResetMessage = "iCloud 加密数据已重置。当前资料库继续保存在本机，旧同步已停止。"
    private static let unreadableCheckpointMessage = "无法读取本机 iCloud 同步状态。请稍后重试，本机数据已保留。"
    private static let containerID = "iCloud.com.pendingname.aauv"
    private let zoneID = CKRecordZone.ID(zoneName: "AAUV", ownerName: CKCurrentUserDefaultName)
    private let store: ConversationStore
    private let defaults: UserDefaults
    private let openContainer: @MainActor () async throws -> CKContainer
    private let sleepBeforeRetry: @MainActor (Duration) async throws -> Void
    private let foregroundNow: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var cancellation: Task<Void, Never>?
    @ObservationIgnored private var database: CKDatabase?
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    @ObservationIgnored private var uploads: [String: ReplicaAsset] = [:]
    @ObservationIgnored private var uploadDeferrals = CloudUploadDeferrals()
    private(set) var status = "iCloud 同步已关闭"
    private(set) var busy = false
    @ObservationIgnored private var reconcileWhenIdle = false
    @ObservationIgnored private var foregroundCatchUpGeneration: Int?
    @ObservationIgnored private var lastSyncStarted: ContinuousClock.Instant?
    private(set) var attachmentRepairStatus: String?
    private var ready = false
    @ObservationIgnored private var missingKnownZone = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var checkpointReadFailed = false
    @ObservationIgnored private var startupBackoff = 2.0
    private var startupRetry: Task<Void, Never>?
    var waitingToRetry: Bool { startupRetry != nil }
    private var checkpoint: Checkpoint?
    private var zoneState: ZoneState { checkpoint?.zone ?? .unknown }
    var recoveryRequired: Bool { zoneState == .recovery }
    var syncLocked: Bool { zoneState == .encryptedReset }
    var runIntent: RunIntent {
        RunIntent(enabled: defaults.bool(forKey: "cloudSyncEnabled"),
                  configurationUnavailable: store.configurationUnavailable)
    }
    private var unavailableStatus: String {
        store.configurationUnavailable ? "本机配置恢复未完成，iCloud 同步已暂停。" : "iCloud 同步已关闭"
    }
    private var suspendedStatus: String? {
        if syncLocked { return Self.encryptedResetMessage }
        if recoveryRequired { return Self.recoveryMessage }
        return nil
    }

    init(store: ConversationStore, defaults: UserDefaults = .standard,
         openContainer: @escaping @MainActor () async throws -> CKContainer = { try await CloudSync.availableContainer() },
         sleepBeforeRetry: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         foregroundNow: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.store = store
        self.defaults = defaults
        self.openContainer = openContainer
        self.sleepBeforeRetry = sleepBeforeRetry
        self.foregroundNow = foregroundNow
        super.init()
        readCheckpoint()
    }

    private func readCheckpoint() {
        do {
            let data = try Data(contentsOf: zoneStateURL)
            let saved = try JSONDecoder().decode(Checkpoint.self, from: data)
            guard !saved.owner.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            checkpoint = saved
            checkpointReadFailed = false
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile && !checkpointReadFailed {
            // Only the first read of an absent checkpoint represents a fresh library.
        } catch {
            checkpointReadFailed = true
            status = Self.unreadableCheckpointMessage
        }
    }

    private var stateURL: URL {
        store.file.deletingLastPathComponent().appending(path: "cloudkit-state.json")
    }

    private var zoneStateURL: URL {
        store.file.deletingLastPathComponent().appending(path: "cloudkit-zone-state")
    }

    private func setZoneState(_ state: ZoneState, owner: String? = nil) throws {
        guard let owner = owner ?? checkpoint?.owner else { throw CocoaError(.fileWriteUnknown) }
        let next = Checkpoint(zone: state, owner: owner)
        guard next != checkpoint else { return }
        try writeProtected(JSONEncoder().encode(next), to: zoneStateURL)
        checkpoint = next
    }

    private func requireZoneRecovery() throws -> Never {
        try setZoneState(.recovery)
        throw ChatClient.ClientError.message(Self.recoveryMessage)
    }

    private func lockAfterEncryptedReset() throws -> Never {
        try setZoneState(.encryptedReset)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            try FileManager.default.removeItem(at: stateURL)
        }
        throw ChatClient.ClientError.message(Self.encryptedResetMessage)
    }

    @discardableResult
    private func detach(_ message: String) -> Task<Void, Never>? {
        let running = engine
        let assets = uploads
        engine = nil
        database = nil
        ready = false
        missingKnownZone = false
        store.onLocalChange = nil
        uploads.removeAll()
        systemFields.removeAll()
        uploadDeferrals = CloudUploadDeferrals()
        attachmentRepairStatus = nil
        status = message
        guard let running else { return cancellation }
        // Delegate callbacks must return before an in-flight engine can finish cancelling.
        let previous = cancellation
        let next = Task {
            await previous?.value
            await running.cancelOperations()
            withExtendedLifetime(assets) {}
        }
        cancellation = next
        return next
    }

    @discardableResult
    private func suspend(_ message: String) -> Task<Void, Never>? {
        generation += 1
        startupRetry?.cancel()
        startupRetry = nil
        reconcileWhenIdle = false
        foregroundCatchUpGeneration = nil
        lastSyncStarted = nil
        startupBackoff = 2
        busy = false
        return detach(message)
    }

    // Every cloud/delegate continuation uses the same live device preference
    // and configuration-publication fence, not a captured pre-await Boolean.
    private func permitsWork(generation expectedGeneration: Int? = nil, engine expectedEngine: CKSyncEngine? = nil,
                             honoringCancellation: Bool = true) -> Bool {
        guard runIntent.allowed else {
            suspend(unavailableStatus)
            return false
        }
        guard expectedGeneration == nil || expectedGeneration == generation,
              expectedEngine == nil || expectedEngine === engine else { return false }
        return !honoringCancellation || !Task.isCancelled
    }

    private func requireWork(generation: Int) throws {
        guard permitsWork(generation: generation) else { throw CancellationError() }
    }

    func stop() async {
        await suspend(unavailableStatus)?.value
    }

    func reconcileRunIntent() async {
        guard runIntent.allowed else { await stop(); return }
        guard !Task.isCancelled else { return }
        if busy {
            // Keep the one final intent that arrived while an obsolete caller
            // was unwinding. Do not turn an error into an unconditional retry.
            reconcileWhenIdle = true
            return
        }
        await syncNow()
    }

    private func finishedSync(generation completedGeneration: Int, succeeded: Bool) {
        guard generation == completedGeneration else { return }
        busy = false
        let requested = reconcileWhenIdle
        reconcileWhenIdle = false
        let catchUp = foregroundCatchUpGeneration == completedGeneration
        foregroundCatchUpGeneration = nil
        // Only an external foreground transition queues this work. A failed
        // operation never turns its own completion into another fetch/retry.
        if catchUp, succeeded, runIntent.allowed, engine != nil, startupRetry == nil {
            Task { [weak self] in
                guard let self, self.generation == completedGeneration else { return }
                await self.foregroundActivated()
            }
            return
        }
        guard requested, runIntent.allowed, engine == nil, startupRetry == nil else { return }
        Task { [weak self] in
            guard let self, self.generation == completedGeneration else { return }
            await self.reconcileRunIntent()
        }
    }

    func syncNow() async {
        guard permitsWork(), !busy, !waitingToRetry else { return }
        startupBackoff = 2
        await sync(recovering: false)
    }

    func foregroundActivated() async {
        guard permitsWork(), !waitingToRetry, !recoveryRequired, !syncLocked else { return }
        // Startup and multiple windows may report the same activation. Keep
        // those requests together without a timer or bypassing retry backoff.
        let now = foregroundNow()
        if let lastSyncStarted, lastSyncStarted.duration(to: now) < .seconds(5) { return }
        if busy {
            foregroundCatchUpGeneration = generation
            return
        }
        await syncNow()
    }

    func accountStatusDidChange() async {
        guard permitsWork(), engine == nil else { return }
        await syncNow()
    }

    func restoreFromLocal() async { await sync(recovering: true) }

    private func sync(recovering: Bool) async {
        guard permitsWork(), !busy else { return }
        if checkpointReadFailed {
            readCheckpoint()
            guard !checkpointReadFailed else { return }
        }
        guard !recovering || recoveryRequired else { return }
        if let suspendedStatus, !recovering { status = suspendedStatus; return }
        let generation = self.generation
        busy = true
        lastSyncStarted = foregroundNow()
        var succeeded = false
        defer { finishedSync(generation: generation, succeeded: succeeded) }
        status = "正在同步…"
        var running: CKSyncEngine?
        do {
            if engine == nil { try await start(recovering: recovering, generation: generation) }
            guard permitsWork(generation: generation), let engine else { return }
            running = engine
            do { try await engine.fetchChanges() }
            catch let error as CKError where Self.isMissingZone(error) {
                guard permitsWork(generation: generation, engine: engine) else { return }
                if zoneState == .existing { try requireZoneRecovery() }
            }
            guard permitsWork(generation: generation, engine: engine) else { return }
            if missingKnownZone { try requireZoneRecovery() }
            if zoneState == .joining { try setZoneState(.existing) }
            try await repairMissingAttachments(from: engine)
            guard permitsWork(generation: generation, engine: engine) else { return }
            uploadDeferrals = CloudUploadDeferrals()
            ready = true
            try enqueue(engine)
            try await engine.sendChanges()
            guard permitsWork(generation: generation, engine: engine) else { return }
            if status == "正在同步…" { try updateStatus() }
            succeeded = true
        } catch {
            guard permitsWork(generation: generation, engine: running) else { return }
            if let suspendedStatus { detach(suspendedStatus) }
            else if let error = error as? CKError, Self.engineRetries(error), engine != nil {
                status = "等待 iCloud 重试。\(error.localizedDescription)"
            } else if let error = error as? CKError, !recovering, engine == nil, Self.startupRetries(error) {
                status = "暂时无法连接 iCloud，将自动重试。\(error.localizedDescription)"
                scheduleStartupRetry(after: error)
            } else { status = "iCloud 同步暂停。\(error.localizedDescription)" }
        }
    }

    private static func isMissingZone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    private static func engineRetries(_ error: CKError) -> Bool {
        switch error.code {
        case .notAuthenticated, .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable,
             .requestRateLimited, .serviceUnavailable, .zoneBusy: return true
        default: return false
        }
    }

    private static func startupRetries(_ error: CKError) -> Bool {
        switch error.code {
        case .networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable, .zoneBusy: return true
        default: return false
        }
    }

    private func scheduleStartupRetry(after error: CKError) {
        guard permitsWork() else { return }
        let generation = self.generation
        let serverDelay = error.retryAfterSeconds ?? 0
        let delay = max(startupBackoff, serverDelay.isFinite ? min(serverDelay, Double(Int32.max)) : 0)
        startupBackoff = min(startupBackoff * 2, 60)
        startupRetry = Task { [weak self, sleepBeforeRetry] in
            do { try await sleepBeforeRetry(.seconds(delay)) }
            catch { return }
            guard let self, self.permitsWork(generation: generation) else { return }
            self.startupRetry = nil
            await self.sync(recovering: false)
        }
    }

    private static func availableContainer() async throws -> CKContainer {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              services.contains("CloudKit"), containers.contains(containerID) else {
            throw ChatClient.ClientError.message("这个 Mac 构建尚未配置 iCloud 签名能力。请使用支持 iCloud 的签名版本。")
        }
        #endif
        let container = CKContainer(identifier: Self.containerID)
        switch try await container.accountStatus() {
        case .available:
            return container
        case .couldNotDetermine:
            throw CKError(.networkUnavailable, userInfo: [NSLocalizedDescriptionKey: "暂时无法确认 iCloud 账户状态。"])
        case .temporarilyUnavailable:
            throw ChatClient.ClientError.message("iCloud 账户暂时无法使用。请稍后再试。")
        default:
            throw ChatClient.ClientError.message("请先在系统设置登录 iCloud。")
        }
    }

    private func start(recovering: Bool, generation: Int) async throws {
        try requireWork(generation: generation)
        await cancellation?.value
        try requireWork(generation: generation)
        let container = try await openContainer()
        try requireWork(generation: generation)
        let account = try await container.userRecordID().recordName
        try requireWork(generation: generation)
        let owner = checkpoint?.owner ?? defaults.string(forKey: "aauv.cloud.owner")
        if let owner, owner != account {
            throw ChatClient.ClientError.message("本机同步记录属于另一个 iCloud 账户。请切回原账户。")
        }
        let hadCursor = FileManager.default.fileExists(atPath: stateURL.path)
        if hadCursor, owner == nil {
            throw ChatClient.ClientError.message("无法确认原 iCloud 同步账户。本机记录仍可打开和导出。")
        }
        let database = container.privateCloudDatabase
        let zoneExists: Bool
        do {
            _ = try await database.recordZone(for: zoneID)
            zoneExists = true
        } catch let error as CKError where Self.isMissingZone(error) || error.code == .unknownItem {
            try requireWork(generation: generation)
            zoneExists = false
        }
        try requireWork(generation: generation)
        let confirmedAccount = try await container.userRecordID().recordName
        try requireWork(generation: generation)
        guard confirmedAccount == account else {
            throw ChatClient.ClientError.message("iCloud 账户已变化，同步已暂停。")
        }
        try requireWork(generation: generation)

        let knownZone = !recovering && (zoneState == .existing || (zoneState == .unknown && hadCursor))

        try store.prepareReplica()
        if recovering {
            try store.requeueReplica()
            if hadCursor { try FileManager.default.removeItem(at: stateURL) }
        }
        try setZoneState(knownZone ? .existing : zoneExists ? .joining : .creating, owner: account)
        defaults.set(account, forKey: "aauv.cloud.owner")
        let state = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data(contentsOf: stateURL))
        let config = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        let engine = CKSyncEngine(config)
        self.database = database
        self.engine = engine
        missingKnownZone = knownZone && !zoneExists
        if !zoneExists && !missingKnownZone {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        store.onLocalChange = { [weak self] in
            guard let self, let engine = self.engine,
                  self.permitsWork(engine: engine, honoringCancellation: false), self.ready else { return }
            do {
                try self.enqueue(engine)
                try self.updateStatus(honoringCancellation: false)
            } catch { self.status = "无法更新 iCloud 同步状态。" }
        }
    }

    private func enqueue(_ engine: CKSyncEngine) throws {
        guard permitsWork(engine: engine, honoringCancellation: false) else { throw CancellationError() }
        var tracked = Set(engine.state.pendingRecordZoneChanges)
        var additions: [CKSyncEngine.PendingRecordZoneChange] = []
        var position: ReplicaPosition?
        while true {
            let page = try store.pendingReplicaPage(after: position)
            guard let last = page.last else { break }
            position = last
            for entry in page where !uploadDeferrals.contains(entry) {
                let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(entry.name))
                if tracked.insert(change).inserted { additions.append(change) }
            }
        }
        if !additions.isEmpty { engine.state.add(pendingRecordZoneChanges: additions) }
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    private func updateStatus(honoringCancellation: Bool = true) throws {
        guard permitsWork(honoringCancellation: honoringCancellation) else { return }
        try uploadDeferrals.removeObsolete(using: store.pendingReplicaRevision)
        let count = try store.pendingReplicaCount()
        if count == 0 {
            status = "iCloud 记录已同步"
        } else if let issue = uploadDeferrals.issue {
            status = "等待同步 \(count) 条记录。\(issue) 可点「立即同步」重试。"
        } else {
            status = "等待同步 \(count) 条记录"
        }
    }

    private func postponeUpload(_ id: CKRecord.ID, revision: String?, message: String, in syncEngine: CKSyncEngine) throws {
        guard permitsWork(engine: syncEngine) else { throw CancellationError() }
        guard let pending = try store.pendingReplicaRevision(id.recordName), revision == nil || revision == pending else { return }
        uploadDeferrals.insert(ReplicaPosition(name: id.recordName, revision: pending), issue: message)
        // The SQLite outbox keeps the record while the engine stops scheduling this revision.
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
    }

    private func repairMissingAttachments(from syncEngine: CKSyncEngine) async throws {
        guard permitsWork(engine: syncEngine), let database, zoneState == .existing else { return }
        let names = await store.missingReplicaAttachmentRecords()
        guard permitsWork(engine: syncEngine) else { return }
        guard !names.isEmpty else { attachmentRepairStatus = nil; return }
        let repairing = "正在从 iCloud 补齐本机缺失的附件…"
        attachmentRepairStatus = repairing
        defer {
            if permitsWork(engine: syncEngine), attachmentRepairStatus == repairing {
                attachmentRepairStatus = "附件补取已中断，可再次同步。"
            }
        }
        // Fetch one asset at a time so several large records cannot fill the staging disk together.
        for name in names {
            guard permitsWork(engine: syncEngine) else { return }
            do {
                let record = try await database.record(for: recordID(name))
                guard permitsWork(engine: syncEngine) else { return }
                try await receive([record], from: syncEngine)
                guard permitsWork(engine: syncEngine) else { return }
            } catch {
                guard permitsWork(engine: syncEngine) else { return }
                if let error = error as? CKError {
                    if Self.isMissingZone(error) { try requireZoneRecovery() }
                    if Self.engineRetries(error) { break }
                }
                // A missing or invalid cloud copy must not prevent other files from being repaired.
            }
        }
        let remaining = await store.missingReplicaAttachmentRecords().count
        guard permitsWork(engine: syncEngine) else { return }
        attachmentRepairStatus = remaining == 0 ? nil : "还有 \(remaining) 条记录的附件未补齐，可稍后再次同步。"
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard permitsWork(engine: syncEngine, honoringCancellation: false) else { return }
        if case .accountChange(let change) = event {
            // Account changes must still invalidate the session even if the
            // task delivering the notification is being cancelled.
            if case .signIn(let current) = change.changeType,
               current.recordName == checkpoint?.owner { return }
            detach("iCloud 账户已变化，同步已暂停。")
            return
        }
        guard !Task.isCancelled else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                try writeProtected(JSONEncoder().encode(update.stateSerialization), to: stateURL)
            case .fetchedDatabaseChanges(let changes):
                if zoneState == .existing {
                    let deletions = changes.deletions.filter { $0.zoneID == zoneID }
                    if deletions.contains(where: { $0.reason == .encryptedDataReset }) { try lockAfterEncryptedReset() }
                    if !deletions.isEmpty { try requireZoneRecovery() }
                }
            case .fetchedRecordZoneChanges(let changes):
                var removedRecord = false
                for item in changes.deletions where item.recordID.zoneID == zoneID {
                    let name = item.recordID.recordName
                    systemFields.removeValue(forKey: name)
                    try store.requeueReplicaRecord(name)
                    removedRecord = true
                }
                let records = changes.modifications.map(\.record).filter { $0.recordID.zoneID == zoneID }
                try await receive(records, from: syncEngine)
                guard permitsWork(engine: syncEngine) else { return }
                if ready, removedRecord { try enqueue(syncEngine) }
            case .didFetchRecordZoneChanges(let result):
                guard result.zoneID == zoneID else { return }
                if let error = result.error {
                    if Self.isMissingZone(error) {
                        if zoneState == .existing { try requireZoneRecovery() }
                    } else if Self.engineRetries(error) {
                        status = "等待 iCloud 重试。\(error.localizedDescription)"
                    } else { throw error }
                } else if !ready, !missingKnownZone {
                    if zoneState == .joining { try setZoneState(.existing) }
                    ready = true
                    try enqueue(syncEngine)
                    try updateStatus()
                }
            case .sentDatabaseChanges(let result):
                if result.savedZones.contains(where: { $0.zoneID == zoneID }) { try setZoneState(.existing) }
                if let failure = result.failedZoneSaves.first(where: { $0.zone.zoneID == zoneID }) {
                    if Self.engineRetries(failure.error) {
                        status = "等待 iCloud 重试。\(failure.error.localizedDescription)"
                    } else { throw failure.error }
                }
            case .sentRecordZoneChanges(let result):
                var review = Set(result.savedRecords.map(\.recordID))
                for record in result.savedRecords {
                    uploads.removeValue(forKey: record.recordID.recordName)
                    remember(record)
                    if let revision = record["revision"] as? String {
                        try store.acknowledgeReplica(name: record.recordID.recordName, revision: revision)
                    }
                }
                for failure in result.failedRecordSaves {
                    let id = failure.record.recordID
                    let revision = failure.record["revision"] as? String
                    uploads.removeValue(forKey: id.recordName)
                    if Self.engineRetries(failure.error) { continue }
                    review.insert(id)
                    if Self.isMissingZone(failure.error) {
                        if zoneState == .existing { try requireZoneRecovery() }
                        try setZoneState(.creating)
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    } else if failure.error.code == .unknownItem {
                        if systemFields.removeValue(forKey: id.recordName) == nil {
                            try postponeUpload(id, revision: revision, message: failure.error.localizedDescription, in: syncEngine)
                        }
                    } else if failure.error.code == .serverRecordChanged, let database {
                        do {
                            // Conflict snapshots do not contain the staged asset bytes.
                            let server = try await database.record(for: id)
                            guard permitsWork(engine: syncEngine) else { return }
                            try await receive([server], from: syncEngine)
                            guard permitsWork(engine: syncEngine) else { return }
                        } catch let error as CKError where error.code == .unknownItem {
                            guard permitsWork(engine: syncEngine) else { return }
                            systemFields.removeValue(forKey: id.recordName)
                        } catch {
                            guard permitsWork(engine: syncEngine) else { return }
                            try postponeUpload(id, revision: revision,
                                               message: "云端冲突等待重新读取。\(error.localizedDescription)", in: syncEngine)
                        }
                    } else {
                        try postponeUpload(id, revision: revision, message: failure.error.localizedDescription, in: syncEngine)
                    }
                }
                guard permitsWork(engine: syncEngine) else { return }
                // A save may acknowledge an older revision while a local edit is
                // still pending. Re-add only records involved in this batch.
                let retry = try review.compactMap { id -> CKSyncEngine.PendingRecordZoneChange? in
                    guard let revision = try store.pendingReplicaRevision(id.recordName),
                          !uploadDeferrals.contains(ReplicaPosition(name: id.recordName, revision: revision)) else { return nil }
                    return .saveRecord(id)
                }
                if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
                try updateStatus()
            case .didSendChanges:
                try updateStatus()
            default:
                break
            }
        } catch {
            guard permitsWork(engine: syncEngine, honoringCancellation: false) else { return }
            // Do not persist a later CloudKit cursor if a fetched record could not be applied.
            detach(suspendedStatus ?? "iCloud 同步暂停。\(error.localizedDescription)")
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard permitsWork(engine: syncEngine), ready, zoneState == .existing else { return nil }
        do {
            var position: ReplicaPosition?
            var records: [CKRecord] = []
            var selected: Set<String> = []
            batch: while true {
                let page = try store.pendingReplicaPage(after: position)
                guard let last = page.last else { break }
                position = last
                for candidate in page {
                    if records.count == 50 { break batch }
                    let name = candidate.name
                    guard !uploadDeferrals.contains(candidate), !selected.contains(name),
                          context.options.scope.contains(recordID(name)) else { continue }
                    do {
                        guard let entry = try store.pendingReplicaRecord(candidate) else { continue }
                        let hasAttachments = try !store.replicaAttachments(entry).isEmpty
                        if hasAttachments && !records.isEmpty { break batch }
                        guard let record = try await makeRecord(entry, hasAttachments: hasAttachments, for: syncEngine) else { continue }
                        guard permitsWork(engine: syncEngine) else { return nil }
                        records.append(record)
                        selected.insert(name)
                        if hasAttachments { break batch }
                    } catch {
                        guard permitsWork(engine: syncEngine) else { return nil }
                        try postponeUpload(recordID(name), revision: candidate.revision,
                                           message: "部分记录无法准备上传。\(error.localizedDescription)", in: syncEngine)
                    }
                }
            }
            if uploadDeferrals.issue != nil { try updateStatus() }
            guard permitsWork(engine: syncEngine), !records.isEmpty else { return nil }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: [], atomicByZone: false)
        } catch {
            guard permitsWork(engine: syncEngine, honoringCancellation: false) else { return nil }
            status = "无法准备 iCloud 上传。\(error.localizedDescription)"
            return nil
        }
    }

    private func makeRecord(_ entry: ReplicaRecord, hasAttachments: Bool, for syncEngine: CKSyncEngine) async throws -> CKRecord? {
        guard permitsWork(engine: syncEngine) else { throw CancellationError() }
        let attachments = store.attachmentDirectory
        let asset = try await Task.detached {
            try ReplicaAsset.create(record: entry, attachments: attachments, hasAttachments: hasAttachments)
        }.value
        guard permitsWork(engine: syncEngine) else { throw CancellationError() }
        guard try store.pendingReplicaRevision(entry.name) == entry.revision else { return nil }
        let record: CKRecord
        if let fields = systemFields[entry.name] {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: fields)
            decoder.requiresSecureCoding = true
            defer { decoder.finishDecoding() }
            record = CKRecord(coder: decoder) ?? CKRecord(recordType: "AAUVRecord", recordID: recordID(entry.name))
        } else {
            record = CKRecord(recordType: "AAUVRecord", recordID: recordID(entry.name))
        }
        record["revision"] = entry.revision
        uploads[entry.name] = asset
        record["packet"] = CKAsset(fileURL: asset.url)
        return record
    }

    private func receive(_ records: [CKRecord], from syncEngine: CKSyncEngine) async throws {
        guard permitsWork(engine: syncEngine) else { throw CancellationError() }
        var remaining = records[...]
        var rejected: Error?
        while !remaining.isEmpty {
            guard permitsWork(engine: syncEngine) else { throw CancellationError() }
            let urls = remaining.prefix(128).map { record in
                record.recordType == "AAUVRecord" ? (record["packet"] as? CKAsset)?.fileURL : nil
            }
            let prepared = await Task.detached { ReplicaPayload.readBatch(urls) }.value
            guard permitsWork(engine: syncEngine) else { throw CancellationError() }
            let batch = remaining.prefix(prepared.count)
            let payloads = zip(batch, prepared).map { record, result in
                result.flatMap { payload -> Result<ReplicaPayload, Error> in
                    guard payload.record.name == record.recordID.recordName,
                          payload.record.revision == record["revision"] as? String else {
                        return .failure(CocoaError(.fileReadCorruptFile))
                    }
                    return .success(payload)
                }
            }
            let results = try store.applyReplicaBatch(payloads)
            for (record, result) in zip(batch, results) {
                switch result {
                case .success: remember(record)
                case .failure(let error): if rejected == nil { rejected = error }
                }
            }
            remaining = remaining.dropFirst(prepared.count)
        }
        if let rejected { throw rejected }
    }

    private func remember(_ record: CKRecord) {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder)
        encoder.finishEncoding()
        systemFields[record.recordID.recordName] = encoder.encodedData
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}

struct CloudUploadDeferrals {
    private var records: [String: (revision: String, issue: String)] = [:]

    var issue: String? { records.values.first?.issue }

    func contains(_ entry: ReplicaPosition) -> Bool {
        records[entry.name]?.revision == entry.revision
    }

    mutating func insert(_ entry: ReplicaPosition, issue: String) {
        records[entry.name] = (entry.revision, issue)
    }

    mutating func removeObsolete(using pendingRevision: (String) throws -> String?) rethrows {
        records = try records.filter { name, failure in try pendingRevision(name) == failure.revision }
    }
}
