import Foundation

private final class CredentialFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OAuthCredentials?
    init(_ value: OAuthCredentials) { self.value = value }
    func read() -> OAuthCredentials? {
        precondition(!Thread.isMainThread, "credential lookup must be off-main")
        lock.lock(); defer { lock.unlock() }; return value
    }
    func write(_ value: OAuthCredentials?) { lock.lock(); self.value = value; lock.unlock() }
    func expire() { lock.lock(); value?.expiresAt = 1; lock.unlock() }
    func replace(_ previous: OAuthCredentials, _ updated: OAuthCredentials) throws {
        lock.lock(); defer { lock.unlock() }
        guard value?.accessToken == previous.accessToken, value?.refreshToken == previous.refreshToken,
              value?.clientID == previous.clientID else { throw FixtureError.stale }
        value = updated
    }
}

private enum FixtureError: Error { case stale }
@MainActor private final class Fixture {
    let root: URL
    let scenario: String
    let defaults: UserDefaults
    let suite: String
    let storage: CredentialFixture
    let proxy: SingBox
    let directory: PrivateTemporaryDirectory
    var active = true
    var routeValid = true
    var renewals = 0
    var replacements = 0
    var renewalChangesVaultRevision = true
    var beforePOST: (@MainActor @Sendable () async throws -> Void)?
    var usageInput: Int64 = 0
    var usageOutput: Int64 = 0

