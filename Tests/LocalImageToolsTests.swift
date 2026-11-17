import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

@MainActor
private final class ImageTransportFixture {
    var requests: [URLRequest] = []
    let respond: @MainActor (URLRequest, Int, @escaping LocalImageTools.ScopeCheck) async throws -> LocalImageTools.Response

    init(_ respond: @escaping @MainActor (URLRequest, Int, @escaping LocalImageTools.ScopeCheck) async throws -> LocalImageTools.Response) {
        self.respond = respond
    }

    var transport: LocalImageTools.Transport {
        { request, maximum, checkpoint in
            try await self.receive(request, maximum: maximum, checkpoint: checkpoint)
        }
    }

    private func receive(_ request: URLRequest, maximum: Int, checkpoint: @escaping LocalImageTools.ScopeCheck) async throws -> LocalImageTools.Response {
        precondition(request.httpMethod == "GET" && request.url?.scheme == "https")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        precondition(request.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Accept") == "image/*" && !request.httpShouldHandleCookies)
        precondition(request.url?.user == nil && request.url?.password == nil && request.timeoutInterval <= 8)
        requests.append(request)
        return try await respond(request, maximum, checkpoint)
    }
}

private final class ImageChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@main @MainActor
struct LocalImageToolsTests {
    private enum ScopeInvalid: Error { case changed }
    private static let webp = Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvAQAAAAdQ0IIUqP+BiOh/AAA=")!

    static func main() async throws {
        let png = try image(.png)
        let jpeg = try image(.jpeg)
        let gif = try image(.gif)
        try checkSession()
        try await checkFormatsAndOrder(png: png, jpeg: jpeg, gif: gif)
        try await checkArgumentAndSourceFailures(png: png)
        try await checkLimits(png: png)
        try await checkRedirects(png: png)
        try await checkCancellation(png: png)
        try await checkScopeInvalidation(png: png)
        print("Local send_images preserved validated PNG/JPEG/WebP/GIF order, byte limits, credential-free GET/redirect policy, safe diagnostics, cancellation and scope boundaries using synthetic transports only.")
    }

    private static func image(_ type: UTType) throws -> Data {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil),
              let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private static func arguments(_ images: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(["images": images]), as: UTF8.self)
    }

    private static func dataURL(_ data: Data, mime: String = "image/png") -> String {
        "data:\(mime);base64," + data.base64EncodedString()
    }

    private static func summary(_ result: LocalImageTools.Result) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(result.modelOutput.utf8)) as! [String: Any]
    }

    private static func checkSession() throws {
        let limits = LocalImageTools.Limits(imageBytes: .max, totalBytes: .max)
        precondition(limits.imageBytes == 25 * 1024 * 1024 && limits.totalBytes == 125 * 1024 * 1024)
        let session = LocalImageTools.imageSession(proxy: nil)
        defer { session.invalidateAndCancel() }
        let config = session.configuration
        precondition(!config.httpShouldSetCookies && config.httpCookieStorage == nil && config.urlCredentialStorage == nil)
        precondition(config.httpAdditionalHeaders == nil && config.urlCache == nil)
        let delegate = session.delegate as! URLSessionTaskDelegate
        let url = URL(string: "https://fixture.example/original")!
        let task = session.dataTask(with: url) // Never resumed: no network request.
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example/"])!
        var redirectWasRejected = false
        delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: URLRequest(url: URL(string: "https://other.example/")!)) { redirected in
            redirectWasRejected = redirected == nil
        }
        precondition(redirectWasRejected)
        let protection = URLProtectionSpace(host: "fixture.example", port: 443, protocol: "https", realm: "synthetic",
                                            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: protection,
                                                  proposedCredential: URLCredential(user: "synthetic-user", password: "synthetic-only", persistence: .forSession),
                                                  previousFailureCount: 0, failureResponse: nil, error: nil, sender: ImageChallengeSender())
        var credentialWasRejected = false
        delegate.urlSession?(session, task: task, didReceive: challenge) { disposition, credential in
            credentialWasRejected = disposition == .cancelAuthenticationChallenge && credential == nil
        }
        precondition(credentialWasRejected)
    }

    private static func checkFormatsAndOrder(png: Data, jpeg: Data, gif: Data) async throws {
        let fixture = ImageTransportFixture { _, _, checkpoint in
            try await checkpoint()
            return .init(status: 200, data: webp)
        }
        let result = try await LocalImageTools.perform(arguments: arguments([
            dataURL(png), dataURL(jpeg, mime: "image/png"), // Bytes override a mislabeled supported MIME.
            "https://fixture.example/misleading.gif?synthetic-access=do-not-echo",
            dataURL(gif, mime: "image/gif")
        ]), proxy: nil, validateScope: {}, transport: fixture.transport)
        precondition(result.generated.files.map(\.name) == ["sent-image-1.png", "sent-image-2.jpg", "sent-image-3.webp", "sent-image-4.gif"])
        precondition(result.generated.files.map(\.data) == [png, jpeg, webp, gif] && result.generated.unavailable == 0)
        let info = summary(result)
        precondition(info["sent"] as? Int == 4 && info["failed"] as? Int == 0 && !result.cancelled)
        precondition(!result.modelOutput.contains("do-not-echo") && !result.modelOutput.contains("fixture.example"))
        let unpadded = gif.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let forgivingBase64 = try await LocalImageTools.perform(arguments: arguments([
            "data:image/gif;base64," + unpadded,
            "data:image/png;base64, \n" + png.base64EncodedString() + "\r\n"
        ]), proxy: nil, validateScope: {}, transport: fixture.transport)
        precondition(forgivingBase64.generated.files.map(\.data) == [gif, png])
        let malformed = Data([137, 80, 78, 71, 13, 10, 26, 10] + Array(repeating: 0, count: 20))
        let bad = try await LocalImageTools.perform(arguments: arguments([dataURL(malformed), dataURL(Data("not an image".utf8))]),
                                                   proxy: nil, validateScope: {}, transport: fixture.transport)
        precondition(bad.generated.files.isEmpty && bad.generated.unavailable == 2)
        precondition((summary(bad))["failed"] as? Int == 2)
    }

    private static func checkArgumentAndSourceFailures(png: Data) async throws {
        let fixture = ImageTransportFixture { _, _, _ in preconditionFailure("Invalid input initiated a fetch.") }
        for args in ["{}", #"{"images":[]}"#, #"{"images":[1]}"#, #"{"images":[""]}"#,
                     try arguments(Array(repeating: dataURL(png), count: 6))] {
            let result = try await LocalImageTools.perform(arguments: args, proxy: nil, validateScope: {}, transport: fixture.transport)
            precondition(result.generated.files.isEmpty && (summary(result))["error"] as? String == "invalid_images_arguments")
        }
        let badSources = [
            "file:///private/tmp/synthetic-never-read.png", "/private/tmp/synthetic-never-read.png", "http://fixture.example/plain",
            "ftp://fixture.example/image", "https://synthetic-user:synthetic-password@fixture.example/image",
            "https://localhost/image", "https://local.LOCALHOST./image", "https://127.1/image",
            "https://0x7f000001/image", "https://10.0.0.1/image", "https://[::1]/image",
            "https://[fe80::1%25en0]/image",
            "https://[::ffff:127.0.0.1]/image", "data:image/svg+xml;base64,PHN2Zy8+", "data:image/png,not-base64"
        ]
        for source in badSources {
            let result = try await LocalImageTools.perform(arguments: arguments([source]), proxy: nil, validateScope: {}, transport: fixture.transport)
            precondition(result.generated.files.isEmpty && result.generated.unavailable == 1)
            precondition(!result.modelOutput.contains("synthetic-password") && !result.modelOutput.contains("private/tmp"))
        }
        precondition(fixture.requests.isEmpty)
    }

    private static func checkLimits(png: Data) async throws {
        let fixture = ImageTransportFixture { _, _, _ in .init(status: 200, data: png) }
        let rejected = try await LocalImageTools.perform(arguments: arguments(["https://fixture.example/oversized"]), proxy: nil,
                                                        validateScope: {}, transport: fixture.transport,
                                                        limits: .init(imageBytes: png.count - 1, totalBytes: png.count * 5))
        precondition(rejected.generated.files.isEmpty && rejected.modelOutput.contains("image_byte_limit"))
        let dataRejected = try await LocalImageTools.perform(arguments: arguments([dataURL(png)]), proxy: nil,
                                                            validateScope: {}, transport: fixture.transport,
                                                            limits: .init(imageBytes: png.count - 1, totalBytes: png.count * 5))
        precondition(dataRejected.generated.files.isEmpty)
        let noExtraFetch = ImageTransportFixture { _, _, _ in preconditionFailure("An exhausted total budget fetched another URL.") }
        let limited = try await LocalImageTools.perform(arguments: arguments([dataURL(png), "https://fixture.example/second"]), proxy: nil,
                                                        validateScope: {}, transport: noExtraFetch.transport,
                                                        limits: .init(imageBytes: png.count, totalBytes: png.count))
        precondition(limited.generated.files.count == 1 && limited.generated.unavailable == 1 && limited.modelOutput.contains("total_image_byte_limit"))
        let declared = ImageTransportFixture { _, maximum, _ in .init(status: 200, data: png, expectedLength: Int64(maximum + 1)) }
        let largeHeader = try await LocalImageTools.perform(arguments: arguments(["https://fixture.example/length"]), proxy: nil,
                                                            validateScope: {}, transport: declared.transport)
        precondition(largeHeader.generated.files.isEmpty)
    }

    private static func checkRedirects(png: Data) async throws {
        let fixture = ImageTransportFixture { request, _, _ in
            switch request.url!.path {
            case "/start": return .init(status: 301, location: "/second")
            case "/second": return .init(status: 307, location: "https://cdn.example/not-a-png.jpg")
            default: return .init(status: 200, data: png)
            }
        }
        let good = try await LocalImageTools.perform(arguments: arguments(["https://fixture.example/start"]), proxy: nil,
                                                    validateScope: {}, transport: fixture.transport)
        precondition(good.generated.files.first?.name == "sent-image-1.png" && fixture.requests.count == 3)
        for location in ["http://fixture.example/downgrade", "https://user:secret@fixture.example/", "file:///private/tmp/image", "https://127.0.0.1/image"] {
            let blocked = ImageTransportFixture { _, _, _ in .init(status: 302, location: location) }
            let result = try await LocalImageTools.perform(arguments: arguments(["https://fixture.example/start"]), proxy: nil,
                                                          validateScope: {}, transport: blocked.transport)
            precondition(result.generated.files.isEmpty && blocked.requests.count == 1 && !result.modelOutput.contains("secret"))
        }
        let loop = ImageTransportFixture { _, _, _ in .init(status: 302, location: "/loop") }
        let exceeded = try await LocalImageTools.perform(arguments: arguments(["https://fixture.example/loop"]), proxy: nil,
                                                         validateScope: {}, transport: loop.transport)
        precondition(loop.requests.count == 4 && exceeded.modelOutput.contains("image_redirect_limit"))
        let rawError = ImageTransportFixture { _, _, _ in
            throw NSError(domain: "synthetic-secret-url", code: 1, userInfo: [NSLocalizedDescriptionKey: "private/path?key=synthetic-secret"])
        }
        let failed = try await LocalImageTools.perform(arguments: arguments(["https://fixture.example/image"]), proxy: nil,
                                                      validateScope: {}, transport: rawError.transport)
        precondition(failed.modelOutput.contains("image_download_failed") && !failed.modelOutput.contains("synthetic-secret"))
    }

    private static func checkCancellation(png: Data) async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let fixture = ImageTransportFixture { _, _, _ in
            started.continuation.yield(())
            for await _ in release.stream { break }
            try Task.checkCancellation()
            return .init(status: 200, data: png)
        }
        let args = try arguments([dataURL(png), "https://fixture.example/current", "https://fixture.example/must-not-fetch"])
        let task = Task { try await LocalImageTools.perform(arguments: args, proxy: nil, validateScope: {}, transport: fixture.transport) }
        for await _ in started.stream.prefix(1) {}
        task.cancel()
        release.continuation.yield(())
        let result = try await task.value
        precondition(result.cancelled && result.generated.files.count == 1 && result.generated.unavailable == 2)
        precondition(fixture.requests.count == 1 && (summary(result))["cancelled_count"] as? Int == 2)
        let before = ImageTransportFixture { _, _, _ in preconditionFailure("An already cancelled tool initiated a fetch.") }
        let pending = Task { try await LocalImageTools.perform(arguments: args, proxy: nil, validateScope: {}, transport: before.transport) }
        pending.cancel()
        let cancelled = try await pending.value
        precondition(cancelled.cancelled && before.requests.isEmpty)
    }

    private static func checkScopeInvalidation(png: Data) async throws {
        for alsoCancel in [false, true] {
            var valid = true
            let started = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let fixture = ImageTransportFixture { _, _, checkpoint in
                started.continuation.yield(())
                for await _ in release.stream { break }
                if !alsoCancel { try await checkpoint() }
                try Task.checkCancellation()
                return .init(status: 200, data: png)
            }
            let args = try arguments([dataURL(png), "https://fixture.example/current", "https://fixture.example/must-not-fetch"])
            let task = Task { try await LocalImageTools.perform(arguments: args, proxy: nil, validateScope: {
                guard valid else { throw ScopeInvalid.changed }
            }, transport: fixture.transport) }
            for await _ in started.stream.prefix(1) {}
            valid = false
            if alsoCancel { task.cancel() }
            release.continuation.yield(())
            do { _ = try await task.value; preconditionFailure("A changed scope returned files for a new destination.") }
            catch ScopeInvalid.changed {}
            precondition(fixture.requests.count == 1)
        }
        var valid = true
        let redirect = ImageTransportFixture { _, _, _ in
            valid = false
            return .init(status: 302, location: "https://cdn.example/must-not-fetch")
        }
        do {
            _ = try await LocalImageTools.perform(arguments: arguments(["https://fixture.example/start"]), proxy: nil,
                                                  validateScope: { guard valid else { throw ScopeInvalid.changed } }, transport: redirect.transport)
            preconditionFailure("A changed scope followed a redirect.")
        } catch ScopeInvalid.changed {}
        precondition(redirect.requests.count == 1)
    }
}
