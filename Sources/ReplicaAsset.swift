import AAUVCore
import Foundation

struct ReplicaPosition: Decodable {
    let name: String
    let revision: String
}

struct ReplicaRecord: Codable, Sendable {
    let name: String
    let kind: String
    let conversation: String
    let revision: String
    let payload: String

    func validateMessageDeletion() throws {
        guard kind == "message_deleted", payload.isEmpty,
              UUID(uuidString: conversation) != nil, name.hasPrefix("m-"),
              UUID(uuidString: String(name.dropFirst(2))) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func messageDeletionAttachments() throws -> [Attachment] {
        try validateMessageDeletion()
        return []
    }
}

struct ReplicaPacket: Codable, Sendable {
    let record: ReplicaRecord
    let files: [String: Data]
}

enum ReplicaPayload: Sendable {
    case inline(ReplicaPacket)
    case zip(ReplicaRecord, PrivateTemporaryDirectory)

    var record: ReplicaRecord {
        switch self {
        case .inline(let packet): packet.record
        case .zip(let record, _): record
        }
    }

    static func read(_ url: URL) throws -> Self {
        try read(url, isZIP: hasZIPSignature(url))
    }

    // Keep one expanded ZIP at a time. Older inline assets can be larger than
    // the batch budget, in which case they also get their own batch.
    static func readBatch(_ urls: [URL?]) -> [Result<Self, Error>] {
        var remaining = 8 * 1024 * 1024
        var prepared: [Result<Self, Error>] = []
        for url in urls {
            do {
                guard let url, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let isZIP = try hasZIPSignature(url)
                if !prepared.isEmpty && (isZIP || size > remaining) { break }
                prepared.append(.success(try read(url, isZIP: isZIP)))
                if isZIP || size >= remaining { break }
                remaining -= size
            } catch {
                prepared.append(.failure(error))
            }
        }
        return prepared
    }

    private static func read(_ url: URL, isZIP: Bool) throws -> Self {
        if isZIP {
            let directory = try PrivateTemporaryDirectory()
            var error: NSError?
            let manifest = AauvcoreReadReplicaZIP(url.path, directory.url.path, &error)
            if let error { throw error }
            let record = try JSONDecoder().decode(ReplicaRecord.self, from: Data(manifest.utf8))
            return .zip(record, directory)
        }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 96 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return .inline(try JSONDecoder().decode(ReplicaPacket.self, from: Data(contentsOf: url)))
    }
}

struct ReplicaAsset: Sendable {
    private let directory: PrivateTemporaryDirectory
    var url: URL { directory.url.appending(path: "packet") }

    static func create(record: ReplicaRecord, attachments: URL, hasAttachments: Bool) throws -> Self {
        if record.kind == "message_deleted" {
            try record.validateMessageDeletion()
            guard !hasAttachments else { throw CocoaError(.fileReadCorruptFile) }
        }
        let asset = Self(directory: try PrivateTemporaryDirectory())
        let encoder = JSONEncoder()
        if hasAttachments {
            let manifest = String(decoding: try encoder.encode(record), as: UTF8.self)
            var error: NSError?
            guard AauvcoreWriteReplicaZIP(asset.url.path, attachments.path, manifest, &error) else {
                if let error { throw error }
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            try encoder.encode(ReplicaPacket(record: record, files: [:])).write(to: asset.url, options: .atomic)
        }
        return asset
    }
}
