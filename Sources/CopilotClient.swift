import AAUVCore
import Foundation
import Network

@MainActor
struct CopilotSession {
    private struct Renewal: Hashable {
        let revision: String
        let accessToken: String
    }

    private static var renewals: [Renewal: Task<String, Error>] = [:]
    // Native CAS need not change imported-vault/login revisions. HTTP preview
    // pins this epoch so a peer rotation cannot slip between fresh-read/resume.
    private(set) static var httpTokenGeneration = UUID()
    private static var requests: [UUID: () -> Void] = [:]
    private static var signingOut = false
    private let defaults: UserDefaults
    private let revision: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        revision = Self.currentRevision(defaults: defaults)
    }

    private static func currentRevision(defaults: UserDefaults) -> String {
        defaults.string(forKey: APIKey.copilotRevisionKey) ?? ""
    }

    func validate() throws {
        try Task.checkCancellation()
        try validateState()
    }

    // Completion cleanup may preserve already prepared local files after a
    // manual cancellation, while logout/configuration changes still reject it.
    func validateState() throws {
        guard revision == Self.currentRevision(defaults: defaults) else {
            throw ChatClient.ClientError.message("GitHub Copilot 授权已更换，请重试。")
        }
        try APIKey.requireCopilotActive(defaults: defaults)
    }

    func withRequest<Value: Sendable>(perform: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try validate()
        let id = UUID()
        let task = Task { try validate(); return try await perform() }
        Self.requests[id] = { task.cancel() }
        defer { Self.requests.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try validate()
        return result
    }

    static func signOut(
        defaults: UserDefaults = .standard,
        read: @escaping @Sendable () throws -> APIKey.CopilotSignOutSnapshot = { try APIKey.copilotSignOutSnapshot() },
        acquireLease: @escaping @MainActor () async throws -> CredentialRefreshLease = {
            try await CredentialRefreshLease.acquire()
        },
        clear: @escaping @MainActor (APIKey.CopilotSignOutSnapshot) throws -> Void = { try APIKey.clearCopilotSignOut($0) }
    ) async throws {
        guard !signingOut else { throw ChatClient.ClientError.message("GitHub Copilot 正在本机退出。") }
        signingOut = true
        defer { signingOut = false }
        let endingRevision = APIKey.beginCopilotSignOut(defaults: defaults)
        for cancel in requests.values { cancel() }
        guard defaults.synchronize() else {
            throw ChatClient.ClientError.message("暂时无法保存 Copilot 本机退出状态，请重试。")
        }
        // A provider exchange already sent is allowed to finish. Its revision
        // check rejects a late save, and no new renewal may enter while blocked.
        let running = Array(renewals.values)
        for renewal in running { _ = try? await renewal.value }
        try Task.checkCancellation()
        let lease = try await acquireLease()
        defer { lease.release() }
        let vaultRevision = defaults.string(forKey: APIKey.revisionKey)
        let snapshot = try await APIKey.readInBackground(read)
        try Task.checkCancellation()
        guard defaults.bool(forKey: APIKey.copilotSignOutPendingKey),
              defaults.string(forKey: APIKey.copilotRevisionKey) == endingRevision,
              defaults.string(forKey: APIKey.revisionKey) == vaultRevision else {
            throw ChatClient.ClientError.message("退出期间本机凭证已更换，请重试。")
        }
        // Keep this CAS and all deletion writes together on MainActor. A failed
        // write deliberately retains the pending flag, including across restart.
        try clear(snapshot)
        APIKey.finishCopilotSignOut(defaults: defaults)
    }

    func models(proxy: SingBox, selectedModel: String? = nil,
                captureHTTP: CopilotPreviewSession.Capture? = nil) async throws -> [CopilotClient.Model] {
        #if os(macOS) && !AAUV_COPILOT_IOS_FIXTURES
        let route = try proxy.requestRoute()
        let proxyURL = try proxy.copilotProxyURL()
        let token = try await token(proxy: route.configuration, validateRoute: route.validate)
        let models = try await withRequest {
            try await CopilotClient.models(token: token, proxyURL: proxyURL, validateRoute: {
                try route.validate()
                try validate()
            })
        }
        try route.validate()
        try validate()
        return models
        #else
        let route = try proxy.requestRoute()
        let preview: CopilotPreviewSession
        if let captureHTTP { preview = try await captureHTTP(self, route) }
        else { preview = try await CopilotPreviewSession.capture(authorization: self, route: route, defaults: defaults) }
        return try preview.models(selectedModel: selectedModel)
        #endif
    }

    func token(
        proxy: ProxyConfiguration?, validateRoute: ProxyRouteCheck? = nil,
        read: @escaping @Sendable () throws -> OAuthCredentials? = { try APIKey.copilotCredentials() },
        renew: (@MainActor (OAuthCredentials) async throws -> OAuthCredentials)? = nil,
        acquireRenewalLease: @escaping @MainActor () async throws -> CredentialRefreshLease = {
            try await CredentialRefreshLease.acquire()
        },
        replace: @escaping @MainActor (OAuthCredentials, OAuthCredentials) throws -> Void = {
            try APIKey.replaceCopilot($0, with: $1)
        }
    ) async throws -> String {
        try validate()
        try validateRoute?()
        let captured = try await APIKey.readInBackground(read)
        try validate()
        try validateRoute?()
        guard let credentials = captured else {
            throw ChatClient.ClientError.message("请先通过 GitHub Copilot 登录，或导入已授权的凭证。")
        }
        try credentials.validateStructure()
        guard ["gho_", "ghu_", "github_pat_"].contains(where: credentials.accessToken.hasPrefix) else {
            throw ChatClient.ClientError.message("当前 GitHub 凭证类型不受 Copilot SDK 支持。")
        }
        let renewalLeadTime: TimeInterval = credentials.refreshToken == nil ? 0 : 60
        guard let expiry = credentials.expiresAt, expiry <= Date().timeIntervalSince1970 + renewalLeadTime else {
            return credentials.accessToken
        }
        let key = Renewal(revision: revision, accessToken: credentials.accessToken)
        let token: String
        if let renewal = Self.renewals[key] {
            token = try await renewal.value
        } else {
            let task = Task {
                let lease = try await acquireRenewalLease()
                defer { lease.release() }
                let current = try await APIKey.readInBackground(read)
                try validate()
                try validateRoute?()
                guard let current, current.flow == credentials.flow,
                      current.clientID == credentials.clientID,
                      current.accessToken == credentials.accessToken,
                      current.refreshToken == credentials.refreshToken else {
                    throw ChatClient.ClientError.message("续期前 GitHub Copilot 凭证已更换，请重试。")
                }
                let updated: OAuthCredentials
                if let renew {
                    updated = try await renew(credentials)
                } else {
                    let authorization = GitHubDeviceAuthorization(proxy: proxy, validateRoute: {
                        try validateRoute?()
                        try validate()
                    })
                    updated = try await authorization.refresh(credentials)
                }
                try validate()
                // Keep compare-and-replace on the main actor with the other
                // credential writes; moving only this write would race login.
                try replace(credentials, updated)
                Self.httpTokenGeneration = UUID()
                return updated.accessToken
            }
            Self.renewals[key] = task
            defer { Self.renewals[key] = nil }
            token = try await task.value
        }
        try validate()
        try validateRoute?()
        return token
    }
}