    init(root: URL, scenario: String, verified: Bool = true, expired: Bool = false, clientID: String? = "AAUV_SYNTHETIC_OWN_APP") throws {
        self.root = root; self.scenario = scenario
        suite = "com.pendingname.aauv.ios-copilot-fixture." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(UUID().uuidString, forKey: APIKey.copilotRevisionKey)
        defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
        defaults.set(UUID().uuidString, forKey: ProxyNodes.revisionKey)
        storage = CredentialFixture(.init(flow: .githubCopilot, accessToken: "gho_SYNTHETIC_" + scenario,
                                          refreshToken: "SYNTHETIC_REFRESH", clientID: clientID,
                                          expiresAt: expired ? 1 : Date().timeIntervalSince1970 + 3600,
                                          verifiedSubject: verified ? "123" : nil, verifiedLogin: verified ? "synthetic-user" : nil))
        proxy = SingBox(defaults: defaults)
        directory = try PrivateTemporaryDirectory()
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
    func context() throws { guard active else { throw FixtureError.stale } }
    func transport() -> any CopilotHTTPTransport {
        FixtureTransport(root: root.appending(path: scenario), beforePOST: { try await self.beforePOST?() })
    }
    func capture(_ authorization: CopilotSession, _ route: ProxyRequestRoute) async throws -> CopilotPreviewSession {
        let checkedRoute = ProxyRequestRoute(configuration: route.configuration, validate: {
            try route.validate()
            if !self.routeValid { throw FixtureError.stale }
        })
        return try await CopilotPreviewSession.capture(
            authorization: authorization, route: checkedRoute, defaults: defaults,
            read: { self.storage.read() }, transport: transport(), obtainToken: {
                try await authorization.token(proxy: checkedRoute.configuration, validateRoute: checkedRoute.validate,
                                               read: { self.storage.read() }, renew: { previous in
                    if previous.clientID == nil {
                        // Exercise the real pre-exchange guard: never borrow a
                        // current settings CID to refresh somebody else's grant.
                        return try await GitHubDeviceAuthorization(proxy: checkedRoute.configuration,
                                                                  validateRoute: checkedRoute.validate).refresh(previous)
                    }
                    self.renewals += 1
                    var updated = previous
                    updated.accessToken = "gho_SYNTHETIC_" + self.scenario + "_RENEWED"
                    updated.refreshToken = "SYNTHETIC_REFRESH_RENEWED"
                    updated.expiresAt = Date().timeIntervalSince1970 + 3600
                    return updated
                }, acquireRenewalLease: {
                    try await CredentialRefreshLease.acquire(file: self.directory.url.appending(path: "lease.json"), checkPending: {})
                }, replace: { previous, updated in
                    try self.storage.replace(previous, updated)
                    self.replacements += 1
                    if self.renewalChangesVaultRevision { self.defaults.set(UUID().uuidString, forKey: APIKey.revisionKey) }
                })
            })
    }
    func session(model: String = "model", instructions: String = "PARENT_INSTRUCTIONS",
                 localToolInstructions: String = "", declaredProtocol: String? = nil) async throws -> ModelSession {
        let bot = BotSnapshot(name: "Synthetic Copilot", endpoint: "https://api.githubcopilot.com", model: model,
                              loginMethod: .copilot, apiProtocol: declaredProtocol)
        return try await ModelSession(bot: bot, instructions: instructions, proxy: proxy,
                                      localToolInstructions: localToolInstructions, captureCopilotHTTP: { route in
            try await self.capture(CopilotSession(defaults: self.defaults), route)
        })
    }
    func usage(_ counts: UsageCounts) { usageInput += counts.input; usageOutput += counts.output }
}

private struct FixtureTransport: CopilotHTTPTransport {
    let root: URL
    let beforePOST: (@MainActor @Sendable () async throws -> Void)?
    let live = CopilotHTTPURLSessionTransport()
    func send(_ original: URLRequest, body: CopilotHTTPBody,
              beforeSend: @escaping @MainActor @Sendable () throws -> Void,
              onResponse: @escaping @Sendable (HTTPURLResponse) async throws -> Void,
              onChunk: @escaping @Sendable (Data) async throws -> Bool) async throws {
        if original.httpMethod == "POST" { try await beforePOST?() }
        var request = original
        request.url = root.appending(path: original.url!.host!).appending(path: original.url!.path)
        try await live.send(request, body: body, beforeSend: beforeSend, onResponse: onResponse, onChunk: onChunk)
    }
}

@main struct CopilotIOSIntegrationTests {
    @MainActor static func main() async throws {
        let root = URL(string: CommandLine.arguments[1])!
        let messages = [ChatMessage(role: .user, content: "PARENT_HISTORY")]
        var fixtures: [Fixture] = []
        func fixture(_ scenario: String, verified: Bool = true, expired: Bool = false,
                     clientID: String? = "AAUV_SYNTHETIC_OWN_APP") throws -> Fixture {
            let f = try Fixture(root: root, scenario: scenario, verified: verified, expired: expired, clientID: clientID)
            fixtures.append(f); return f
        }
        defer { for f in fixtures { f.cleanup() } }

        let main = try fixture("main")
        let session = try await main.session(localToolInstructions: "CONVERSATION_TOOL_INSTRUCTIONS", declaredProtocol: "chat_completions")
        let file = main.directory.url.appending(path: "synthetic.txt")
        let data = Data("SYNTHETIC_ATTACHMENT".utf8)
        try data.write(to: file)
        let attachment = RequestAttachment(name: "synthetic.txt", mediaType: "text/plain", url: file, size: data.count)
        let names = ["search_chat_history", "create_skill", "read_attachment", "send_images", "delegate_to_specialist"]
        var performed: [String] = []
        var buffered = ChatClient.GeneratedFiles()
        let disabledExecution: LocalToolExecution? = try session.prepareConversationTools(enabled: false) {
            fatalError("Disabled ordinary tools must not construct execution")
        }
        precondition(disabledExecution == nil)
        let execution: LocalToolExecution? = try session.prepareConversationTools(enabled: LocalToolPreference.enabled(in: main.defaults)) {
            LocalToolExecution(names: names, namespace: "", validate: { try main.context() },
                                          drainGenerated: { let current = buffered; buffered = .init(); return current },
                                          hasGeneratedFiles: { !buffered.files.isEmpty }, perform: { call in
            performed.append(call.name)
            switch call.name {
            case "read_attachment":
                return try await session.reply(to: [.init(role: .user, content: "READ_STANDALONE")], forSummary: true,
                                               files: [attachment], validateContext: { try main.context() }, onUsage: main.usage)
            case "delegate_to_specialist":
                return try await session.reply(to: [.init(role: .user, content: "DELEGATE_STANDALONE")], forSummary: true,
                                               validateContext: { try main.context() }, onUsage: main.usage)
            case "send_images":
                buffered.files.append(.init(name: "synthetic.png", data: Data([137, 80, 78, 71])))
                return "{\"sent\":1}"
            default: return "{\"synthetic\":true}"
            }
        })
        }
        precondition(execution != nil, "Discovered Responses capability must preserve all five ordinary tools")
        var ready = 0
        var files = 0
        let text = try await session.reply(to: messages, files: [attachment], localExecution: execution,
                                           validateContext: { try main.context() }, onUsage: main.usage,
                                           onReplyReady: { reply in ready += 1; main.active = false; precondition(reply.fileCount == 1) },
                                           onGeneratedFiles: { files += $0.files.count })
        precondition(text.isEmpty && ready == 1 && files == 1 && Set(performed) == Set(names))
        precondition(main.usageInput == 40 && main.usageOutput == 4)
        // Same session can be reused for a separate title after the original
        // attempt was committed/removed. It gets its own request context.
        let title = try await session.reply(to: [.init(role: .user, content: "TITLE_STANDALONE")], forSummary: true,
                                             validateContext: {}, onUsage: main.usage)
        precondition(title == "Synthetic reply" && main.usageInput == 50)

        let imported = try fixture("imported", verified: false)
        let importedSession = try await imported.session()
        _ = try await importedSession.reply(to: messages, validateContext: { try imported.context() })

        let refreshed = try fixture("renewal", expired: true)
        let renewedSession = try await refreshed.session()
        _ = try await renewedSession.reply(to: messages, onUsage: refreshed.usage)
        precondition(refreshed.renewals == 1 && refreshed.replacements == 1)

        let unknownUsage = try fixture("usage-unknown")
        let unknownUsageSession = try await unknownUsage.session()
        let knownReply = try await unknownUsageSession.reply(to: messages, onUsage: unknownUsage.usage)
        precondition(knownReply == "Synthetic reply" && unknownUsage.usageInput == 0)

        let catalog = try fixture("catalog")
        let auth = CopilotSession(defaults: catalog.defaults)
        let models = try await auth.models(proxy: catalog.proxy, selectedModel: "model", captureHTTP: catalog.capture)
        precondition(models.first(where: { $0.id == "model" })?.allowed == true)

        for scenario in ["no-default", "disabled-default", "multiple-defaults", "messages-only-default", "unknown-default"] {
            let f = try fixture(scenario)
            do { _ = try await f.session(model: ""); fatalError("invented or ineligible default selected") }
            catch CopilotHTTPAdapter.Failure.modelRequired {}
        }
        let realDefault = try fixture("real-default")
        let defaultSession = try await realDefault.session(model: "")
        _ = try await defaultSession.reply(to: messages)
        let disabled = try fixture("disabled-explicit")
        do { _ = try await disabled.session(model: "disabled"); fatalError("disabled explicit model selected") }
        catch CopilotHTTPAdapter.Failure.policyDenied {}

        let chat = try fixture("chat")
        let chatSession = try await chat.session()
        let basic = try await chatSession.reply(to: messages, onUsage: chat.usage)
        precondition(basic == "Synthetic chat" && chat.usageInput == 7 && chat.usageOutput == 3)
        // Exercise the same production ordinary-tool preparation helper used
        // by Workspace, with its real default-true private preference. The bot's
        // declaration intentionally disagrees with the discovered CC catalog.
        let ordinaryChat = try fixture("chat")
        precondition(LocalToolPreference.enabled(in: ordinaryChat.defaults))
        let ordinarySession = try await ordinaryChat.session(localToolInstructions: "CONVERSATION_TOOL_INSTRUCTIONS", declaredProtocol: "responses")
        var constructed = 0
        let ordinaryExecution: LocalToolExecution? = try ordinarySession.prepareConversationTools(enabled: LocalToolPreference.enabled(in: ordinaryChat.defaults)) {
            constructed += 1
            return LocalToolExecution(names: names, namespace: "", perform: { _ in fatalError("CC must not construct or execute ordinary tools") })
        }
        precondition(ordinaryExecution == nil && constructed == 0)
        let ordinaryReply = try await ordinarySession.reply(to: messages, localExecution: ordinaryExecution,
                                                            validateContext: { try ordinaryChat.context() }, onUsage: ordinaryChat.usage)
        precondition(ordinaryReply == "Synthetic chat" && ordinaryChat.usageInput == 7)
        let noToolResponse = try fixture("responses-no-tools")
        let noToolSession = try await noToolResponse.session(localToolInstructions: "CONVERSATION_TOOL_INSTRUCTIONS")
        let noToolExecution: LocalToolExecution? = try noToolSession.prepareConversationTools(enabled: true) {
            fatalError("Discovered no-tool Responses model must not construct execution")
        }
        precondition(noToolExecution == nil)
        let noToolReply = try await noToolSession.reply(to: messages, localExecution: noToolExecution, onUsage: noToolResponse.usage)
        precondition(noToolReply == "Synthetic reply")
        let chatTools = LocalToolExecution(names: ["search_chat_history"], namespace: "", perform: { _ in fatalError("CC silently executed tools") })
        do { _ = try await chatSession.reply(to: messages, localExecution: chatTools); fatalError("CC silently dropped tools") }
        catch CopilotHTTPAdapter.Failure.unsupportedProtocol {}
        // forSummary must suppress even a supplied execution and instructions.
        _ = try await chatSession.reply(to: [.init(role: .user, content: "SUMMARY_STANDALONE")], forSummary: true, localExecution: chatTools)

        for action in ["token", "subject", "client", "epoch", "route", "context", "will-send"] {
            let f = try fixture("stale-" + action)
            let s = try await f.session()
            switch action {
            case "token", "subject", "client":
                var value = await Task.detached { f.storage.read()! }.value
                if action == "token" { value.accessToken += "_CHANGED" }
                if action == "subject" { value.verifiedSubject = "999" }
                if action == "client" { value.clientID = "AAUV_OTHER_APP" }
                f.storage.write(value)
            case "epoch": f.defaults.set(UUID().uuidString, forKey: ProxyNodes.revisionKey)
            case "route": f.routeValid = false
            case "context": f.active = false
            default: break
            }
            do {
                _ = try await s.reply(to: messages, validateContext: { try f.context() }, willSend: { if action == "will-send" { f.active = false } })
                fatalError("obsolete state reached provider submission")
            } catch is ChatClient.ClientError {} catch FixtureError.stale {}
        }
        let mid = try fixture("stale-delta")
        let midSession = try await mid.session()
        var published = false
        do {
            _ = try await midSession.reply(to: messages, validateContext: { try mid.context() }, onDelta: { _ in mid.active = false },
                                           onReplyReady: { _ in published = true })
            fatalError("stale completed reply published")
        } catch FixtureError.stale {}
        precondition(!published)

        let rotation = try fixture("resume-rotation")
        rotation.renewalChangesVaultRevision = false // Actual native CAS does not change imported-vault revision.
        let rotatingSession = try await rotation.session()
        rotation.beforePOST = {
            rotation.beforePOST = nil
            rotation.storage.expire()
            _ = try await rotation.capture(CopilotSession(defaults: rotation.defaults), try rotation.proxy.requestRoute())
        }
        do { _ = try await rotatingSession.reply(to: messages); fatalError("old token remained current after peer refresh") }
        catch is ChatClient.ClientError {}
        precondition(rotation.renewals == 1 && rotation.replacements == 1)

        let unrelated = try fixture("vault-unrelated")
        let unrelatedSession = try await unrelated.session()
        let vaultExecution = LocalToolExecution(names: ["delegate_to_specialist"], namespace: "", perform: { _ in
            // Shared-vault publication by a different provider is neither a
            // Copilot record change nor a complete configuration import.
            unrelated.defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
            return "{\"answer\":\"synthetic\"}"
        })
        let vaultReply = try await unrelatedSession.reply(to: messages, localExecution: vaultExecution)
        precondition(vaultReply == "Synthetic reply")

        let legacy = try fixture("legacy-nil-cid", verified: false, clientID: nil)
        legacy.defaults.set("DO_NOT_BORROW_THIS_CID", forKey: "githubCopilotClientID")
        let legacySession = try await legacy.session()
        let legacyReply = try await legacySession.reply(to: messages)
        let legacyRecord = await Task.detached { legacy.storage.read() }.value
        precondition(legacyReply == "Synthetic reply" && legacyRecord?.clientID == nil)

        let appeared = try fixture("stale-cid-appeared", clientID: nil)
        let appearedSession = try await appeared.session()
        var appearedRecord = await Task.detached { appeared.storage.read()! }.value
        appearedRecord.clientID = "AAUV_ANOTHER_ORIGIN_APP"
        appeared.storage.write(appearedRecord)
        do { _ = try await appearedSession.reply(to: messages); fatalError("nil-CID record silently rebound to another App") }
        catch is ChatClient.ClientError {}

        let expiredLegacy = try fixture("legacy-expired", expired: true, clientID: nil)
        expiredLegacy.defaults.set("DO_NOT_BORROW_THIS_CID", forKey: "githubCopilotClientID")
        do { _ = try await expiredLegacy.session(); fatalError("expired legacy grant borrowed a CID") }
        catch let error as ChatClient.ClientError { precondition(error.localizedDescription.contains("重新登录")) }

        let forbidden = try fixture("forbidden")
        let forbiddenSession = try await forbidden.session()
        do { _ = try await forbiddenSession.reply(to: messages); fatalError("service rejection ignored") }
        catch CopilotHTTPAdapter.Failure.http(403) {}

        for scenario in ["cancel", "signout"] {
            let f = try fixture(scenario)
            let s = try await f.session()
            var delta = false
            var waiting: CheckedContinuation<Void, Never>?
            var completed = false
            let request = Task { @MainActor in
                try await s.reply(to: messages, validateContext: { try f.context() }, onDelta: { _ in delta = true; waiting?.resume(); waiting = nil },
                                  onReplyReady: { _ in completed = true })
            }
            await withCheckedContinuation { signal in if delta { signal.resume() } else { waiting = signal } }
            let start = ContinuousClock.now
            if scenario == "cancel" { request.cancel() }
            else {
                try await CopilotSession.signOut(defaults: f.defaults, read: { .init(configurationWithoutCopilot: nil) }, acquireLease: {
                    try await CredentialRefreshLease.acquire(file: f.directory.url.appending(path: "logout.json"), checkPending: {})
                }, clear: { _ in f.storage.write(nil) })
            }
            do { _ = try await request.value; fatalError("cancel/signout did not stop request") } catch {}
            precondition(!completed && start.duration(to: .now) < .seconds(3))
        }
        print("iOS Copilot wiring passed real ModelSession fake HTTP main chain")
    }
}
