import Foundation
import Network

struct GitHubDeviceAuthorization {
    private static let deviceEndpoint = URL(string: "https://github.com/login/device/code")!
    private static let tokenEndpoint = URL(string: "https://github.com/login/oauth/access_token")!
    private static let identityEndpoint = URL(string: "https://api.github.com/user")!
    static let verificationURL = URL(string: "https://github.com/login/device")!

    struct Grant {
        let userCode: String
        fileprivate let clientID: String
        fileprivate let deviceCode: String
        fileprivate let interval: Int
        fileprivate let expiresAt: ContinuousClock.Instant
    }

    struct Account: Decodable {
        let id: UInt64
        let login: String
    }

    private let send: (URLRequest) async throws -> Data

    init(proxy: ProxyConfiguration?, validateRoute: ProxyRouteCheck? = nil) {
        send = { request in
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.timeoutIntervalForResource = 25
            if let proxy { config.proxyConfigurations = [proxy] }
            let session = URLSession(configuration: config, delegate: ChatClient.NoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            try await validateRoute?()
            let (data, response) = try await session.data(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode, data.count <= 64 * 1024 else {
                throw ChatClient.ClientError.message("GitHub 授权响应无效。")
            }
            if code == 200 { return data }
            if request.url?.host == "github.com", [400, 401, 403, 422].contains(code),
               let error = try? JSONDecoder().decode(TokenResponse.self, from: data).error, !error.isEmpty {
                return data
            }
            throw ChatClient.ClientError.message("GitHub 授权服务返回 HTTP \(code)。")
        }
    }

    init(send: @escaping (URLRequest) async throws -> Data) {
        self.send = send
    }

    func begin(clientID: String) async throws -> Grant {
        guard Self.isIdentifier(clientID, maxBytes: 128) else {
            throw ChatClient.ClientError.message("请输入有效的 GitHub OAuth Client ID。")
        }
        let data = try await send(Self.formRequest(Self.deviceEndpoint, fields: ["client_id": clientID]))
        if let error = try? JSONDecoder().decode(TokenResponse.self, from: data).error {
            throw Self.authorizationError(error)
        }
        let response = try JSONDecoder().decode(DeviceResponse.self, from: data)
        guard Self.isIdentifier(response.device_code, maxBytes: 512),
              Self.isIdentifier(response.user_code, maxBytes: 32),
              response.verification_uri == Self.verificationURL,
              (1...3600).contains(response.expires_in),
              (1...response.expires_in).contains(response.interval) else {
            throw ChatClient.ClientError.message("GitHub 返回的设备授权信息无效。")
        }
        return Grant(userCode: response.user_code, clientID: clientID, deviceCode: response.device_code,
                     interval: response.interval, expiresAt: .now.advanced(by: .seconds(response.expires_in)))
    }

    func finish(
        _ grant: Grant,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> OAuthCredentials {
        let request = Self.formRequest(Self.tokenEndpoint, fields: [
            "client_id": grant.clientID,
            "device_code": grant.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
        var interval = grant.interval
        while ContinuousClock.now < grant.expiresAt {
            let now = ContinuousClock.now
            let next = now.advanced(by: .seconds(interval))
            try await sleep(now.duration(to: min(next, grant.expiresAt)))
            try Task.checkCancellation()
            guard ContinuousClock.now < grant.expiresAt else { break }
            let data = try await send(request)
            let token = try JSONDecoder().decode(TokenResponse.self, from: data)
            switch token.error {
            case "authorization_pending": continue
            case "slow_down":
                interval = max(interval + 5, min(token.interval ?? 0, 3600))
            case let error?:
                throw Self.authorizationError(error)
            case nil:
                return try token.credentials(clientID: grant.clientID)
            }
        }
        throw Self.authorizationError("expired_token")
    }

    func verify(_ credentials: OAuthCredentials) async throws -> Account {
        try credentials.validateStructure()
        guard credentials.flow == .githubCopilot,
              Self.isIdentifier(credentials.accessToken, maxBytes: 512) else {
            throw ChatClient.ClientError.message("GitHub OAuth 凭证无效。")
        }
        var request = URLRequest(url: Self.identityEndpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AAUV", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        let account = try JSONDecoder().decode(Account.self, from: await send(request))
        guard account.id > 0, !account.login.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return account
    }

    func refresh(_ previous: OAuthCredentials) async throws -> OAuthCredentials {
        guard let id = previous.clientID, let refreshToken = previous.refreshToken,
              Self.isIdentifier(id, maxBytes: 128), Self.isIdentifier(refreshToken, maxBytes: 512) else {
            throw ChatClient.ClientError.message("GitHub 授权已过期，请重新登录。")
        }
        let data = try await send(Self.formRequest(Self.tokenEndpoint, fields: [
            "client_id": id, "refresh_token": refreshToken, "grant_type": "refresh_token"
        ]))
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard response.error == nil, response.refresh_token != nil, response.expires_in != nil else {
            throw ChatClient.ClientError.message("无法续期 GitHub 授权，请重新登录。")
        }
        var credentials = try response.credentials(clientID: id)
        credentials.verifiedSubject = previous.verifiedSubject
        credentials.verifiedLogin = previous.verifiedLogin
        return credentials
    }

    private static func formRequest(_ endpoint: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("AAUV", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(ChatGPTPlanSession.formBody(fields).utf8)
        return request
    }

    private static func isIdentifier(_ value: String, maxBytes: Int) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !value.isEmpty && value.utf8.count <= maxBytes && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func authorizationError(_ code: String) -> ChatClient.ClientError {
        switch code {
        case "access_denied": return .message("GitHub 授权已被取消。")
        case "expired_token", "token_expired", "incorrect_device_code":
            return .message("GitHub 设备码已失效，请重新开始授权。")
        case "device_flow_disabled", "incorrect_client_credentials":
            return .message("请确认 GitHub Client ID 正确，且已启用设备授权。")
        default: return .message("GitHub 未能完成授权。")
        }
    }

    private struct DeviceResponse: Decodable {
        let user_code: String
        let device_code: String
        let verification_uri: URL
        let interval: Int
        let expires_in: Int
    }

    private struct TokenResponse: Decodable {
        let error: String?
        let interval: Int?
        let access_token: String?
        let token_type: String?
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?

        func credentials(clientID: String) throws -> OAuthCredentials {
            guard let access_token, access_token.hasPrefix("gho_") || access_token.hasPrefix("ghu_"),
                  GitHubDeviceAuthorization.isIdentifier(access_token, maxBytes: 512),
                  token_type?.lowercased() == "bearer",
                  expires_in.map({ $0.isFinite && $0 > 0 }) ?? true,
                  refresh_token.map({ GitHubDeviceAuthorization.isIdentifier($0, maxBytes: 512) }) ?? true else {
                throw ChatClient.ClientError.message("GitHub 返回的 OAuth 凭证无效。")
            }
            return OAuthCredentials(flow: .githubCopilot, accessToken: access_token, refreshToken: refresh_token,
                                    clientID: clientID, expiresAt: expires_in.map { Date().timeIntervalSince1970 + $0 },
                                    scopes: scope?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }
}
