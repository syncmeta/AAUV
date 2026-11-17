import Foundation

/// Stages only the final HTTP body. The shared core still owns the provider's JSON schema.
struct InlineRequestBody {
    struct File {
        let attachment: RequestAttachment
        private let marker = "AAUV-" + UUID().uuidString

        var fields: [String: String] {
            var fields = attachment.fields
            fields["data"] = marker
            return fields
        }

        func range(in template: Data) throws -> Range<Data.Index> {
            // Match the entire Base64 slot so that model instructions and filenames stay untouched.
            let match = Data((",\(marker)\"").utf8)
            guard let range = template.range(of: match),
                  template.range(of: match, in: range.upperBound..<template.endIndex) == nil else {
                throw CocoaError(.fileWriteUnknown)
            }
            return (range.lowerBound + 1)..<(range.upperBound - 1)
        }
    }

    private let directory: PrivateTemporaryDirectory
    let url: URL
    let size: Int

    init(template: Data, files: [File]) throws {
        let parts = try files.map { (range: try $0.range(in: template), file: $0.attachment) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        directory = try PrivateTemporaryDirectory()
        url = directory.url.appending(path: "request.json")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var start = template.startIndex
        for part in parts {
            try output.write(contentsOf: template[start..<part.range.lowerBound])
            try Self.writeBase64(part.file, to: output)
            start = part.range.upperBound
        }
        try output.write(contentsOf: template[start..<template.endIndex])
        try output.close()
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        self.size = size
    }

    private static func writeBase64(_ file: RequestAttachment, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: file.url)
        defer { try? input.close() }
        var remaining = file.size
        var carry = Data()
        while let chunk = try input.read(upToCount: 192 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= remaining else { throw CocoaError(.fileReadCorruptFile) }
            remaining -= chunk.count
            carry.append(chunk)
            let count = carry.count - carry.count % 3
            try output.write(contentsOf: carry.prefix(count).base64EncodedData())
            carry = Data(carry.suffix(carry.count - count))
        }
        guard remaining == 0 else { throw CocoaError(.fileReadCorruptFile) }
        if !carry.isEmpty { try output.write(contentsOf: carry.base64EncodedData()) }
    }
}
