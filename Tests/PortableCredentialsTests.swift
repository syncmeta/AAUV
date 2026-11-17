import Foundation

@main
struct PortableCredentialsTests {
    @MainActor static func main() async throws {
        let apiA = "https://example.invalid/a/v1"
        let apiB = "https://example.invalid/b/v1"
        let legacy = try PortableSettings(version: 3, endpoint: apiA, model: "old", loginMethod: .byok,
                                          key: "fixture-a").validated()
        let plans = [
            OAuthCredentials(flow: .chatgptPlan, accessToken: "fixture-plan-1", refreshToken: "refresh-1",
                             clientID: "plan-1", verifiedSubject: "injected identity", verifiedEmail: "fake@example.invalid"),
            OAuthCredentials(flow: .chatgptPlan, accessToken: "fixture-plan-2", clientID: "plan-2")
        ]
        let copilot = OAuthCredentials(flow: .githubCopilot, accessToken: "gho_fixture", verifiedLogin: "fake")
        let defaults = ProviderDefaults(byokEndpoint: apiB + "/", byokModel: "text-b", byokProtocol: "responses",
                                        chatGPTModel: "plan-model", copilotModel: "copilot-model",
                                        byokHostedTools: ["code_interpreter", "web_search"],
                                        chatGPTHostedTools: ["web_search"])
        let bundle = PortableCredentials(byokKeys: [apiB + "/": "fixture-b"], chatGPT: plans, copilot: copilot,
                                         preferredChatGPTClientID: "plan-2")
        let imported = try PortableSettings(endpoint: "https://api.openai.com/v1", model: "plan-model", loginMethod: .chatgpt,
                                            credentials: bundle, providerDefaults: defaults).validated()
        let link = try ConfigurationLink.encode(JSONEncoder().encode(imported))
        let decoded = try JSONDecoder().decode(PortableSettings.self, from: ConfigurationLink.decode(link)).validated()
        let stored = try APIKey.configurationToStore(decoded, previous: legacy)
        precondition(decoded.providerDefaults?.byokEndpoint == apiB && decoded.providerDefaults?.copilotModel == "copilot-model")
        precondition(decoded.providerDefaults?.byokHostedTools == ["web_search", "code_interpreter"])
        precondition(decoded.providerDefaults?.chatGPTHostedTools == ["web_search"])
        precondition(stored.key == nil && stored.oauth == nil)
        precondition(stored.credentials?.byokKeys == [apiA: "fixture-a", apiB: "fixture-b"])
        precondition(stored.credentials?.chatGPTAuthorization()?.clientID == "plan-2")
        precondition(stored.credentials?.chatGPTAuthorization(clientID: "plan-1")?.verifiedSubject == nil)
        precondition(stored.credentials?.copilot?.verifiedLogin == nil)

        let noSecrets = try PortableSettings(endpoint: apiA, model: "new", loginMethod: .byok).validated()
        let afterNoSecrets = try APIKey.configurationToStore(noSecrets, previous: stored)
        precondition(afterNoSecrets.credentials?.byokKeys == stored.credentials?.byokKeys)
        precondition(afterNoSecrets.credentials?.chatGPTAuthorization(clientID: "plan-1")?.refreshToken == "refresh-1")
        precondition(afterNoSecrets.credentials?.copilot?.accessToken == "gho_fixture")

        let legacyPlan = try PortableSettings(version: 3, endpoint: "https://api.openai.com/v1", model: "plan",
                                               loginMethod: .chatgpt, oauth: plans[0]).validated()
        let afterLegacyPlan = try APIKey.configurationToStore(legacyPlan, previous: afterNoSecrets)
        precondition(afterLegacyPlan.credentials?.chatGPTAuthorization()?.clientID == "plan-1")
        precondition(afterLegacyPlan.credentials?.chatGPTAuthorization(clientID: "plan-2")?.accessToken == "fixture-plan-2")

        let replacement = try PortableSettings(endpoint: apiA, model: "new", key: "fixture-a-rotated").validated()
        let afterReplace = try APIKey.configurationToStore(replacement, previous: afterLegacyPlan)
        precondition(afterReplace.credentials?.byokKeys == [apiA: "fixture-a-rotated", apiB: "fixture-b"])

        let cleared = PortableSettings(version: 3, endpoint: apiA, model: "old", loginMethod: .byok, key: "")
        let afterCleared = try APIKey.configurationToStore(noSecrets, previous: cleared)
        precondition(afterCleared.credentials?.byokKeys?[apiA] == "", "Previously cleared keys must remain cleared")

        let conflicting = PortableCredentials(byokKeys: [apiB: "one", apiB + "/": "two"])
        precondition((try? conflicting.validated()) == nil)
        let duplicate = PortableCredentials(chatGPT: [plans[0], plans[0]])
        precondition((try? duplicate.validated()) == nil)
        let legacyConflict = PortableSettings(endpoint: apiA, model: "test", key: "one",
                                              credentials: PortableCredentials(byokKeys: [apiA: "two"]))
        precondition((try? legacyConflict.validated()) == nil)
        let codex = PortableSettings(endpoint: "https://example.invalid/v1", model: "fixture",
                                     oauth: OAuthCredentials(flow: .codex, accessToken: "fixture"))
        do {
            _ = try codex.validated()
            fatalError("Expected a Codex credential to be rejected before import")
        } catch {
            precondition(error.localizedDescription.contains("Codex CLI"))
        }
        let oldPlanAddress = try PortableSettings(version: 2, endpoint: "https://old.example.invalid/v1", model: "plan",
                                                  oauth: plans[0]).validated()
        precondition(oldPlanAddress.loginMethod == .chatgpt && oldPlanAddress.endpoint == "https://api.openai.com/v1")
        let oldCopilotAddress = try PortableSettings(version: 3, endpoint: apiA, model: "",
                                                     oauth: copilot).validated()
        precondition(oldCopilotAddress.loginMethod == .copilot && oldCopilotAddress.endpoint == "https://github.com")

        let directory = try PrivateTemporaryDirectory()
        let file = directory.url.appending(path: "legacy.json")
        let legacyJSON = Data(#"{"version":1,"endpoint":"https://example.invalid/a/v1","model":"old","key":"fixture"}"#.utf8)
        try legacyJSON.write(to: file)
        let fromFile = try JSONDecoder().decode(PortableSettings.self, from: PortableSettings.readFile(file)).validated()
        precondition(fromFile.apiProtocol == "chat_completions" && fromFile.key == "fixture")
        let namedFile = directory.url.appending(path: "legacy.aauv.json")
        try legacyJSON.write(to: namedFile)
        guard case .configurationFile(let opened) = try FileOpenRequest.read(namedFile) else {
            fatalError("Expected a named configuration file to open for preview")
        }
        let openedData = try PortableSettings.readFile(opened)
        precondition(opened == namedFile && openedData == legacyJSON)
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: UInt64(PortableSettings.maximumFileBytes + 1))
        try writer.close()
        do {
            _ = try PortableSettings.readFile(file)
            fatalError("Expected an oversized configuration file to be rejected")
        } catch let error as CocoaError {
            precondition(error.code == .fileReadTooLarge)
        }
        precondition((try? ChatClient.baseURL("https://AAUV.invalid./imported-configuration")) == nil)
        precondition((try? ChatClient.baseURL("https://%61auv.invalid/github-copilot")) == nil)
        try await checkChatGPTRenewal()
        try await checkPlanPermission()
        try await checkPlanRevocation()
        try await checkSignOut()
        await checkRevocationRequest()
        print("Provider credentials, configuration link and file validation, legacy migration and endpoint isolation passed.")
    }

