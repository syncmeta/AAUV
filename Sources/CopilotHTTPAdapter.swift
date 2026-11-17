import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Local HTTP transport for the iOS direct preview; account admission is checked by GitHub.
// HTTP admission for AAUV's own OAuth App remains unverified by GitHub.
struct CopilotHTTPAdapter: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidCredential, forbiddenEndpoint, identityMismatch, malformedMetadata
        case unsupportedModel, unsupportedProtocol, modelRequired, policyDenied, expiredDiscovery, http(Int)
        case responseTooLarge, transport, invalidRequest, invalidStream
    }

    enum APIProtocol: String, Sendable { case responses, chatCompletions = "chat_completions" }

    struct Credential: Sendable, CustomStringConvertible {
        // Capture an already verified GitHub user OAuth record; never obtain a
        // token from system CLI state or silently switch to another account.
        fileprivate let token: String
        let accountID: String
        let login: String
        let clientID: String?
        let bindingID: UUID
        var description: String { "CopilotHTTP.Credential(redacted)" }

        init(token: String, accountID: String, login: String, clientID: String?, bindingID: UUID) throws {
            guard !token.isEmpty, token.utf8.count <= 4096,
                  token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
                  !accountID.isEmpty, accountID.utf8.allSatisfy({ (48...57).contains($0) }),
                  !login.isEmpty, login.utf8.count <= 256, !login.contains(where: \.isWhitespace),
                  clientID.map({ !$0.isEmpty && $0.utf8.count <= 256 && $0.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) }) ?? true else { throw Failure.invalidCredential }
            self.token = token; self.accountID = accountID; self.login = login
            self.clientID = clientID; self.bindingID = bindingID
        }
    }

    struct Guards: Sendable {
        // The host compares this exact credential/account/binding asynchronously.
        let validateCredential: @Sendable (Credential) async throws -> Void
        // The host includes current conversation intent, credential revision and
        // proxy/configuration epoch. Called atomically with dataTask.resume().
        let validateScope: @MainActor @Sendable () throws -> Void
    }

    struct Model: Decodable, Sendable {
        struct Capabilities: Decodable, Sendable {
            struct Supports: Decodable, Sendable {
                let streaming: Bool?
                let vision: Bool?
                let tool_calls: Bool?
            }
            let type: String?
            let supports: Supports?
        }
        struct Policy: Decodable, Sendable { let state: String? }
        let policy: Policy?
        let is_chat_default: Bool?
        let id: String
        let name: String?
        let vendor: String?
        let supported_endpoints: [String]?
        let capabilities: Capabilities?

        var policyAllows: Bool { policy?.state == nil || policy?.state == "" || policy?.state == "enabled" }

        func preferredProtocol() throws -> APIProtocol {
            guard policyAllows else { throw Failure.policyDenied }
            guard capabilities?.type == "chat" else { throw Failure.unsupportedModel }
            let endpoints = Set(supported_endpoints ?? [])
            if endpoints.contains("/responses"), capabilities?.supports?.streaming != false { return .responses }
            if endpoints.contains("/chat/completions") { return .chatCompletions }
            // No guessing when the provider omits capabilities; no Anthropic
            // route or protocol retry after an HTTP error is introduced here.
            throw Failure.unsupportedProtocol
        }
    }

    struct Prepared: Sendable {
        let baseURL: URL
        let model: Model
        let apiProtocol: APIProtocol
        fileprivate let credential: Credential
        fileprivate let expiresAt: ContinuousClock.Instant
        var requestURL: URL {
            baseURL.appending(path: apiProtocol == .responses ? "responses" : "chat/completions")
        }
    }

    struct Catalog: Sendable {
        let baseURL: URL
        let models: [Model]
        fileprivate let credential: Credential
        fileprivate let expiresAt: ContinuousClock.Instant

        func select(_ modelID: String) throws -> Prepared {
            let selected = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let model: Model
            if selected.isEmpty {
                let defaults = models.filter { $0.is_chat_default == true && (try? $0.preferredProtocol()) != nil }
                guard defaults.count == 1, let declared = defaults.first else { throw Failure.modelRequired }
                model = declared
            } else {
                guard let explicit = models.first(where: { $0.id == selected }) else { throw Failure.unsupportedModel }
                model = explicit
            }
            guard ContinuousClock.now < expiresAt else { throw Failure.expiredDiscovery }
            return try Prepared(baseURL: baseURL, model: model, apiProtocol: model.preferredProtocol(),
                                credential: credential, expiresAt: expiresAt)
        }
    }

    private struct User: Decodable {
        struct Endpoints: Decodable { let api: String? }
        let login: String?
        let endpoints: Endpoints?
    }
    private struct Models: Decodable { let data: [Model] }

    // Exact hosts are deliberately narrower than arbitrary *.githubcopilot.com.
    // Adding a new service region requires an explicit reviewed source change.
    static let apiHosts: Set<String> = ["api.githubcopilot.com", "api.individual.githubcopilot.com",
                                        "api.business.githubcopilot.com", "api.enterprise.githubcopilot.com"]
    static func validatedAPIEndpoint(_ text: String) throws -> URL {
        guard let c = URLComponents(string: text), c.scheme == "https",
              let host = c.host, host == host.lowercased(), apiHosts.contains(host),
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              c.query == nil, c.fragment == nil, c.percentEncodedPath == "" || c.percentEncodedPath == "/",
              let result = URL(string: "https://" + host) else { throw Failure.forbiddenEndpoint }
        return result
    }

    private let transport: any CopilotHTTPTransport
    init(transport: any CopilotHTTPTransport = CopilotHTTPURLSessionTransport()) { self.transport = transport }

    func discover(credential: Credential, guards: Guards) async throws -> Catalog {
        let data = try await metadata(URL(string: "https://api.github.com/copilot_internal/user")!,
                                      credential: credential, guards: guards, discovery: true)
        guard let user = try? JSONDecoder().decode(User.self, from: data), let endpoint = user.endpoints?.api else {
            throw Failure.malformedMetadata
        }
        if let login = user.login, login.caseInsensitiveCompare(credential.login) != .orderedSame {
            throw Failure.identityMismatch
        }
        // If login is absent, ownership rests on the host's verified credential
        // capture and exact-token guards; no inferred response identity is used.
        let base = try Self.validatedAPIEndpoint(endpoint)
        let modelData = try await metadata(base.appending(path: "models"), credential: credential, guards: guards, discovery: false)
        guard let models = try? JSONDecoder().decode(Models.self, from: modelData), models.data.count <= 4096,
              Set(models.data.map(\.id)).count == models.data.count,
              models.data.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && !$0.id.contains(where: \.isNewline) }) else {
            throw Failure.malformedMetadata
        }
        try await validate(credential, guards: guards)
        return Catalog(baseURL: base, models: models.data, credential: credential,
                       expiresAt: ContinuousClock.now.advanced(by: .seconds(30 * 60)))
    }

    func prepare(modelID: String, credential: Credential, guards: Guards) async throws -> Prepared {
        try await discover(credential: credential, guards: guards).select(modelID)
    }

    func send(_ prepared: Prepared, body: CopilotHTTPBody, guards: Guards,
              willSend: (@MainActor @Sendable () throws -> Void)? = nil,
              onChunk: @escaping @Sendable (Data) async throws -> Bool) async throws {
        guard ContinuousClock.now < prepared.expiresAt else { throw Failure.expiredDiscovery }
        _ = try Self.validatedAPIEndpoint(prepared.baseURL.absoluteString)
        var request = authenticatedRequest(prepared.requestURL, credential: prepared.credential)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(prepared.apiProtocol == .responses ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        request.setValue("conversation", forHTTPHeaderField: "OpenAI-Intent")
        try await validate(prepared.credential, guards: guards)
        try await transport.send(request, body: body, beforeSend: {
            try guards.validateScope()
            try willSend?()
            try guards.validateScope()
        }, onResponse: { try Self.checkResponse($0) },
                                 onChunk: { data in
            try Task.checkCancellation()
            try await guards.validateScope()
            return try await onChunk(data)
        })
        try await validate(prepared.credential, guards: guards)
    }

    private func metadata(_ url: URL, credential: Credential, guards: Guards, discovery: Bool) async throws -> Data {
        var request = authenticatedRequest(url, credential: credential)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if discovery { request.setValue("2025-04-01", forHTTPHeaderField: "X-GitHub-Api-Version") }
        let collector = CopilotHTTPDataCollector(limit: 2 * 1024 * 1024)
        try await validate(credential, guards: guards)
        try await transport.send(request, body: .none, beforeSend: guards.validateScope,
                                 onResponse: { try Self.checkResponse($0) }, onChunk: { try await collector.append($0); return true })
        try await validate(credential, guards: guards)
        return await collector.data
    }

    private func authenticatedRequest(_ url: URL, credential: Credential) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("AAUV/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(_ credential: Credential, guards: Guards) async throws {
        try Task.checkCancellation()
        try await guards.validateCredential(credential)
        try Task.checkCancellation()
        try await guards.validateScope()
    }

    private static func checkResponse(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
    }
}

