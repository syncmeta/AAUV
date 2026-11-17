import Foundation
import Network

@MainActor
enum ModelServiceFetcher {
    typealias Transport = @MainActor (URLRequest, ProxyConfiguration?, ProxyRouteCheck, AsyncCredentialCheck?) async throws -> Data

    static func refresh(_ original: ModelService, proxy: SingBox, defaults: UserDefaults = .standard,
                        validateIntent: @escaping ProxyRouteCheck = {},
                        readKey: @escaping @Sendable (URL) throws -> String = { try APIKey.read(for: $0) },
                        transport: Transport = send) async throws -> ModelService {
        let service = try original.validated()
        let ticket = try ModelServices.capture(service, defaults: defaults)
        let route = try proxy.requestRoute()
        let check: ProxyRouteCheck = {
            try Task.checkCancellation()
            try validateIntent()
            try route.validate()
            try ticket.validate()
        }
        try check()
        let fetched: [ServiceModel]
        switch service.loginMethod {
        case .byok:
            let endpoint = try ChatClient.baseURL(service.endpoint)
            let credentials = try await RequestCredentials.read(for: endpoint, validateRoute: check,
                                                                defaults: defaults, read: readKey)
            guard credentials.key.utf8.count <= 65_536, !credentials.key.contains(where: \.isNewline) else {
                throw ChatClient.ClientError.message(String(localized: "API Key 格式无效。"))
            }
            var request = URLRequest(url: endpoint.appending(path: "models"))
            request.httpMethod = "GET"
            if !credentials.key.isEmpty { request.setValue("Bearer " + credentials.key, forHTTPHeaderField: "Authorization") }
            let data = try await transport(request, route.configuration, check, { try credentials.validate() })
            try credentials.validate()
            fetched = try decodeBYOK(data)
        case .chatgpt:
            guard let client = service.chatGPTClientID else { throw CancellationError() }
            let read: ChatGPTCatalogRequest.ReadSelection = { requested in
                try await ChatGPTPlanSession.selectionForRequest(clientID: requested ?? client, defaults: defaults)
            }
            let account = try await ChatGPTCatalogRequest.account(client, validateIntent: check, read: read)
            let token = try await ChatGPTPlanSession.token(proxy: route.configuration, clientID: account, validateRoute: check)
            let request = ChatGPTCatalogRequest(account: account, validateIntent: check,
                                               validateRoute: route.validate, defaults: defaults, read: read)
            let result = try await request.load(token: token) { request, credentialCheck in
                try await transport(request, route.configuration, check, credentialCheck)
            }
            try result.validatePublication()
            fetched = result.models.map { ServiceModel(id: $0.slug, name: $0.display_name) }
        case .copilot:
            let session = CopilotSession(defaults: defaults)
            let models = try await session.models(proxy: proxy)
            try session.validate()
            fetched = models.filter(\.allowed).map { ServiceModel(id: $0.id, name: $0.name) }
        }
        try check()
        var result = service
        result.models = try ModelService.validatedModels(service.models + fetched)
        try ModelServices.upsert(result, replacing: service.id, defaults: defaults)
        return result
    }

    static func decodeBYOK(_ data: Data) throws -> [ServiceModel] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String; let name: String? }
            let data: [Model]
        }
        guard data.count <= 4 * 1024 * 1024 else { throw invalidResponse() }
        do {
            return try ModelService.validatedModels(JSONDecoder().decode(Response.self, from: data).data.map {
                ServiceModel(id: $0.id, name: $0.name)
            })
        } catch { throw invalidResponse() }
    }

    private static func send(_ request: URLRequest, _ proxy: ProxyConfiguration?,
                             _ validateRoute: ProxyRouteCheck, _ validateCredential: AsyncCredentialCheck?) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        if let proxy { configuration.proxyConfigurations = [proxy] }
        let session = URLSession(configuration: configuration, delegate: ChatClient.NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        try await validateCredential?()
        try Task.checkCancellation()
        try validateRoute()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validateRoute()
        try await validateCredential?()
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw ChatClient.ClientError.message(String(localized: "无法读取模型目录，原模型列表已保留。"))
        }
        guard data.count <= 4 * 1024 * 1024 else { throw invalidResponse() }
        return data
    }

    static func safeMessage(_ error: Error) -> String {
        if let error = error as? ChatClient.ClientError { return error.localizedDescription }
        if let error = error as? APIKey.KeychainError { return error.localizedDescription }
        return String(localized: "无法读取模型目录，原模型列表已保留。")
    }

    private static func invalidResponse() -> ChatClient.ClientError {
        .message(String(localized: "模型目录格式无效，原模型列表已保留。"))
    }
}
