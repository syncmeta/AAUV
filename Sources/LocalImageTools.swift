import Foundation
import Network
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum LocalImageTools {
    typealias ScopeCheck = @MainActor @Sendable () async throws -> Void
    typealias Transport = @Sendable (URLRequest, Int, @escaping ScopeCheck) async throws -> Response

    struct Response: Sendable {
        let status: Int
        var data = Data()
        var location: String?
        var expectedLength: Int64 = -1
    }

    struct Limits: Sendable {
        static let standard = Limits()
        let imageBytes: Int
        let totalBytes: Int
        let imageCount: Int

        init(imageBytes: Int = 25 * 1024 * 1024, totalBytes: Int = 125 * 1024 * 1024, imageCount: Int = 5) {
            self.imageBytes = max(0, min(imageBytes, 25 * 1024 * 1024))
            self.totalBytes = max(0, min(totalBytes, 125 * 1024 * 1024))
            self.imageCount = max(0, min(imageCount, 5))
        }
    }

    struct Result: Sendable {
        let modelOutput: String
        let generated: ChatClient.GeneratedFiles
        let cancelled: Bool
    }

    private struct Issue: Encodable, Sendable {
        let index: Int
        let code: String
    }

    private struct ScopeFailure: Error { let underlying: Error }
    private enum Failure: String, Error {
        case invalidSource = "invalid_image_source"
        case blockedHost = "blocked_image_host"
        case invalidDataURL = "invalid_image_data_url"
        case unsupportedType = "unsupported_image_type"
        case invalidImage = "invalid_image_bytes"
        case imageLimit = "image_byte_limit"
        case totalLimit = "total_image_byte_limit"
        case redirectLimit = "image_redirect_limit"
        case httpFailure = "image_http_failure"
        case downloadFailure = "image_download_failed"
    }

    private enum ArgumentsFailure: Error { case invalid }
    private struct DecodedImage: Sendable { let data: Data; let suffix: String }

    // This helper owns no conversation or file-system state. The host must
    // validate the same scope again when it commits returned in-memory files.
    // A scope-check error always escapes; cancellation can return completed
    // images only if the final scope check still permits that original scope.
    @MainActor static func perform(
        arguments: String, proxy: ProxyConfiguration?,
        validateScope: @escaping ScopeCheck,
        transport: Transport? = nil,
        limits: Limits = .standard
    ) async throws -> Result {
        try await validateScope()
        let entries: [String]
        do {
            entries = try await process {
                guard arguments.utf8.count <= limits.totalBytes * 2 + 32 * 1024 else { throw ArgumentsFailure.invalid }
                struct Arguments: Decodable { let images: [String] }
                let values = try JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8)).images
                guard !values.isEmpty, values.count <= limits.imageCount else { throw ArgumentsFailure.invalid }
                let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard trimmed.allSatisfy({ !$0.isEmpty }) else { throw ArgumentsFailure.invalid }
                return trimmed
            }
        } catch {
            try await validateScope()
            return result(requested: 0, files: [], issues: [], cancelledCount: 0,
                          cancelled: Task.isCancelled || error is CancellationError,
                          error: Task.isCancelled || error is CancellationError ? "cancelled" : "invalid_images_arguments")
        }
        let checkpoint: ScopeCheck = {
            do { try await validateScope() }
            catch { throw ScopeFailure(underlying: error) }
            try Task.checkCancellation()
        }
        let network = transport == nil ? NetworkFetcher(proxy: proxy) : nil
        defer { network?.session.invalidateAndCancel() }
        let fetch: Transport = transport ?? { request, maximum, scope in
            try await network!.fetch(request, maximum: maximum, checkpoint: scope)
        }
        var files: [ChatClient.GeneratedFiles.File] = []
        var issues: [Issue] = []
        var remaining = limits.totalBytes
        var cancelledCount = 0
        var cancelled = false
        for (index, entry) in entries.enumerated() {
            do {
                try await checkpoint()
                guard remaining > 0 else { throw Failure.totalLimit }
                let maximum = min(limits.imageBytes, remaining)
                guard maximum > 0 else { throw Failure.imageLimit }
                let image: DecodedImage
                if entry.prefix(5).lowercased() == "data:" {
                    image = try await process { try decodeDataURL(entry, maximum: maximum) }
                } else {
                    let data = try await download(entry, maximum: maximum, transport: fetch, checkpoint: checkpoint)
                    image = try await process { try validateImage(data) }
                }
                try await checkpoint()
                guard image.data.count <= maximum else { throw Failure.imageLimit }
                remaining -= image.data.count
                files.append(.init(name: "sent-image-\(index + 1).\(image.suffix)", data: image.data))
            } catch let failure as ScopeFailure {
                throw failure.underlying
            } catch {
                if Task.isCancelled || error is CancellationError {
                    cancelled = true
                    cancelledCount = entries.count - index
                    break
                }
                let code = (error as? Failure)?.rawValue ?? Failure.downloadFailure.rawValue
                issues.append(.init(index: index + 1, code: code))
            }
        }
        // Deliberately do not suppress a scope failure even when user cancellation
        // also happened. A validator that checks Task cancellation may choose to
        // discard the partial result; a pure scope validator can retain it.
        try await validateScope()
        cancelled = cancelled || Task.isCancelled
        return result(requested: entries.count, files: files, issues: issues,
                      cancelledCount: cancelledCount, cancelled: cancelled)
    }

    private static func result(requested: Int, files: [ChatClient.GeneratedFiles.File], issues: [Issue],
                               cancelledCount: Int, cancelled: Bool, error: String? = nil) -> Result {
        struct Summary: Encodable {
            let ok: Bool
            let requested: Int
            let sent: Int
            let failed: Int
            let cancelled_count: Int
            let cancelled: Bool
            let errors: [Issue]
            let error: String?
        }
        let summary = Summary(ok: !files.isEmpty, requested: requested, sent: files.count, failed: issues.count,
                              cancelled_count: cancelledCount, cancelled: cancelled, errors: issues, error: error)
        let output = (try? JSONEncoder().encode(summary)) ?? Data(#"{"ok":false,"error":"image_result_failed"}"#.utf8)
        return Result(modelOutput: String(decoding: output, as: UTF8.self),
                      generated: .init(files: files, unavailable: max(0, requested - files.count)), cancelled: cancelled)
    }

    private static func process<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func decodeDataURL(_ value: String, maximum: Int) throws -> DecodedImage {
        guard let comma = value.firstIndex(of: ",") else { throw Failure.invalidDataURL }
        let header = value[value.index(value.startIndex, offsetBy: 5)..<comma].lowercased().split(separator: ";", omittingEmptySubsequences: false)
        guard let mime = header.first,
              ["image/png", "image/jpeg", "image/jpg", "image/webp", "image/gif"].contains(String(mime)),
              header.dropFirst().contains("base64") else { throw Failure.invalidDataURL }
        let maximumEncoded = ((maximum + 2) / 3) * 4
        var encoded: [UInt8] = []
        var scanned = 0
        for byte in value[value.index(after: comma)...].utf8 {
            scanned += 1
            if scanned % (64 * 1024) == 0 { try Task.checkCancellation() }
            if [9, 10, 12, 13, 32].contains(byte) { continue }
            guard (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [43, 47, 61].contains(byte) else {
                throw Failure.invalidDataURL
            }
            guard encoded.count < maximumEncoded else { throw Failure.imageLimit }
            encoded.append(byte)
        }
        guard encoded.count % 4 != 1 else { throw Failure.invalidDataURL }
        while encoded.count % 4 != 0 { encoded.append(61) }
        guard encoded.count <= maximumEncoded,
              let data = Data(base64Encoded: Data(encoded)) else { throw Failure.invalidDataURL }
        guard data.count <= maximum else { throw Failure.imageLimit }
        return try validateImage(data)
    }

    private static func validateImage(_ data: Data) throws -> DecodedImage {
        try Task.checkCancellation()
        let header = Array(data.prefix(12))
        let suffix: String
        let identifier: String
        if header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            suffix = "png"; identifier = UTType.png.identifier
        } else if header.starts(with: [255, 216, 255]) {
            suffix = "jpg"; identifier = UTType.jpeg.identifier
        } else if header.starts(with: Array("GIF87a".utf8)) || header.starts(with: Array("GIF89a".utf8)) {
            suffix = "gif"; identifier = UTType.gif.identifier
        } else if header.count == 12, header.starts(with: Array("RIFF".utf8)), header.suffix(4).elementsEqual("WEBP".utf8) {
            suffix = "webp"; identifier = UTType.webP.identifier
        } else {
            throw Failure.unsupportedType
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == identifier,
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width > 0, image.height > 0 else { throw Failure.invalidImage }
        try Task.checkCancellation()
        return DecodedImage(data: data, suffix: suffix)
    }

    private static func download(_ source: String, maximum: Int, transport: Transport,
                                 checkpoint: @escaping ScopeCheck) async throws -> Data {
        var current = try imageURL(source)
        var redirects = 0
        while true {
            try await checkpoint()
            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let response = try await transport(request, maximum, checkpoint)
            try await checkpoint()
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard redirects < 3 else { throw Failure.redirectLimit }
                guard let location = response.location, let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw Failure.invalidSource
                }
                current = try imageURL(next.absoluteString)
                redirects += 1
                continue
            }
            guard (200..<300).contains(response.status) else { throw Failure.httpFailure }
            guard response.expectedLength <= Int64(maximum), response.data.count <= maximum else { throw Failure.imageLimit }
            return response.data
        }
    }

    private static func imageURL(_ text: String) throws -> URL {
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, let host = components.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("@"), !host.contains("/"), !host.contains("\\"),
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { throw Failure.invalidSource }
        guard !blockedHost(host) else { throw Failure.blockedHost }
        return url
    }

    private static func blockedHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "metadata.google.internal" { return true }
        func blockedV4(_ bytes: [UInt8]) -> Bool {
            bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224 ||
            (bytes[0] == 169 && bytes[1] == 254) || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168)
        }
        var v4 = in_addr()
        if inet_aton(host, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { blockedV4(Array($0)) }
        }
        var v6 = in6_addr()
        let address = host.contains(":") ? String(host.prefix { $0 != "%" }) : host
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) || (bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1) ||
                bytes[0] == 255 || bytes[0] & 254 == 252 || (bytes[0] == 254 && bytes[1] & 192 == 128) { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return blockedV4(Array(bytes.suffix(4)))
            }
        }
        return false
    }

    // Take the same ephemeral/proxy/timeouts baseline as ChatClient, then remove
    // ambient cookies, credentials and headers explicitly. The new delegate never
    // follows redirects and refuses HTTP/proxy credential challenges.
    static func imageSession(proxy: ProxyConfiguration?) -> URLSession {
        let baseline = ChatClient.session(proxy: proxy, resourceTimeout: 8, requestTimeout: 8)
        let configuration = baseline.configuration
        baseline.invalidateAndCancel()
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: ImageSessionDelegate(), delegateQueue: nil)
    }

    private final class ImageSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }

    private final class NetworkFetcher: @unchecked Sendable {
        let session: URLSession
        init(proxy: ProxyConfiguration?) { session = imageSession(proxy: proxy) }

        func fetch(_ request: URLRequest, maximum: Int, checkpoint: @escaping ScopeCheck) async throws -> Response {
            try await checkpoint()
            guard maximum > 0 else { throw Failure.imageLimit }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw Failure.httpFailure }
            try await checkpoint()
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                return Response(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"))
            }
            guard (200..<300).contains(http.statusCode) else { throw Failure.httpFailure }
            guard response.expectedContentLength <= Int64(maximum) else { throw Failure.imageLimit }
            return try await withTaskCancellationHandler {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maximum else { throw Failure.imageLimit }
                    data.append(byte)
                    if data.count % (64 * 1024) == 0 { try await checkpoint() }
                }
                try await checkpoint()
                return Response(status: http.statusCode, data: data, expectedLength: response.expectedContentLength)
            } onCancel: {
                bytes.task.cancel()
            }
        }
    }
}
