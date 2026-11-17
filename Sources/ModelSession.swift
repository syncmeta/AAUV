import Foundation
import Network

typealias AsyncCredentialCheck = @MainActor @Sendable () async throws -> Void

struct ModelSession {
    private enum Provider {
        case http(ChatClient.Configuration, chatGPTRegistration: String? = nil,
                  validateCredential: ProxyRouteCheck? = nil)
        case copilot(model: String, instructions: String, authorization: CopilotSession, proxyURL: URL?)
        case copilotHTTP(session: CopilotPreviewSession, model: String, instructions: String)
    }

    private let provider: Provider
    private let route: ProxyRequestRoute
    private let conversationToolsAllowed: Bool

    // Shared by the ordinary Workspace and its headless regression. Unsupported
    // protocols do not construct tool execution or its side-effecting context.
    @MainActor func prepareConversationTools<T>(enabled: Bool, make: () throws -> T) throws -> T? {
        try validateSelection()
        guard enabled, conversationToolsAllowed else { return nil }
        return try make()
    }

    @MainActor func validateSelection() throws {
        try route.validate()
        switch provider {
        case .http(_, let registration, let validateCredential):
            try validateCredential?()
            if let registration { try ChatGPTPlanSession.requireNotSigningOut(registration) }
        case .copilot(_, _, let authorization, _): try authorization.validate()
        case .copilotHTTP(let session, _, _): try session.validate()
        }
    }