enum CopilotHTTPBody: Sendable { case none, data(Data), file(URL, bytes: Int) }

protocol CopilotHTTPTransport: Sendable {
    func send(_ request: URLRequest, body: CopilotHTTPBody,
              beforeSend: @escaping @MainActor @Sendable () throws -> Void,
              onResponse: @escaping @Sendable (HTTPURLResponse) async throws -> Void,
              onChunk: @escaping @Sendable (Data) async throws -> Bool) async throws
}

private actor CopilotHTTPDataCollector {
    var data = Data()
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else { throw CopilotHTTPAdapter.Failure.responseTooLarge }
        data.append(chunk)
    }
}

// Foundation-only transport; no CLI, native Copilot runtime or account storage.
final class CopilotHTTPURLSessionTransport: CopilotHTTPTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.httpShouldSetCookies = false
        self.configuration.httpCookieStorage = nil
        self.configuration.urlCredentialStorage = nil
        self.configuration.urlCache = nil
        self.configuration.timeoutIntervalForRequest = 60
        self.configuration.timeoutIntervalForResource = 900
    }

    func send(_ original: URLRequest, body: CopilotHTTPBody,
              beforeSend: @escaping @MainActor @Sendable () throws -> Void,
              onResponse: @escaping @Sendable (HTTPURLResponse) async throws -> Void,
              onChunk: @escaping @Sendable (Data) async throws -> Bool) async throws {
        var request = original
        var bodyURL: URL?
        switch body {
        case .none: break
        case .data(let data): request.httpBody = data
        case .file(let url, let size):
            guard url.isFileURL, size >= 0, let stream = InputStream(url: url) else { throw CopilotHTTPAdapter.Failure.invalidRequest }
            bodyURL = url
            request.httpBodyStream = stream
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        }
        let channel = Channel(bodyURL: bodyURL)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: channel, delegateQueue: queue)
        let task = session.dataTask(with: request)
        channel.attach(task)
        defer { channel.stop(nil); session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await MainActor.run {
                try Task.checkCancellation()
                try beforeSend()
                task.resume()
            }
            for try await event in channel.events {
                try Task.checkCancellation()
                switch event {
                case .response(let response): try await onResponse(response)
                case .data(let data):
                    defer { channel.consumed(data.count) }
                    if try await !onChunk(data) { return }
                }
            }
        } onCancel: {
            channel.stop(CancellationError())
            task.cancel()
        }
    }

    private final class Channel: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        enum Event: Sendable { case response(HTTPURLResponse), data(Data) }
        let events: AsyncThrowingStream<Event, Error>
        private let continuation: AsyncThrowingStream<Event, Error>.Continuation
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var pending = 0
        private var ended = false
        private let bodyURL: URL?

        init(bodyURL: URL?) {
            var output: AsyncThrowingStream<Event, Error>.Continuation!
            events = AsyncThrowingStream { output = $0 }
            continuation = output
            self.bodyURL = bodyURL
        }
        func attach(_ task: URLSessionDataTask) { lock.lock(); self.task = task; lock.unlock() }
        func consumed(_ count: Int) { lock.lock(); pending -= count; lock.unlock() }
        func stop(_ error: Error?) {
            lock.lock()
            let wasEnded = ended
            ended = true
            let task = self.task
            lock.unlock()
            guard !wasEnded else { return }
            task?.cancel()
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse else {
                completionHandler(.cancel); stop(CopilotHTTPAdapter.Failure.transport); return
            }
            continuation.yield(.response(response))
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            guard data.count <= 4 * 1024 * 1024 - pending else {
                lock.unlock(); stop(CopilotHTTPAdapter.Failure.responseTooLarge); return
            }
            pending += data.count
            lock.unlock()
            continuation.yield(.data(data))
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil { stop(CopilotHTTPAdapter.Failure.transport) } else { stop(nil) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
            completionHandler(bodyURL.flatMap { InputStream(url: $0) })
        }
    }
}


