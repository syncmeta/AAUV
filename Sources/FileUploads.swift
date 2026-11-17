import Foundation
import Network

extension ChatClient {
    static func withRequestFiles<T>(
        _ files: [RequestAttachment], configuration: Configuration, proxy: ProxyConfiguration?,
        validateRoute: ProxyRouteCheck? = nil,
        validateCredential: AsyncCredentialCheck? = nil,
        onCleanupFailure: (@MainActor (Int) -> Void)?,
        perform: ([AttachmentInput]) async throws -> T
    ) async throws -> T {
        if RequestAttachment.fitsInline(files) || configuration.apiProtocol != "responses" ||
            configuration.credentialKind != "byok" {
            return try await perform(files.map(AttachmentInput.inline))
        }

        let api = FilesAPI(configuration: configuration, proxy: proxy, validateRoute: validateRoute,
                           validateCredential: validateCredential)
        var ids: [String] = []
        let result: Result<T, Error>
        do {
            var attachments: [AttachmentInput] = []
            var uploadAvailable = true
            for file in files {
                try Task.checkCancellation()
                if !uploadAvailable {
                    attachments.append(.inline(file))
                    continue
                }
                do {
                    let id = try await api.upload(file)
                    if !ids.contains(id) { ids.append(id) }
                    var fields = file.fields
                    fields["file_id"] = id
                    attachments.append(.uploaded(fields))
                } catch FilesAPI.Unavailable.endpoint {
                    uploadAvailable = false
                    attachments.append(.inline(file))
                } catch FilesAPI.Unavailable.attachment {
                    attachments.append(.inline(file))
                }
            }
            try Task.checkCancellation()
            result = .success(try await perform(attachments))
        } catch {
            result = .failure(error)
        }
        if !ids.isEmpty {
            let uploaded = ids
            // A cancelled model request must still clean up files already uploaded.
            let remaining = await Task.detached { await api.remove(uploaded) }.value
            if remaining != 0 { await onCleanupFailure?(remaining) }
        }
        return try result.get()
    }
}

private struct FilesAPI {
    let configuration: ChatClient.Configuration
    let proxy: ProxyConfiguration?
    let validateRoute: ProxyRouteCheck?
    let validateCredential: AsyncCredentialCheck?

    enum Unavailable: Error {
        case endpoint, attachment
    }

    private var endpoint: URL { configuration.baseURL.appending(component: "files") }

    func upload(_ file: RequestAttachment) async throws -> String {
        let directory = try PrivateTemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let boundary = "AAUV-\(UUID())"
        let body = directory.url.appending(path: "multipart")
        try writeMultipart(file, boundary: boundary, to: body)
        let session = ChatClient.session(proxy: proxy, resourceTimeout: 300)
        defer { session.invalidateAndCancel() }
        var request = request(method: "POST", url: endpoint)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try await validateCredential?()
        try Task.checkCancellation()
        try await validateRoute?()
        let (data, response) = try await session.upload(for: request, fromFile: body)
        guard ChatClient.isSuccessful(response) else {
            if let code = (response as? HTTPURLResponse)?.statusCode, [404, 405, 501].contains(code) {
                throw Unavailable.endpoint
            }
            let error = ChatClient.serviceError(response, body: data.prefix(8192), key: configuration.key)
            if case .service(let diagnostic, let detail) = error {
                if [400, 422].contains(diagnostic.status),
                   let parameter = diagnostic.parameter,
                   ["expires_after", "expires_after[anchor]", "expires_after[seconds]",
                    "expires_after.anchor", "expires_after.seconds"].contains(parameter) {
                    // Do not retry an upload without an expiry on a compatible endpoint.
                    throw Unavailable.endpoint
                }
                if diagnostic.status == 415 || ([400, 422].contains(diagnostic.status) &&
                    ["unsupported_file_type", "invalid_file_type"].contains(diagnostic.code ?? "")) {
                    throw Unavailable.attachment
                }
                throw ChatClient.ClientError.service(diagnostic, ["附件上传失败。", detail].compactMap { $0 }.joined(separator: "\n"))
            }
            throw error
        }
        guard data.count <= 64 * 1024, let uploaded = try? JSONDecoder().decode(Uploaded.self, from: data),
              Self.validID(uploaded.id) else {
            throw ChatClient.ClientError.message("服务商未返回可用的文件 ID。")
        }
        return uploaded.id
    }

    func remove(_ ids: [String]) async -> Int {
        let session = ChatClient.session(proxy: proxy, resourceTimeout: 5)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var removed = 0
        for id in ids {
            guard ContinuousClock.now < deadline else { break }
            let request = request(method: "DELETE", url: endpoint.appending(component: id))
            do {
                try await validateCredential?()
                try Task.checkCancellation()
                try await validateRoute?()
            }
            catch { break }
            guard let (data, response) = try? await session.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { continue }
            if status == 404 || status == 204 ||
                (ChatClient.isSuccessful(response) && (try? JSONDecoder().decode(Deleted.self, from: data).deleted) == true) {
                removed += 1
            }
        }
        return ids.count - removed
    }

    private func request(method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.key.isEmpty {
            request.setValue("Bearer " + configuration.key, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func writeMultipart(_ file: RequestAttachment, boundary: String, to destination: URL) throws {
        let basename = file.name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? ""
        let cleaned = String(basename.prefix(256)).replacingOccurrences(of: "\"", with: "_")
            .components(separatedBy: .controlCharacters).joined()
        let name = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "attachment" : cleaned
        let imageTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]
        let purpose = imageTypes.contains(file.mediaType) ? "vision" : "user_data"
        guard !file.mediaType.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        let source = try FileHandle(forReadingFrom: file.url)
        defer { try? source.close(); try? output.close() }
        for (key, value) in [("purpose", purpose), ("expires_after[anchor]", "created_at"), ("expires_after[seconds]", "3600")] {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let headers = "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n" +
            "Content-Type: \(file.mediaType)\r\n\r\n"
        try output.write(contentsOf: Data(headers.utf8))
        var remaining = file.size
        while let data = try source.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            guard data.count <= remaining else { throw CocoaError(.fileReadCorruptFile) }
            try output.write(contentsOf: data)
            remaining -= data.count
        }
        guard remaining == 0 else { throw CocoaError(.fileReadCorruptFile) }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()
    }

    private static func validID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return (1...256).contains(id.utf8.count) && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    private struct Uploaded: Decodable {
        let id: String
    }

    private struct Deleted: Decodable {
        let deleted: Bool
    }
}