    @MainActor init(
        bot: BotSnapshot, instructions: String, proxy: SingBox, localToolInstructions: String = "",
        captureCopilotHTTP: @escaping @MainActor (ProxyRequestRoute) async throws -> CopilotPreviewSession = {
            try await CopilotPreviewSession.capture(authorization: CopilotSession(), route: $0)
        },
        readBYOK: (URL, @escaping ProxyRouteCheck) async throws -> RequestCredentials = {
            try await RequestCredentials.read(for: $0, validateRoute: $1)
        }
    ) async throws {
        let model = bot.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = try proxy.requestRoute()
        self.route = route
        func requestInstructions(toolsAllowed: Bool) -> String {
            [instructions, toolsAllowed ? localToolInstructions : ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        if bot.loginMethod != .copilot && model.isEmpty {
            throw ChatClient.ClientError.message("请先在设置填写模型名称。")
        }
        switch bot.loginMethod {
        case .byok:
            let base = try ChatClient.baseURL(bot.endpoint)
            let credentials = try await readBYOK(base, route.validate)
            try Task.checkCancellation()
            try route.validate()
            try credentials.validate()
            let toolsAllowed = (bot.apiProtocol ?? "chat_completions") == "responses"
            conversationToolsAllowed = toolsAllowed
            provider = .http(.init(baseURL: base, model: model, key: credentials.key,
                                   apiProtocol: bot.apiProtocol ?? "chat_completions",
                                   hostedTools: (bot.apiProtocol == "responses" ? bot.hostedTools : nil) ?? [],
                                   instructions: requestInstructions(toolsAllowed: toolsAllowed)), validateCredential: credentials.validate)
        case .chatgpt:
            guard let registrationID = bot.chatGPTClientID, !registrationID.isEmpty else {
                throw ChatClient.ClientError.message("此会话尚未绑定 ChatGPT 账户。请在『更换机器人』中确认要使用的账户。")
            }
            let toolsAllowed = true
            conversationToolsAllowed = toolsAllowed
            provider = .http(.init(baseURL: ChatGPTPlanSession.endpoint, model: model, key: "",
                                   hostedTools: HostedTool.supported(bot.hostedTools ?? [], by: .chatgpt),
                                   instructions: requestInstructions(toolsAllowed: toolsAllowed), credentialKind: "chatgpt_plan"),
                             chatGPTRegistration: registrationID)
        case .copilot:
            #if os(macOS) && !AAUV_COPILOT_IOS_FIXTURES
            guard CopilotClient.available else { throw ChatClient.ClientError.message(CopilotClient.unavailableMessage) }
            let address = try proxy.copilotProxyURL()
            let toolsAllowed = true
            conversationToolsAllowed = toolsAllowed
            provider = .copilot(model: model, instructions: requestInstructions(toolsAllowed: toolsAllowed), authorization: CopilotSession(), proxyURL: address)
            #else
            let session = try await captureCopilotHTTP(route)
            let selected = try session.selectedModel(model)
            let toolsAllowed = try session.supportsConversationTools(model: selected)
            conversationToolsAllowed = toolsAllowed
            provider = .copilotHTTP(session: session, model: selected,
                                    instructions: requestInstructions(toolsAllowed: toolsAllowed))
            #endif
        }
    }

    /// `validateContext` currently guards Copilot HTTP preview requests only.
    /// Other providers keep their existing route, credential, local-tool and
    /// willSend checks; callers must not use this as a provider-neutral guard.
    func reply(
        to messages: [ChatMessage], forSummary: Bool = false, files: [RequestAttachment] = [],
        localExecution: LocalToolExecution? = nil, modelOverride: String? = nil,
        validateContext: ProxyRouteCheck? = nil,
        willSend: (@MainActor () throws -> Void)? = nil,
        onDelta: (@MainActor (String) throws -> Void)? = nil,
        onTools: (@MainActor (Set<HostedTool>) -> Void)? = nil,
        onLocalTool: (@MainActor (String?) -> Void)? = nil,
        onUsage: (@MainActor (UsageCounts) -> Void)? = nil,
        onReplyReady: (@MainActor (ChatClient.CompletedReply) throws -> Void)? = nil,
        onGeneratedFiles: (@MainActor (ChatClient.GeneratedFiles) throws -> Void)? = nil,
        onCleanupFailure: (@MainActor (Int) -> Void)? = nil
    ) async throws -> String {
        if let modelOverride {
            guard forSummary, !modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  modelOverride.utf8.count <= 2048 else {
                throw ChatClient.ClientError.message("委托模型配置无效。")
            }
        }
        try await route.validate()
        switch provider {
        case .http(var configuration, let registration, let validateCredential):
            if let modelOverride {
                configuration.model = modelOverride
            }
            try await validateCredential?()
            if let registration {
                try await ChatGPTPlanSession.requireUsageAvailable(registration)
                configuration.key = try await ChatGPTPlanSession.token(proxy: route.configuration, clientID: registration,
                                                                       validateRoute: route.validate)
            }
            if forSummary {
                configuration.hostedTools = []
                configuration.instructions = ""
            }
            let requestConfiguration = configuration
            let validateRequest: ProxyRouteCheck = {
                try route.validate()
                try validateCredential?()
                if !forSummary { try localExecution?.validate() }
                if let registration {
                    try ChatGPTPlanSession.requireUsageAvailable(registration)
                    try ChatGPTPlanSession.requireNotSigningOut(registration)
                }
            }
            let submitRequest: @MainActor () throws -> Void = {
                try validateRequest()
                try willSend?()
                // The callback can synchronously change configuration or scope.
                // Recheck on the same actor before ChatClient submits its HTTP request.
                try validateRequest()
            }
            let validateAuthorization: AsyncCredentialCheck?
            if let registration {
                let token = requestConfiguration.key
                validateAuthorization = {
                    try await ChatGPTPlanSession.validateTokenForRequest(token, for: registration)
                    try validateRequest()
                }
            } else {
                validateAuthorization = nil
            }
            do {
                let perform = {
                    try await ChatClient.withRequestFiles(files, configuration: requestConfiguration, proxy: route.configuration,
                                                          validateRoute: validateRequest,
                                                          validateCredential: validateAuthorization,
                                                          onCleanupFailure: onCleanupFailure) { attachments in
                        if let execution = localExecution, !forSummary, requestConfiguration.apiProtocol == "responses" {
                            return try await ResponseToolLoop.run(execution: execution, send: { state in
                                var current = requestConfiguration
                                if let registration {
                                    current.key = try await ChatGPTPlanSession.token(proxy: route.configuration, clientID: registration,
                                                                                     validateRoute: validateRequest)
                                }
                                current.generatedFileLimit = state.remainingFileCount
                                current.generatedByteLimit = state.remainingFileBytes
                                let roundCheck: AsyncCredentialCheck?
                                if let registration {
                                    let token = current.key
                                    roundCheck = {
                                        try await ChatGPTPlanSession.validateTokenForRequest(token, for: registration)
                                        try validateRequest()
                                    }
                                } else { roundCheck = validateAuthorization }
                                var turn: ResponseToolLoop.Turn?
                                var generated = ChatClient.GeneratedFiles()
                                _ = try await ChatClient.reply(
                                    to: messages, configuration: current, proxy: route.configuration, attachments: attachments,
                                    validateRoute: validateRequest, validateCredential: roundCheck, willSend: submitRequest,
                                    onDelta: onDelta, onTools: onTools, onUsage: onUsage,
                                    onGeneratedFiles: { generated = $0 }, localTools: execution.names,
                                    continuation: state.continuation, usedCallIDs: state.usedCallIDs,
                                    allowEmptyFinalReply: state.allowEmptyFinalReply,
                                    onResponseTurn: { turn = $0 })
                                try route.validate()
                                try execution.validate()
                                guard var completed = turn else {
                                    throw ChatClient.ClientError.message("模型未返回完整工具回合。")
                                }
                                completed.generated = generated
                                return completed
                            }, onDelta: onDelta, onLocalTool: onLocalTool,
                               onReplyReady: onReplyReady, onGeneratedFiles: onGeneratedFiles)
                        }
                        return try await ChatClient.reply(to: messages, configuration: requestConfiguration, proxy: route.configuration,
                                                   attachments: attachments, validateRoute: validateRequest,
                                                   validateCredential: validateAuthorization,
                                                   willSend: submitRequest, onDelta: onDelta, onTools: onTools,
                                                   onUsage: onUsage, onReplyReady: onReplyReady, onGeneratedFiles: onGeneratedFiles)
                    }
                }
                if let registration { return try await ChatGPTPlanSession.withRequest(registration, perform: perform) }
                return try await perform()
            } catch let error as ChatClient.ClientError {
                if let registration, case .service(let diagnostic, _) = error, diagnostic.usageLimited {
                    await ChatGPTPlanSession.setUsagePaused(true, for: registration)
                }
                throw error
            }
        case .copilotHTTP(let session, let model, let instructions):
            return try await session.reply(to: messages, model: modelOverride ?? model, instructions: instructions,
                                           forSummary: forSummary, files: files, localExecution: localExecution,
                                           validateContext: validateContext, willSend: willSend, onDelta: onDelta, onLocalTool: onLocalTool,
                                           onUsage: onUsage, onReplyReady: onReplyReady, onGeneratedFiles: onGeneratedFiles)
        case .copilot(let model, let instructions, let authorization, let proxyURL):
            return try await authorization.withRequest {
                let token = try await authorization.token(proxy: route.configuration, validateRoute: route.validate)
                let execution = forSummary ? nil : localExecution
                var partial = ""
                var deliveryStarted = false
                do {
                    let text = try await CopilotClient.reply(
                    to: messages, model: modelOverride ?? model, instructions: forSummary ? "" : instructions,
                    token: token, proxyURL: proxyURL, files: files,
                    localExecution: execution, onLocalTool: onLocalTool, validate: {
                        try route.validate()
                        try authorization.validate()
                    }, willSend: willSend, onDelta: { delta in
                        partial += delta
                        try onDelta?(delta)
                    }, onUsage: onUsage)
                // Complete on the same actor/intent as stream events, so a
                // logout between the bridge reply and delivery cannot commit it.
                try Task.checkCancellation()
                try route.validate()
                try authorization.validate()
                try execution?.validate()
                let generated = execution?.drainGenerated() ?? .init()
                deliveryStarted = true
                try onReplyReady?(.init(text: text, fileCount: generated.files.count + generated.unavailable))
                if !generated.files.isEmpty || generated.unavailable != 0 { try onGeneratedFiles?(generated) }
                return text
                } catch {
                    // Already prepared images survive manual cancellation, but
                    // an account/route/chat change invalidates their destination.
                    if !deliveryStarted, let execution {
                        try route.validate()
                        try execution.validate()
                        let generated = execution.drainGenerated()
                        if !generated.files.isEmpty {
                            deliveryStarted = true
                            try onReplyReady?(.init(text: partial, fileCount: generated.files.count + generated.unavailable))
                            try onGeneratedFiles?(generated)
                        }
                    }
                    throw error
                }
            }
        }
    }
}
