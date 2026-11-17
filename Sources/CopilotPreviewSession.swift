import Foundation
import Network

// The preview owns a pinned HTTP conversation, never OAuth persistence. The
// existing CopilotSession owns renewal/CAS, request registration and sign-out.
@MainActor
final class CopilotPreviewSession {
    typealias Read = @Sendable () throws -> OAuthCredentials?
    typealias Capture = @MainActor (CopilotSession, ProxyRequestRoute) async throws -> CopilotPreviewSession

    private let pin: Pin
    private let adapter: CopilotHTTPAdapter
    private let catalog: CopilotHTTPAdapter.Catalog

    private init(pin: Pin, adapter: CopilotHTTPAdapter, catalog: CopilotHTTPAdapter.Catalog) {
        self.pin = pin; self.adapter = adapter; self.catalog = catalog
    }

    static func capture(
        authorization: CopilotSession, route: ProxyRequestRoute, defaults: UserDefaults = .standard,
        read: @escaping Read = { try APIKey.checkNoPendingConfigurationImport(); return try APIKey.copilotCredentials() },
        transport: (any CopilotHTTPTransport)? = nil,
        obtainToken: (@MainActor () async throws -> String)? = nil
    ) async throws -> CopilotPreviewSession {
        try await authorization.withRequest {
            let epoch = defaults.string(forKey: ProxyNodes.revisionKey)
            let token: String
            if let obtainToken { token = try await obtainToken() }
            else { token = try await authorization.token(proxy: route.configuration, validateRoute: route.validate, read: read) }
            try authorization.validate()
            try route.validate()
            guard epoch == defaults.string(forKey: ProxyNodes.revisionKey) else { throw Self.changed }
            // Pin the provider's post-renewal generation, not the shared vault
            // revision: an unrelated ChatGPT refresh also republishes that vault.
            let generation = CopilotSession.httpTokenGeneration
            let captured = try await APIKey.readInBackground(read)
            try authorization.validate()
            try route.validate()
            guard epoch == defaults.string(forKey: ProxyNodes.revisionKey),
                  let captured, captured.flow == .githubCopilot, captured.accessToken == token,
                  captured.reauthorizationRequired != true else { throw Self.changed }
            let clientID = captured.clientID // Legacy bearer grants may omit their original OAuth App ID.
            try captured.validateStructure()
            let configuration = URLSessionConfiguration.ephemeral
            if let proxy = route.configuration { configuration.proxyConfigurations = [proxy] }
            let selectedTransport = transport ?? CopilotHTTPURLSessionTransport(configuration: configuration)
            let baseScope: ProxyRouteCheck = {
                try authorization.validate()
                try route.validate()
                guard epoch == defaults.string(forKey: ProxyNodes.revisionKey),
                      generation == CopilotSession.httpTokenGeneration else { throw Self.changed }
            }
            let subject: String
            let login: String
            if let storedSubject = captured.verifiedSubject, !storedSubject.isEmpty,
               let storedLogin = captured.verifiedLogin, !storedLogin.isEmpty {
                subject = storedSubject; login = storedLogin
            } else {
                // Portable imports intentionally strip verification metadata.
                // Reuse the existing /user verifier, with the new guarded HTTP
                // transport, and bind its result only to this exact token.
                let verifier = GitHubDeviceAuthorization(send: { request in
                    let collector = IdentityData()
                    try await selectedTransport.send(request, body: .none, beforeSend: baseScope, onResponse: { response in
                        guard response.statusCode == 200 else { throw CopilotHTTPAdapter.Failure.http(response.statusCode) }
                    }, onChunk: { try await collector.append($0); return true })
                    try baseScope()
                    return await collector.data
                })
                let account = try await verifier.verify(captured)
                subject = String(account.id); login = account.login
                if let prior = captured.verifiedSubject, prior != subject { throw CopilotHTTPAdapter.Failure.identityMismatch }
                if let prior = captured.verifiedLogin, prior.caseInsensitiveCompare(login) != .orderedSame {
                    throw CopilotHTTPAdapter.Failure.identityMismatch
                }
            }
            let credential = try CopilotHTTPAdapter.Credential(token: token, accountID: subject, login: login,
                                                              clientID: clientID, bindingID: UUID())
            let pin = Pin(authorization: authorization, route: route, defaults: defaults,
                          epoch: epoch, generation: generation, snapshot: captured, read: read, credential: credential)
            try await pin.checkCredential()
            let adapter = CopilotHTTPAdapter(transport: selectedTransport)
            let catalog = try await adapter.discover(credential: credential, guards: pin.guards())
            try pin.validate()
            return CopilotPreviewSession(pin: pin, adapter: adapter, catalog: catalog)
        }
    }