enum CopilotClient {
    static var available: Bool {
        #if os(macOS) && !AAUV_COPILOT_IOS_FIXTURES
        executables() != nil
        #elseif os(iOS) || AAUV_COPILOT_IOS_FIXTURES
        true
        #else
        false
        #endif
    }

    static var unavailableMessage: String {
        #if os(macOS)
        "此构建缺少 GitHub Copilot 运行时。"
        #else
        "此调用缺少固定账户的 Copilot 直连会话，请重新检查访问权限。"
        #endif
    }

    struct Model: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let allowed: Bool
    }

    static func models(token: String, proxyURL: URL?, validateRoute: ProxyRouteCheck? = nil) async throws -> [Model] {
        #if os(macOS)
        var result: [Model]?
        try await invoke([
            "operation": "list_models", "token": token, "proxy": proxyURL?.absoluteString ?? ""
        ], failure: "无法读取 GitHub Copilot 模型目录，请检查授权和网络。", validate: validateRoute) { event in
            guard event.type == "models", result == nil else { throw CocoaError(.fileReadCorruptFile) }
            result = event.models ?? []
        }
        guard let result else { throw ChatClient.ClientError.message("GitHub Copilot 未返回模型目录。") }
        return result
        #else
        throw ChatClient.ClientError.message(unavailableMessage)
        #endif
    }

    static func reply(
        to messages: [ChatMessage], model: String, instructions: String, token: String, proxyURL: URL?,
        files: [RequestAttachment] = [],
        localExecution: LocalToolExecution? = nil,
        onLocalTool: (@MainActor (String?) -> Void)? = nil,
        validate: ProxyRouteCheck? = nil,
        willSend: (@MainActor () throws -> Void)? = nil,
        onDelta: (@MainActor (String) throws -> Void)? = nil,
        onUsage: (@MainActor (UsageCounts) -> Void)? = nil
    ) async throws -> String {
        #if os(macOS)
        var payload: [String: Any] = [
            "token": token,
            "model": model,
            "instructions": instructions,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "files": files.map { [
                "name": $0.name, "media_type": $0.mediaType, "path": $0.url.path, "size": $0.size
            ] as [String: Any] },
            "proxy": proxyURL?.absoluteString ?? ""
        ]
        if let localExecution {
            guard !localExecution.names.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            var error: NSError?
            let names = try JSONEncoder().encode(localExecution.names)
            let definitions = AauvcoreLocalToolDefinitionsJSON(String(decoding: names, as: UTF8.self), &error)
            if let error { throw error }
            guard let data = definitions.data(using: .utf8),
                  let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  tools.count == localExecution.names.count else { throw CocoaError(.fileReadCorruptFile) }
            payload["bridge_protocol"] = 2
            payload["request_id"] = UUID().uuidString
            payload["local_tools"] = tools
        }
        var text: String?
        try await invoke(payload, failure: "GitHub Copilot 请求失败，请检查授权、模型和网络。",
                         validate: validate, willSend: willSend, localExecution: localExecution,
                         onLocalTool: onLocalTool) { event in
            switch event.type {
            case "delta": if let delta = event.text { try onDelta?(delta) }
            case "usage": if let counts = event.usage { onUsage?(counts) }
            case "completed": text = event.text
            default: throw CocoaError(.fileReadCorruptFile)
            }
        }
        guard let text else {
            throw ChatClient.ClientError.message("GitHub Copilot 请求中断，未收到完整回复。")
        }
        try await MainActor.run {
            try localExecution?.validate()
            guard !text.isEmpty || localExecution?.hasGeneratedFiles() == true else {
                throw ChatClient.ClientError.message("GitHub Copilot 请求中断，未收到完整回复。")
            }
        }
        return text
        #else
        throw ChatClient.ClientError.message(unavailableMessage)
        #endif
    }

    #if os(macOS)
    @MainActor private static func invoke(_ payload: [String: Any], failure: String, validate: ProxyRouteCheck?,
                               willSend: (@MainActor () throws -> Void)? = nil,
                               localExecution: LocalToolExecution? = nil,
                               onLocalTool: (@MainActor (String?) -> Void)? = nil,
                               receive: @MainActor (BridgeEvent) throws -> Void) async throws {
        guard let (bridge, runtime) = executables() else { throw ChatClient.ClientError.message(unavailableMessage) }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        var length = UInt32(data.count).bigEndian
        var initialFrame = withUnsafeBytes(of: &length) { Data($0) }
        initialFrame.append(data)
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = bridge
        process.arguments = [runtime.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let io = CopilotProcessIO(process: process, reader: output.fileHandleForReading, writer: input.fileHandleForWriting)
        let writer = CopilotPipeWriter(input.fileHandleForWriting)
        let requestID = payload["request_id"] as? String
        let dispatcher = localExecution.flatMap { execution in requestID.map {
            CopilotToolDispatcher(requestID: $0, execution: execution, validate: validate,
                                  writer: writer, io: io, onLocalTool: onLocalTool)
        } }
        try Task.checkCancellation()
        try process.run()
        defer { dispatcher?.cancelAll(); io.stop() }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await writer.write(initialFrame)
                var ready = false
                var submitted = false
                var completed = false
                var line = Data()
                @MainActor func deliver(_ data: Data) throws {
                    try Task.checkCancellation()
                    if let error = dispatcher?.failure { throw error }
                    let event = try JSONDecoder().decode(BridgeEvent.self, from: data)
                    if event.type == "failed" {
                        throw ChatClient.ClientError.message(event.code == "not_authenticated"
                            ? "GitHub Copilot 运行时未接受当前授权，请重新登录。" : failure)
                    }
                    if (event.type == "ready" && !ready) || (event.type == "submit" && ready && !submitted) {
                        guard event.bridgeProtocol == (requestID == nil ? nil : 2), event.requestID == requestID else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        try validate?()
                        try localExecution?.validate()
                        if event.type == "submit" { try willSend?() }
                        // ACKs precede all tool frames, so this small actor-local
                        // write keeps the validation and permission together.
                        try io.writer.write(contentsOf: Data([1]))
                        ready = true
                        submitted = event.type == "submit"
                        return
                    }
                    guard submitted, !completed, event.type != "ready", event.type != "submit" else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try validate?()
                    try localExecution?.validate()
                    switch event.type {
                    case "tool_call":
                        guard let dispatcher, event.requestID == requestID, let id = event.callID,
                              let name = event.name, let arguments = event.arguments else { throw CocoaError(.fileReadCorruptFile) }
                        try dispatcher.call(id: id, name: name, arguments: arguments)
                    case "tool_cancel":
                        guard let dispatcher, event.requestID == requestID, let id = event.callID else { throw CocoaError(.fileReadCorruptFile) }
                        try dispatcher.cancel(id: id)
                    default:
                        if event.type == "completed" || event.type == "models" { completed = true }
                        try receive(event)
                    }
                }
                for try await byte in io.reader.bytes {
                    try Task.checkCancellation()
                    if byte == 10 {
                        try deliver(line)
                        line.removeAll(keepingCapacity: true)
                    } else {
                        guard line.count < 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        line.append(byte)
                    }
                }
                guard line.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                try await dispatcher?.finish()
                io.closeInput()
                let status = await io.wait()
                try Task.checkCancellation()
                guard submitted, completed, status == 0 else { throw ChatClient.ClientError.message(failure) }
            } catch {
                dispatcher?.cancelAll()
                io.stop()
                _ = await io.wait()
                try Task.checkCancellation()
                if let error = dispatcher?.failure { throw error }
                throw error
            }
        } onCancel: { io.stop() }
    }

    private static func executables() -> (URL, URL)? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent()
            .appending(path: "Copilot-\(arch)") else { return nil }
        let bridge = directory.appending(path: "bridge")
        let runtime = directory.appending(path: "copilot-runtime")
        guard FileManager.default.isExecutableFile(atPath: bridge.path),
              FileManager.default.isExecutableFile(atPath: runtime.path),
              FileManager.default.isReadableFile(atPath: directory.appending(path: "runtime.node").path) else { return nil }
        return (bridge, runtime)
    }

    private struct BridgeEvent: Decodable {
        let type: String
        let bridgeProtocol: Int?
        let requestID: String?
        let callID: String?
        let name: String?
        let arguments: [String: CopilotJSONValue]?
        let text: String?
        let usage: UsageCounts?
        let models: [Model]?
        let code: String?
        enum CodingKeys: String, CodingKey {
            case type, text, usage, models, code, name, arguments
            case bridgeProtocol = "bridge_protocol", requestID = "request_id", callID = "call_id"
        }
    }
    #endif
}
