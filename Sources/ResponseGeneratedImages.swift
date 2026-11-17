import Foundation

enum ResponseGeneratedImages {
    struct OutputItem: Decodable, Sendable {
        let type: String
        let result: String?
        let status: String?

        private enum CodingKeys: String, CodingKey { case type, result, status }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? values.decode(String.self, forKey: .type)) ?? ""
            // A malformed image must not discard the completed text or other files.
            result = try? values.decode(String.self, forKey: .result)
            status = try? values.decode(String.self, forKey: .status)
        }
    }

    static func decode(_ images: [OutputItem], maximumBytes: Int, maximumCount: Int = 32) -> ChatClient.GeneratedFiles {
        var files: [ChatClient.GeneratedFiles.File] = []
        var remaining = max(0, min(maximumBytes, 32 * 1024 * 1024))
        for (index, image) in images.prefix(max(0, min(maximumCount, 32))).enumerated() {
            guard !Task.isCancelled else { break }
            guard image.type == "image_generation_call", let encoded = image.result,
                  image.status == nil || image.status == "completed",
                  encoded.utf8.count <= ((remaining + 2) / 3) * 4,
                  let data = Data(base64Encoded: encoded), data.count <= remaining,
                  let suffix = imageExtension(data) else { continue }
            remaining -= data.count
            files.append(.init(name: "generated-image-\(index + 1).\(suffix)", data: data))
        }
        return .init(files: files, unavailable: images.count - files.count)
    }

    private static func imageExtension(_ data: Data) -> String? {
        let header = Array(data.prefix(12))
        if header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "png" }
        if header.starts(with: [255, 216, 255]) { return "jpg" }
        if header.count == 12, header.starts(with: Array("RIFF".utf8)),
           header.suffix(4).elementsEqual("WEBP".utf8) { return "webp" }
        return nil
    }
}