    func validate() throws { try pin.validate() }

    func selectedModel(_ model: String) throws -> String { try catalog.select(model).model.id }

    // Read the exact immutable discovered catalog used by reply; never infer
    // the HTTP protocol or tool capability from a saved bot setting.
    func supportsConversationTools(model: String) throws -> Bool {
        try validate()
        let prepared = try catalog.select(model)
        return prepared.apiProtocol == .responses && prepared.model.capabilities?.supports?.tool_calls != false
    }

    func models(selectedModel: String? = nil) throws -> [CopilotClient.Model] {
        try validate()
        if let selectedModel { _ = try catalog.select(selectedModel) }
        let models = catalog.models.filter { $0.capabilities?.type == "chat" }.map {
            CopilotClient.Model(id: $0.id, name: $0.name ?? $0.id, allowed: (try? $0.preferredProtocol()) != nil)
        }
        guard models.contains(where: \.allowed) else { throw CopilotHTTPAdapter.Failure.unsupportedProtocol }
        return models
    }

    func reply(
        to messages: [ChatMessage], model: String, instructions: String, forSummary: Bool,
        files: [RequestAttachment], localExecution: LocalToolExecution?,
        validateContext: ProxyRouteCheck?, willSend: (@MainActor () throws -> Void)?, onDelta: (@MainActor (String) throws -> Void)?,
        onLocalTool: (@MainActor (String?) -> Void)?, onUsage: (@MainActor (UsageCounts) -> Void)?,
        onReplyReady: (@MainActor (ChatClient.CompletedReply) throws -> Void)?,
        onGeneratedFiles: (@MainActor (ChatClient.GeneratedFiles) throws -> Void)?
    ) async throws -> String {
        try await pin.authorization.withRequest {
            try self.validate()
            let prepared = try self.catalog.select(model)
            let execution = forSummary ? nil : localExecution.map { self.pin.execution($0, context: validateContext) }
            let callbacks = Callbacks(pin: self.pin, execution: execution, context: validateContext, willSend: willSend, onDelta: onDelta,
                                      onUsage: onUsage, onReplyReady: onReplyReady, onGeneratedFiles: onGeneratedFiles)
            let guards = self.pin.guards(scope: { try callbacks.validate() })
            let attachments = files.map(ChatClient.AttachmentInput.inline)
            if let execution {
                guard prepared.apiProtocol == .responses else { throw CopilotHTTPAdapter.Failure.unsupportedProtocol }
                return try await ResponseToolLoop.run(execution: execution, send: { state in
                    try await CopilotHTTPCoreBridge.reply(
                        to: messages, prepared: prepared, adapter: self.adapter, guards: guards,
                        instructions: instructions, attachments: attachments, localTools: execution.names,
                        continuation: state.continuation, usedCallIDs: state.usedCallIDs,
                        allowEmptyFinalReply: state.allowEmptyFinalReply, willSend: { try callbacks.submit() },
                        onUsage: { callbacks.usage($0) }, onDelta: { try callbacks.delta($0) })
                }, onDelta: callbacks.delta, onLocalTool: onLocalTool,
                   onReplyReady: callbacks.deliver, onGeneratedFiles: callbacks.generated)
            }
            let turn = try await CopilotHTTPCoreBridge.reply(
                to: messages, prepared: prepared, adapter: self.adapter, guards: guards,
                instructions: forSummary ? "" : instructions, attachments: attachments,
                willSend: { try callbacks.submit() }, onUsage: { callbacks.usage($0) }, onDelta: { try callbacks.delta($0) })
            try callbacks.deliver(turn.reply)
            return turn.reply.text
        }
    }

    private static var changed: ChatClient.ClientError {
        .message("Copilot 凭证或应用配置已更换，请重新检查访问权限后重试。")
    }

    @MainActor private final class Pin {
        let authorization: CopilotSession
        let route: ProxyRequestRoute
        let defaults: UserDefaults
        let epoch: String?
        let generation: UUID
        let snapshot: OAuthCredentials
        let read: Read
        let credential: CopilotHTTPAdapter.Credential

