import Foundation

@MainActor
final class ChatGPTCatalogIntent {
    private var current = UUID()
    private var readingToken = false
    private var acceptedRevision: String?

    func begin() -> ProxyRouteCheck {
        let intent = UUID()
        current = intent
        readingToken = false
        acceptedRevision = nil
        return { [weak self] in
            try Task.checkCancellation()
            guard self?.current == intent else { throw CancellationError() }
        }
    }

    func beginTokenRead() { readingToken = true }

    func didReadToken(revision: String) {
        acceptedRevision = revision
        readingToken = false
    }

    func finish() { readingToken = false }

    func credentialsDidChange(_ revision: String) -> Bool {
        // Imported-token rotation publishes a vault revision. Reads already
        // validate their own short context; accept that rotation before loading
        // the catalog rather than cancelling the task that performed it.
        guard !readingToken, acceptedRevision != revision else { return false }
        invalidate()
        return true
    }

    func invalidate() {
        current = UUID()
        readingToken = false
        acceptedRevision = nil
    }
}

struct ChatGPTModelCatalog: Decodable {
    let models: [Model]
    struct Model: Decodable, Identifiable, Sendable {
        let slug: String
        let display_name: String
        let visibility: String?
        var id: String { slug }
    }
}

@MainActor
struct ChatGPTCatalogRequest {
    typealias ReadSelection = @MainActor (String?) async throws -> ChatGPTPlanSession.Selection?
    typealias Fetch = @MainActor (URLRequest, AsyncCredentialCheck?) async throws -> Data

    struct Result {
        let models: [ChatGPTModelCatalog.Model]
        let validatePublication: ProxyRouteCheck
    }

    private struct Stamp: Equatable {
        let activeRegistration: String?
        let credentials: String?
        let nativeRead: String?
        let prefersNative: Bool
    }

    let account: String
    let validateIntent: ProxyRouteCheck
    let validateRoute: ProxyRouteCheck
    var defaults: UserDefaults = .standard
    var read: ReadSelection = { try await ChatGPTPlanSession.selectionForRequest(clientID: $0) }

    static func account(
        _ requested: String? = nil, validateIntent: @escaping ProxyRouteCheck,
        read: ReadSelection = { try await ChatGPTPlanSession.selectionForRequest(clientID: $0) }
    ) async throws -> String {
        try validateIntent()
        let selection = try await read(requested)
        try Task.checkCancellation()
        try validateIntent()
        guard let id = selection?.credentials.clientID, !id.isEmpty,
              requested == nil || id == requested else {
            throw ChatClient.ClientError.message("请先通过 ChatGPT 登录，或导入此账户的授权凭证。")
        }
        try ChatGPTPlanSession.requireNotSigningOut(id)
        return id
    }

    func load(token: String, fetch: Fetch) async throws -> Result {
        let expected = stamp()
        let check: ProxyRouteCheck = {
            try validateIntent()
            try validateRoute()
            guard expected == stamp() else { throw CancellationError() }
        }
        try check()
        let original = try await read(nil)
        try check()
        guard original?.credentials.clientID == account else { throw CancellationError() }
        try await ChatGPTPlanSession.validateTokenForRequest(token, for: account, read: { _ in original })
        let validate: AsyncCredentialCheck = {
            try check()
            try await ChatGPTPlanSession.validateTokenForRequest(token, for: account, read: { _ in
                let current = try await read(nil)
                try check()
                guard current?.credentials.clientID == account else { throw CancellationError() }
                guard let original, current?.matches(original) == true else {
                    throw ChatClient.ClientError.message("ChatGPT 授权已更换，请重新刷新模型列表。")
                }
                return current
            })
            try check()
        }
        var request = URLRequest(url: ChatGPTPlanSession.endpoint.appending(path: "models"))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let data = try await fetch(request, validate)
        try await validate()
        let response = try JSONDecoder().decode(ChatGPTModelCatalog.self, from: data)
        var seen = Set<String>()
        let available = response.models.filter {
            $0.visibility == "list" && !$0.slug.isEmpty && seen.insert($0.slug).inserted
        }
        try check()
        return Result(models: available, validatePublication: check)
    }

    private func stamp() -> Stamp {
        Stamp(activeRegistration: defaults.string(forKey: ChatGPTPlanSession.selectionKey),
              credentials: defaults.string(forKey: APIKey.revisionKey),
              nativeRead: APIKey.nativeChatGPTReadRevision(clientID: account, defaults: defaults),
              prefersNative: ChatGPTPlanSession.prefersNativeSource(for: account, defaults: defaults))
    }
}
