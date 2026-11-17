import CloudKit
import Foundation

struct CloudZoneChangePage {
    let records: [CKRecord]
    let deletions: [CKRecord.ID]
    let token: Data
    let moreComing: Bool
}

/// A separate zone cursor makes foreground and manual checks independent of
/// CKSyncEngine's database-change discovery. Replays use the normal replica merge.
@MainActor
final class CloudZoneCatchUp {
    enum Failure: Error, LocalizedError {
        case cursorMismatch, invalidProgress
        var errorDescription: String? {
            switch self {
            case .cursorMismatch: "本机 iCloud 增量检查点与当前账户或同步区不一致。"
            case .invalidProgress: "iCloud 增量检查没有取得新的同步进度。"
            }
        }
    }
    private struct Cursor: Codable {
        let owner: String
        let scope: String
        let token: Data
    }
    private let file: URL
    private let owner: String
    private let scope: String
    private let permitted: @MainActor () -> Bool
    private let fetch: @MainActor (Data?) async throws -> CloudZoneChangePage
    private let apply: @MainActor (CloudZoneChangePage) async throws -> Void
    private var running: (id: UUID, task: Task<Void, Error>)?

    init(file: URL, owner: String, scope: String,
         permitted: @escaping @MainActor () -> Bool,
         fetch: @escaping @MainActor (Data?) async throws -> CloudZoneChangePage,
         apply: @escaping @MainActor (CloudZoneChangePage) async throws -> Void) {
        self.file = file; self.owner = owner; self.scope = scope
        self.permitted = permitted; self.fetch = fetch; self.apply = apply
    }

    func run() async throws {
        try check()
        if let running { try await running.task.value; return }
        let id = UUID()
        let task = Task { try await self.drain() }
        running = (id, task)
        defer { if running?.id == id { running = nil } }
        try await task.value
    }

    @discardableResult
    func cancel() -> Task<Void, Error>? {
        let task = running?.task
        task?.cancel()
        return task
    }

    private func check() throws {
        try Task.checkCancellation()
        guard permitted() else { throw CancellationError() }
    }

    private func readCursor() throws -> Data? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let cursor = try JSONDecoder().decode(Cursor.self, from: data)
        guard cursor.owner == owner, cursor.scope == scope, !cursor.token.isEmpty else {
            throw Failure.cursorMismatch
        }
        return cursor.token
    }

    private func drain() async throws {
        try check()
        var token = try readCursor()
        var recoveredExpiredToken = false
        while true {
            try check()
            let page: CloudZoneChangePage
            do { page = try await fetch(token) }
            catch let error as CKError where error.code == .changeTokenExpired && token != nil && !recoveredExpiredToken {
                // Only an explicit server expiry permits a full zone replay.
                // Keep the old checkpoint until a replacement page is applied.
                token = nil; recoveredExpiredToken = true; continue
            }
            try check()
            guard !page.token.isEmpty, !page.moreComing || page.token != token else {
                throw Failure.invalidProgress
            }
            try await apply(page)
            try check()
            let cursor = Cursor(owner: owner, scope: scope, token: page.token)
            let data = try JSONEncoder().encode(cursor)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            token = page.token
            if !page.moreComing { return }
        }
    }

    static func fetch(database: CKDatabase, zone: CKRecordZone.ID, token data: Data?) async throws -> CloudZoneChangePage {
        let token: CKServerChangeToken?
        if let data {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            token = decoded
        } else { token = nil }
        let result = try await database.recordZoneChanges(inZoneWith: zone, since: token, resultsLimit: 128)
        let records = try result.modificationResultsByID.values.map { try $0.get().record }
        guard records.allSatisfy({ $0.recordID.zoneID == zone }), result.deletions.allSatisfy({ $0.recordID.zoneID == zone }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let serialized = try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
        return CloudZoneChangePage(records: records, deletions: result.deletions.map(\.recordID),
                                   token: serialized, moreComing: result.moreComing)
    }
}