extension CopilotHTTPAdapter.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Copilot 直连预览需要有效的 GitHub 用户 OAuth 凭证。"
        case .forbiddenEndpoint: return "GitHub 返回的 Copilot 地址不在允许的官方 HTTPS 地址范围内。"
        case .identityMismatch: return "Copilot 访问检查返回了不同账户，请重新登录。"
        case .malformedMetadata: return "GitHub 返回的 Copilot 账户或模型目录无效。"
        case .unsupportedModel: return "所选模型不在此账户的 Copilot 目录中。请重新选择模型。"
        case .unsupportedProtocol: return "此 Copilot 模型不支持当前请求所需的接口或工具。"
        case .modelRequired: return "请明确选择 Copilot 模型；GitHub 未返回唯一可用的服务默认模型。"
        case .policyDenied: return "所选 Copilot 模型受到 GitHub 账户策略限制。"
        case .expiredDiscovery: return "Copilot 模型目录已过期，请重新检查访问权限后重试。"
        case .http(let status): return "Copilot 直连预览返回 HTTP \(status)。请核对账户、订阅及模型权限。"
        case .responseTooLarge: return "Copilot 响应超出本机处理上限。"
        case .transport: return "Copilot 连接失败，请检查网络后重试。"
        case .invalidRequest: return "当前 Copilot 请求或附件格式无法通过本机校验。"
        case .invalidStream: return "Copilot 未返回完整成功回复。"
        }
    }
}