    @MainActor private static func checkRevocationRequest() async {
        let confirmed = await ChatGPTPlanSession.revokeSession("fixture&refresh", clientID: "oaiapp_fixture") { request in
            if request.httpMethod != "POST" {
                precondition(request.url?.absoluteString == "https://auth.openai.com/.well-known/openid-configuration")
                return (Data(#"{"revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#.utf8), 200)
            }
            precondition(request.url?.absoluteString == "https://auth.openai.com/api/accounts/oauth/revoke")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            var body = URLComponents()
            body.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let fields = body.queryItems ?? []
            precondition(fields.count == 3 && fields.contains(.init(name: "token", value: "fixture&refresh")))
            precondition(fields.contains(.init(name: "client_id", value: "oaiapp_fixture")))
            precondition(fields.contains(.init(name: "token_type_hint", value: "refresh_token")))
            return (Data(), 200)
        }
        precondition(confirmed)
        let otherOrigin = await ChatGPTPlanSession.revokeSession("fixture-refresh", clientID: "oaiapp_fixture") { request in
            precondition(request.httpMethod != "POST" && request.httpBody == nil)
            return (Data(#"{"revocation_endpoint":"https://other.invalid/oauth/revoke"}"#.utf8), 200)
        }
        precondition(!otherOrigin)
    }

    @MainActor private static func checkSignOut() async throws {
        typealias Selection = ChatGPTPlanSession.Selection
        let id = "oaiapp_fixture_sign_out"
        let original = OAuthCredentials(flow: .chatgptPlan, accessToken: "fixture-old-access", refreshToken: "fixture-old-refresh",
                                        idToken: "fixture-id-token", clientID: id, expiresAt: 1,
                                        scopes: ["resource.invoke", "chatgpt.tokens.use.direct"], verifiedSubject: "fixture-subject")
        var native = Selection(credentials: original, source: .native)
        var imported = Selection(credentials: original.transferable, source: .imported)
        let running = AsyncStream<Void>.makeStream()
        let request = Task {
            try await ChatGPTPlanSession.withRequest(id) {
                running.continuation.yield(())
                try await Task.sleep(for: .seconds(15))
                return "request did not stop"
            }
        }
        for await _ in running.stream { break }
        let refreshing = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let renewal = Task {
            try await ChatGPTPlanSession.resolveToken(clientID: id, read: { _ in native }) { _ in
                refreshing.continuation.yield(())
                for await _ in release.stream { break }
                var fresh = original
                fresh.accessToken = "fixture-new-access"
                fresh.refreshToken = "fixture-new-refresh"
                native = .init(credentials: fresh, source: .native)
                return fresh
            }
        }
        for await _ in refreshing.stream { break }
        var attempts: [String] = []
        let signingOut = Task {
            try await ChatGPTPlanSession.endSession(id, read: { [native, imported] }, revoke: { token in
                attempts.append(token)
                return token == "fixture-new-refresh"
            }, replace: { previous, cleared in
                precondition(cleared.accessToken.isEmpty && cleared.refreshToken == nil && cleared.idToken == nil)
                precondition(cleared.clientID == id && cleared.reauthorizationRequired == true)
                let replacement = Selection(credentials: cleared, source: previous.source)
                if previous.source == .native { native = replacement }
                else { imported = replacement }
            })
        }
        do {
            _ = try await request.value
            fatalError("Sign-out did not cancel the active request")
        } catch is CancellationError {}
        do {
            try ChatGPTPlanSession.requireNotSigningOut(id)
            fatalError("Sign-out should block new requests until revocation and local clearing finish")
        } catch is ChatClient.ClientError {}
        try ChatGPTPlanSession.requireNotSigningOut("oaiapp_other_account")
        release.continuation.yield(())
        let confirmed = try await signingOut.value
        precondition(!confirmed && attempts == ["fixture-new-refresh", "fixture-old-refresh"])
        do {
            _ = try await renewal.value
            fatalError("An expired session issued a usable token during sign-out")
        } catch is ChatClient.ClientError {}
        precondition(native.credentials.verifiedSubject == "fixture-subject")
        precondition(!native.credentials.permitsChatGPTPlan && !imported.credentials.permitsChatGPTPlan)
        print("ChatGPT sign-out cancelled the active request, waited for rotation, and cleared both credential slots.")
    }

    @MainActor private static func checkPlanRevocation() async throws {
        let id = "oaiapp_fixture_revoked"
        let original = OAuthCredentials(flow: .chatgptPlan, accessToken: "fixture-access", refreshToken: "fixture-refresh",
                                        idToken: "fixture-identity", clientID: id, expiresAt: 1,
                                        scopes: ["resource.invoke", "chatgpt.tokens.use.direct"], verifiedSubject: "fixture-subject")
        var saved: OAuthCredentials?
        for (status, body) in [(503, #"{"error":"invalid_grant"}"#), (400, #"{"error":"invalid_client"}"#)] {
            do {
                _ = try await ChatGPTPlanSession.updateAfterRefresh(original, exchange: {
                    try ChatGPTPlanSession.tokenResponse(Data(body.utf8), status: status)
                }, save: { saved = $0 })
                fatalError("Failed token responses cannot renew a grant")
            } catch let error as ChatGPTPlanSession.TokenExchangeError {
                precondition(error.status == status)
            }
            precondition(saved == nil)
        }
        do {
            _ = try await ChatGPTPlanSession.updateAfterRefresh(original, exchange: {
                try ChatGPTPlanSession.tokenResponse(Data(#"{"error":{"code":"refresh_token_reused","message":"private text"}}"#.utf8),
                                                      status: 400)
            }, save: { saved = $0 })
            fatalError("A revoked refresh token produced a renewed grant")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("请在设置重新登录"))
        }
        guard let cleared = saved else { throw CocoaError(.fileReadCorruptFile) }
        precondition(cleared.accessToken.isEmpty && cleared.refreshToken == nil && cleared.expiresAt == nil)
        precondition(cleared.clientID == id && cleared.idToken == original.idToken &&
                     cleared.verifiedSubject == original.verifiedSubject && cleared.reauthorizationRequired == true)
        let local = try JSONDecoder().decode(OAuthCredentials.self, from: JSONEncoder().encode(cleared))
        do {
            _ = try await ChatGPTPlanSession.resolveToken(clientID: id, read: { _ in .init(credentials: local, source: .native) }) { _ in
                fatalError("A cleared token set attempted another refresh")
            }
            fatalError("A revoked credential supplied an access token")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("授权已失效"))
        }
        let before = PortableSettings(endpoint: "https://api.openai.com/v1", model: "fixture", loginMethod: .chatgpt,
                                      credentials: .init(chatGPT: [cleared.transferable], preferredChatGPTClientID: id))
        var reimported = before
        reimported.credentials?.chatGPT = [original.transferable]
        let merged = try APIKey.configurationToStore(reimported, previous: before)
        precondition(merged.credentials?.chatGPTAuthorization(clientID: id)?.accessToken == original.accessToken)
        precondition(merged.credentials?.chatGPTAuthorization(clientID: id)?.reauthorizationRequired != true)
        print("ChatGPT revocation cleared unusable tokens, kept the registration, and preserved credentials on transient errors.")
    }

    @MainActor private static func checkPlanPermission() async throws {
        typealias Selection = ChatGPTPlanSession.Selection
        let id = "fixture-plan-permission"
        let identityOnly = OAuthCredentials(flow: .chatgptPlan, accessToken: "identity-only", refreshToken: "refresh",
                                            clientID: id, expiresAt: 1, scopes: ["openid", "email"],
                                            verifiedSubject: "fixture-user")
        let transferred = try JSONDecoder().decode(OAuthCredentials.self, from: JSONEncoder().encode(identityOnly.transferable))
        precondition(!identityOnly.permitsChatGPTPlan && !transferred.permitsChatGPTPlan)
        var current = Selection(credentials: identityOnly, source: .native)
        let read: (String?) throws -> Selection? = { $0 == id ? current : nil }
        do {
            _ = try await ChatGPTPlanSession.resolveToken(clientID: id, read: read) { _ in
                fatalError("Known identity-only credentials must not be used for a plan request")
            }
            fatalError("An identity-only grant supplied a model token")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("尚未授权"))
        }

        var permitted = identityOnly
        permitted.scopes = ["openid", "resource.invoke", "chatgpt.tokens.use.direct"]
        current = Selection(credentials: permitted, source: .native)
        do {
            _ = try await ChatGPTPlanSession.resolveToken(clientID: id, read: read) { _ in
                var narrowed = identityOnly
                narrowed.accessToken = "rotated-identity-only"
                narrowed.refreshToken = "rotated-refresh"
                narrowed.expiresAt = Date().timeIntervalSince1970 + 3600
                current = Selection(credentials: narrowed, source: .native)
                return narrowed
            }
            fatalError("An explicit scope reduction during renewal supplied a model token")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("尚未授权"))
        }
        precondition(current.credentials.verifiedSubject == identityOnly.verifiedSubject)
        precondition(current.credentials.refreshToken == "rotated-refresh")
        print("ChatGPT identity-only grants and permission changes during refresh were blocked before inference.")
    }

    @MainActor private static func checkChatGPTRenewal() async throws {
        let expired = OAuthCredentials(flow: .chatgptPlan, accessToken: "old", refreshToken: "old-refresh",
                                       clientID: "fixture-registered-account", expiresAt: 1)
        let missing = try ChatGPTPlanSession.select(clientID: nil, activeRegistration: "missing-account", nativePreferences: [],
                                                    native: { _ in nil },
                                                    imported: { $0 == nil ? expired : nil })
        precondition(missing == nil)

        let nativeID = expired.clientID!
        var importedDuplicate = expired
        importedDuplicate.accessToken = "imported-copy"
        let other = OAuthCredentials(flow: .chatgptPlan, accessToken: "other-account", clientID: "other-registration")
        let readNative: (String) -> OAuthCredentials? = { $0 == nativeID ? expired : nil }
        let readImported: (String?) -> OAuthCredentials? = { id in
            if id == nativeID { return importedDuplicate }
            return id == other.clientID || id == nil ? other : nil
        }
        let original = try ChatGPTPlanSession.select(clientID: nil, activeRegistration: nativeID, nativePreferences: [nativeID],
                                                     native: readNative, imported: readImported)
        let afterSwitch = try ChatGPTPlanSession.select(clientID: nativeID, activeRegistration: other.clientID,
                                                        nativePreferences: [nativeID], native: readNative, imported: readImported)
        let newDefault = try ChatGPTPlanSession.select(clientID: nil, activeRegistration: other.clientID,
                                                       nativePreferences: [nativeID], native: readNative, imported: readImported)
        let afterImport = try ChatGPTPlanSession.select(clientID: nativeID, activeRegistration: nativeID, nativePreferences: [],
                                                        native: readNative, imported: readImported)
        precondition(original?.source == .native && afterSwitch?.matches(original!) == true)
        precondition(newDefault?.credentials.clientID == other.clientID)
        precondition(afterImport?.source == .imported && afterImport?.credentials.accessToken == importedDuplicate.accessToken)

        typealias Selection = ChatGPTPlanSession.Selection
        var current = Selection(credentials: expired, source: .native)
        let read: (String?) throws -> Selection? = { id in id == expired.clientID ? current : nil }
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let previous = Task {
            try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: read) { selection in
                precondition(selection.matches(Selection(credentials: expired, source: .native)))
                start.yield(())
                for await _ in released { break }
                var refreshed = expired
                refreshed.accessToken = "obsolete-renewal"
                refreshed.refreshToken = "obsolete-refresh"
                return refreshed
            }
        }
        var startIterator = started.makeAsyncIterator()
        _ = await startIterator.next()

        var replacement = expired
        replacement.accessToken = "new-login"
        replacement.refreshToken = "new-login-refresh"
        current = Selection(credentials: replacement, source: .imported)
        do {
            _ = try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: read) { _ in
                fatalError("A different token set must wait for the prior renewal to finish")
            }
            fatalError("An expired replacement must not borrow a renewal from the previous token set")
        } catch is ChatClient.ClientError {}

        replacement.expiresAt = Date().timeIntervalSince1970 + 3600
        current = Selection(credentials: replacement, source: .imported)
        let resolved = try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: read) { _ in
            fatalError("A valid replacement should be used immediately")
        }
        precondition(resolved == replacement.accessToken)
        release.yield(())
        do {
            _ = try await previous.value
            fatalError("A completed renewal must not supply a token after the selection changed")
        } catch is ChatClient.ClientError {}

        current = Selection(credentials: expired, source: .native)
        let (began, begin) = AsyncStream<Void>.makeStream()
        let (joined, join) = AsyncStream<Void>.makeStream()
        let (ready, finish) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: read) { _ in
                begin.yield(())
                for await _ in ready { break }
                current = Selection(credentials: replacement, source: .native)
                return replacement
            }
        }
        var beganIterator = began.makeAsyncIterator()
        _ = await beganIterator.next()
        let second = Task {
            try await ChatGPTPlanSession.resolveToken(clientID: expired.clientID, read: { id in
                join.yield(())
                return try read(id)
            }) { _ in
                fatalError("Two requests for the same token set should share one renewal")
            }
        }
        var joinedIterator = joined.makeAsyncIterator()
        _ = await joinedIterator.next()
        finish.yield(())
        let firstToken = try await first.value
        let secondToken = try await second.value
        precondition(firstToken == replacement.accessToken && secondToken == replacement.accessToken)
        print("ChatGPT account switching preserved bound credentials; imported replacement and shared refresh passed.")
    }
}
