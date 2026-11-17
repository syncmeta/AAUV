import Foundation

@main
struct GitHubDeviceAuthorizationTests {
    @MainActor
    static func main() async throws {
        let grantJSON = #"{"device_code":"testDevice","user_code":"AAAA-BBBB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        var pollCount = 0
        var refreshCount = 0
        var waits: [Duration] = []
        let service = GitHubDeviceAuthorization(send: { request in
            let fields = URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems
            switch request.url?.absoluteString {
            case "https://github.com/login/device/code":
                precondition(request.httpMethod == "POST" && fields == [.init(name: "client_id", value: "Iv1.testClient")])
                return Data(grantJSON.utf8)
            case "https://github.com/login/oauth/access_token":
                precondition(request.httpMethod == "POST")
                let form = Dictionary(uniqueKeysWithValues: (fields ?? []).map { ($0.name, $0.value) })
                if form["grant_type"] == "refresh_token" {
                    precondition(form == ["client_id": "Iv1.testClient", "refresh_token": "ghr_fake", "grant_type": "refresh_token"])
                    refreshCount += 1
                    return Data(#"{"access_token":"gho_new","refresh_token":"ghr_new","token_type":"bearer","expires_in":3600}"#.utf8)
                }
                precondition(form == [
                    "client_id": "Iv1.testClient", "device_code": "testDevice",
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ])
                pollCount += 1
                switch pollCount {
                case 1: return Data(#"{"error":"authorization_pending"}"#.utf8)
                case 2: return Data(#"{"error":"slow_down","interval":12}"#.utf8)
                default: return Data(#"{"access_token":"gho_fake","refresh_token":"ghr_fake","token_type":"bearer","expires_in":3600}"#.utf8)
                }
            case "https://api.github.com/user":
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer gho_fake")
                return Data(#"{"id":42,"login":"example"}"#.utf8)
            default: fatalError("Unexpected destination")
            }
        })
        let grant = try await service.begin(clientID: "Iv1.testClient")
        precondition(grant.userCode == "AAAA-BBBB")
        let token = try await service.finish(grant) { waits.append($0) }
        precondition(waits == [.seconds(5), .seconds(5), .seconds(12)])
        let account = try await service.verify(token)
        precondition(account.login == "example" && account.id == 42)
        precondition(token.flow == .githubCopilot && token.clientID == "Iv1.testClient" && token.refreshToken == "ghr_fake")
        let renewed = try await service.refresh(token)
        precondition(refreshCount == 1 && renewed.accessToken == "gho_new" && renewed.refreshToken == "ghr_new")
        let exported = try JSONEncoder().encode(PortableSettings(endpoint: "https://github.com", model: "", loginMethod: .copilot, oauth: token))
        let imported = try JSONDecoder().decode(PortableSettings.self, from: ConfigurationLink.decode(ConfigurationLink.encode(exported))).validated()
        precondition(imported.oauth?.accessToken == token.accessToken && imported.oauth?.refreshToken == token.refreshToken)
        let exportedText = String(decoding: exported, as: UTF8.self)
        precondition(!exportedText.contains(grant.userCode) && !exportedText.contains("testDevice"))

        let bad = GitHubDeviceAuthorization(send: { _ in
            Data(grantJSON.replacingOccurrences(of: "github.com", with: "example.invalid").utf8)
        })
        do {
            _ = try await bad.begin(clientID: "testClient")
            fatalError("Untrusted verification URL accepted")
        } catch {}

        let denied = GitHubDeviceAuthorization(send: { request in
            request.url?.path == "/login/device/code" ? Data(grantJSON.utf8) : Data(#"{"error":"access_denied"}"#.utf8)
        })
        let deniedGrant = try await denied.begin(clientID: "testClient")
        do {
            _ = try await denied.finish(deniedGrant) { _ in }
            fatalError("Denied grant accepted")
        } catch {}
        do {
            _ = try await service.finish(grant) { _ in throw CancellationError() }
            fatalError("Cancelled grant continued")
        } catch is CancellationError {}
        precondition(pollCount == 3)
        try testCredentialSelection()
        print("GitHub device exchange, rate limits, identity, rejection, cancellation, portable OAuth and account switch passed.")
    }

    @MainActor
    private static func testCredentialSelection() throws {
        let defaults = UserDefaults.standard
        let domain = UserDefaults.argumentDomain
        let original = defaults.volatileDomain(forName: domain)
        var arguments = original
        arguments[APIKey.copilotRevisionKey] = "fixture-original"
        defaults.removeVolatileDomain(forName: domain)
        defaults.setVolatileDomain(arguments, forName: domain)
        defer {
            defaults.removeVolatileDomain(forName: domain)
            defaults.setVolatileDomain(original, forName: domain)
        }
        let originalSession = CopilotSession()
        try originalSession.validate()

        arguments[APIKey.copilotRevisionKey] = "fixture-replacement"
        defaults.removeVolatileDomain(forName: domain)
        defaults.setVolatileDomain(arguments, forName: domain)
        do {
            try originalSession.validate()
            fatalError("A pending request retained its previous account after the credential selection changed")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("授权已更换"))
        }
        try CopilotSession().validate()
    }
}
