import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Keep the Photos provider's file alive until AAUV has staged its own draft.
/// PhotosPicker grants access only to the items the user actually chooses.
struct PendingPickedImage: Transferable, Sendable {
    private let directory: PrivateTemporaryDirectory
    let url: URL

    init(copying source: URL) throws {
        let directory = try PrivateTemporaryDirectory()
        let name = source.lastPathComponent.isEmpty ? "Image" : source.lastPathComponent
        let target = directory.url.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        self.directory = directory
        self.url = target
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try PendingPickedImage(copying: received.file)
        }
    }
}
