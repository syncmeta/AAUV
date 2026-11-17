import Foundation

struct RequestCredentials {
    let key: String
    let validate: ProxyRouteCheck

    @MainActor static func read(
        for endpoint: URL, validateRoute: @escaping ProxyRouteCheck,
        defaults: UserDefaults = .standard,
        read: @escaping @Sendable (URL) throws -> String = { try APIKey.read(for: $0) }
    ) async throws -> Self {
        let revision = defaults.string(forKey: APIKey.byokRevisionKey)
        let configurationRevision = defaults.string(forKey: ProxyNodes.revisionKey)
        let validate: ProxyRouteCheck = {
            try Task.checkCancellation()
            try validateRoute()
            guard revision == defaults.string(forKey: APIKey.byokRevisionKey),
                  configurationRevision == defaults.string(forKey: ProxyNodes.revisionKey) else {
                throw ChatClient.ClientError.message("API 凭证已改变，请重新请求。")
            }
        }
        try validate()
        let key = try await APIKey.readInBackground { try read(endpoint) }
        try validate()
        return Self(key: key, validate: validate)
    }
}