        init(authorization: CopilotSession, route: ProxyRequestRoute, defaults: UserDefaults,
             epoch: String?, generation: UUID, snapshot: OAuthCredentials, read: @escaping Read, credential: CopilotHTTPAdapter.Credential) {
            self.authorization = authorization; self.route = route; self.defaults = defaults
            self.epoch = epoch; self.generation = generation; self.snapshot = snapshot; self.read = read; self.credential = credential
        }
        func validate(checkCancellation: Bool = true) throws {
            if checkCancellation { try Task.checkCancellation() }
            try authorization.validateState()
            try route.validate()
            guard defaults.string(forKey: ProxyNodes.revisionKey) == epoch,
                  CopilotSession.httpTokenGeneration == generation else { throw Self.changed }
        }
        func checkCredential() async throws {
            try validate()
            let current = try await APIKey.readInBackground(read)
            try validate()
            guard let current, Self.same(current, snapshot) else { throw Self.changed }
        }
        private static func same(_ a: OAuthCredentials, _ b: OAuthCredentials) -> Bool {
            a.flow == b.flow && a.accessToken == b.accessToken && a.refreshToken == b.refreshToken &&
            a.clientID == b.clientID && a.expiresAt == b.expiresAt && a.scopes == b.scopes &&
            a.verifiedSubject == b.verifiedSubject && a.verifiedLogin == b.verifiedLogin &&
            a.idToken == b.idToken && a.verifiedEmail == b.verifiedEmail && a.reauthorizationRequired == b.reauthorizationRequired
        }
        func guards(scope: (@MainActor @Sendable () throws -> Void)? = nil) -> CopilotHTTPAdapter.Guards {
            .init(validateCredential: { candidate in try await self.check(candidate) },
                  validateScope: { try self.validate(); try scope?() })
        }
        private func check(_ candidate: CopilotHTTPAdapter.Credential) async throws {
            guard candidate.bindingID == credential.bindingID, candidate.accountID == credential.accountID,
                  candidate.clientID == credential.clientID else { throw Self.changed }
            try await checkCredential()
        }
        func execution(_ base: LocalToolExecution, context: ProxyRouteCheck?) -> LocalToolExecution {
            let validate: ProxyRouteCheck = {
                try self.validate(checkCancellation: false)
                try context?()
                try base.validate()
            }
            return .init(names: base.names, namespace: base.namespace, validate: validate,
                         drainGenerated: base.drainGenerated, hasGeneratedFiles: base.hasGeneratedFiles,
                         perform: { call in
                try Task.checkCancellation()
                try validate()
                let result = try await base.perform(call)
                try validate()
                return result
            })
        }
        private static var changed: ChatClient.ClientError { CopilotPreviewSession.changed }
    }

    @MainActor private final class Callbacks {
        let pin: Pin
        let execution: LocalToolExecution?
        let context: ProxyRouteCheck?
        var deliveryStarted = false
        let willSend: (@MainActor () throws -> Void)?
        let onDelta: (@MainActor (String) throws -> Void)?
        let onUsage: (@MainActor (UsageCounts) -> Void)?
        let onReplyReady: (@MainActor (ChatClient.CompletedReply) throws -> Void)?
        let onGeneratedFiles: (@MainActor (ChatClient.GeneratedFiles) throws -> Void)?
        init(pin: Pin, execution: LocalToolExecution?, context: ProxyRouteCheck?, willSend: (@MainActor () throws -> Void)?,
             onDelta: (@MainActor (String) throws -> Void)?, onUsage: (@MainActor (UsageCounts) -> Void)?,
             onReplyReady: (@MainActor (ChatClient.CompletedReply) throws -> Void)?,
             onGeneratedFiles: (@MainActor (ChatClient.GeneratedFiles) throws -> Void)?) {
            self.pin = pin; self.execution = execution; self.context = context; self.willSend = willSend; self.onDelta = onDelta
            self.onUsage = onUsage; self.onReplyReady = onReplyReady; self.onGeneratedFiles = onGeneratedFiles
        }
        func validate() throws {
            try pin.validate(checkCancellation: false)
            if !deliveryStarted { try context?(); try execution?.validate() }
        }
        func submit() throws { try validate(); try willSend?(); try validate() }
        func delta(_ text: String) throws { try validate(); try onDelta?(text); try validate() }
        func usage(_ counts: UsageCounts) { onUsage?(counts) }
        func deliver(_ reply: ChatClient.CompletedReply) throws {
            try validate()
            deliveryStarted = true
            try onReplyReady?(reply)
        }
        func generated(_ files: ChatClient.GeneratedFiles) throws { try validate(); try onGeneratedFiles?(files) }
    }

    private actor IdentityData {
        var data = Data()
        func append(_ chunk: Data) throws {
            guard chunk.count <= 64 * 1024 - data.count else { throw CopilotHTTPAdapter.Failure.responseTooLarge }
            data.append(chunk)
        }
    }
}
