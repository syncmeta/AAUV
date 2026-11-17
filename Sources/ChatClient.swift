import Foundation
import Network
import AAUVCore

struct ChatClient {
    struct Configuration {
        let baseURL: URL
        var model: String
        var key: String
        var apiProtocol: String = "responses"
        var hostedTools: [String] = []
        var instructions = ""
        var credentialKind = "byok"
        var generatedFileLimit = 32
        var generatedByteLimit = 32 * 1024 * 1024
    }

    enum AttachmentInput {
        case uploaded([String: String])
        case inline(RequestAttachment)
    }

    struct GeneratedFiles: Sendable {
        struct File: Sendable {
            let name: String
            let data: Data
        }

        var files: [File] = []
        var unavailable = 0
    }

    struct CompletedReply: Sendable {
        let text: String
        var citations: [WebCitation] = []
        var fileCount = 0
    }

    struct ServiceDiagnostic: Codable, Sendable {
        let status: Int
        let shape: String
        let code: String?
        let parameter: String?
        let requestID: String?
        let chatGPTPlan: Bool

        var usageLimited: Bool { chatGPTPlan && code == "subscription_sharing_usage_limit_exceeded" }

        var summary: String {
            if chatGPTPlan {
                switch code {
                case "subscription_sharing_usage_limit_exceeded":
                    return "此账户在 AAUV 的 ChatGPT 订阅用量受限。请查看 ChatGPT 用量后，在设置恢复请求。"
                case "subscription_sharing_user_not_eligible":
                    return "当前账户或工作区无法使用 ChatGPT 订阅推理。"
                case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
                    return "OpenAI 暂时无法核验 ChatGPT 用量或账户，请稍后重试。"
                case "subscription_sharing_unsupported_capability":
                    return "当前 ChatGPT 模型不支持这项请求能力。请检查模型、工具或附件后再发送。"
                case "subscription_sharing_route_not_supported":
                    return "OpenAI 拒绝了当前 ChatGPT 请求路径。"
                case "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
                    return "OpenAI 未接受此账户的订阅授权。请在设置核对所选账户和权限。"
                default:
                    if status == 401 { return "OpenAI 未接受当前 ChatGPT 授权。请核对账户和订阅权限。" }
                    if status == 403 { return "当前 ChatGPT 订阅请求受到服务商策略或权限限制。" }
                    if status == 503 { return "ChatGPT 订阅服务暂不可用，请稍后重试。" }
                }
            }
            if !(200..<300).contains(status) { return "模型服务返回 HTTP \(status)。" }
            if shape == "response.incomplete" { return "模型服务报告回复未完成。" }
            if shape == "response.cancelled" { return "模型服务取消了回复。" }
            return "模型服务未能完成回复。"
        }

        var supportDetails: String {
            (["HTTP \(status)"] + [code, parameter.map { "参数 \($0)" }, requestID.map { "请求编号 \($0)" }]
                .compactMap { $0 }).joined(separator: " · ")
        }
    }

    static func baseURL(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let host = components.host?.lowercased(), !host.isEmpty, !APIKey.isReservedHost(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme == "https" ||
                (components.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw ClientError.message("请输入 HTTPS API 地址。本机服务可使用 HTTP。") }
        components.scheme = components.scheme?.lowercased()
        components.host = host
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let url = components.url else { throw ClientError.message("API 地址无效。") }
        return url
    }

    static func reply(
        to messages: [ChatMessage], configuration: Configuration, proxy: ProxyConfiguration?,
        attachments: [AttachmentInput] = [],
        validateRoute: ProxyRouteCheck? = nil,
        validateCredential: AsyncCredentialCheck? = nil,
        willSend: (@MainActor () throws -> Void)? = nil,
        onDelta: (@MainActor (String) throws -> Void)? = nil,
        onTools: (@MainActor (Set<HostedTool>) -> Void)? = nil,
        onUsage: (@MainActor (UsageCounts) -> Void)? = nil,
        onReplyReady: (@MainActor (CompletedReply) throws -> Void)? = nil,
        onGeneratedFiles: (@MainActor (GeneratedFiles) throws -> Void)? = nil,
        localTools: [String] = [], continuation: Data? = nil, usedCallIDs: [String] = [],
        allowEmptyFinalReply: Bool = false,
        onResponseTurn: (@MainActor (ResponseToolLoop.Turn) throws -> Void)? = nil
    ) async throws -> String {
        guard localTools.isEmpty || onResponseTurn != nil else {
            throw ClientError.message("本机工具请求缺少结果处理器。")
        }
        var inline: [InlineRequestBody.File] = []
        let files = attachments.map { attachment in
            switch attachment {
            case .uploaded(let fields): return fields
            case .inline(let file):
                let part = InlineRequestBody.File(attachment: file)
                inline.append(part)
                return part.fields
            }
        }
        var input: [String: Any] = [
            "protocol": configuration.apiProtocol,
            "base_url": configuration.baseURL.absoluteString,
            "model": configuration.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "hosted_tools": configuration.hostedTools,
            "instructions": configuration.instructions,
            "files": files,
            "credential_kind": configuration.credentialKind
        ]
        if !localTools.isEmpty { input["local_tools"] = localTools }
        var encoded = try JSONSerialization.data(withJSONObject: input)
        if let continuation {
            // The Go builder validates the complete object and replay policy.
            // Embed the original array without coercing opaque JSON numbers.
            encoded.removeLast()
            encoded.append(Data(",\"continuation\":".utf8))
            encoded.append(continuation)
            encoded.append(125)
        }
        var coreError: NSError?
        let planJSON = AauvcoreBuildRequest(String(decoding: encoded, as: UTF8.self), &coreError)
        if let coreError { throw coreError }
        let plan = try JSONDecoder().decode(HTTPRequestPlan.self, from: Data(planJSON.utf8))
        guard let template = AauvcoreRequestPlanBody(planJSON, &coreError), coreError == nil else {
            throw coreError ?? ClientError.message("模型请求无效。")
        }
        var request = URLRequest(url: plan.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.key.isEmpty {
            request.setValue("Bearer " + configuration.key, forHTTPHeaderField: "Authorization")
        }
        let staged: InlineRequestBody?
        if inline.isEmpty {
            staged = nil
            request.httpBody = template
        } else {
            let file = try InlineRequestBody(template: template, files: inline)
            staged = file
            guard let stream = InputStream(url: file.url) else { throw CocoaError(.fileReadUnknown) }
            request.httpBodyStream = stream
            request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")
        }
        let generatingImages = configuration.hostedTools.contains(HostedTool.imageGeneration.rawValue)
        let session = session(proxy: proxy, resourceTimeout: generatingImages ? 900 : nil,
                              bodyFile: staged?.url, requestTimeout: generatingImages ? 180 : 60)
        defer {
            session.invalidateAndCancel()
            withExtendedLifetime(staged) {}
        }
        try Task.checkCancellation()
        try await validateCredential?()
        try Task.checkCancellation()
        if validateRoute != nil || willSend != nil {
            try await MainActor.run {
                try Task.checkCancellation()
                try validateRoute?()
                try willSend?()
            }
        }
        if plan.streaming {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            if !isSuccessful(response) {
                var errorBody = Data()
                for try await byte in bytes {
                    errorBody.append(byte)
                    if errorBody.count >= 8192 { break }
                }
                throw serviceError(response, body: errorBody, key: configuration.key,
                                   chatGPTPlan: configuration.credentialKind == "chatgpt_plan")
            }
            let parser: AauvcoreStream?
            if localTools.isEmpty {
                parser = AauvcoreNewStream()
            } else {
                let policy: [String: Any] = ["local_tools": localTools,
                                             "namespace": configuration.credentialKind == "chatgpt_plan" ? "aauv" : "",
                                             "used_call_ids": usedCallIDs]
                let policyData = try JSONSerialization.data(withJSONObject: policy)
                parser = AauvcoreNewStreamWithLocalTools(String(decoding: policyData, as: UTF8.self), &coreError)
            }
            if let coreError { throw coreError }
            guard let stream = parser else { throw ClientError.message("无法初始化响应解析器。") }
            func checkStreamError(_ error: NSError?) throws {
                guard let error else { return }
                guard let failure = try? JSONDecoder().decode(StreamFailure.self, from: Data(stream.failureDetails().utf8)) else {
                    throw ClientError.stream(error.localizedDescription)
                }
                throw ClientError.service(diagnostic(response, shape: failure.kind, code: failure.code, param: failure.param,
                                                     key: configuration.key, chatGPTPlan: configuration.credentialKind == "chatgpt_plan"), nil)
            }
            var chunk = Data()
            var runningTools: [String: HostedTool] = [:]
            readStream: for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if byte == 10 || chunk.count >= 8192 {
                    let events = stream.push(chunk, error: &coreError)
                    try checkStreamError(coreError)
                    chunk.removeAll(keepingCapacity: true)
                    if events != "[]" {
                        let updates = try JSONDecoder().decode([StreamUpdate].self, from: Data(events.utf8))
                        for update in updates {
                            if update.type == "completed" { break readStream }
                            if update.type == "delta", let text = update.text { try await onDelta?(text) }
                            if let onTools, update.type == "status", let status = update.status,
                               let tool = HostedTool(rawValue: status) {
                                let previous = Set(runningTools.values)
                                let key = status + "/" + (update.item_id ?? "")
                                if update.completed == true {
                                    runningTools.removeValue(forKey: key)
                                } else if runningTools.count < 256 {
                                    runningTools[key] = tool
                                }
                                let current = Set(runningTools.values)
                                if previous != current { await onTools(current) }
                            }
                        }
                    }
                }
            }
            if !chunk.isEmpty {
                _ = stream.push(chunk, error: &coreError)
                try checkStreamError(coreError)
            }
            let result = stream.finish(&coreError)
            try checkStreamError(coreError)
            // The complete response has arrived even if the HTTP connection stays open.
            bytes.task.cancel()
            if !runningTools.isEmpty { await onTools?([]) }
            let terminal = try JSONDecoder().decode(ReplyEnvelope.self, from: Data(result.utf8))
            if let usage = terminal.usage { await onUsage?(usage) }
            let text = terminal.text ?? ""
            let downloadsFiles = onGeneratedFiles != nil && configuration.credentialKind == "byok" &&
                (!terminal.files.isEmpty || !terminal.images.isEmpty)
            // Stream.finish has already required an explicit successful terminal.
            // The tool loop alone may authorize an empty final after retaining
            // actual files from a completed earlier round (never unavailable files).
            let attachmentOnlyFinal = allowEmptyFinalReply && configuration.apiProtocol == "responses" &&
                !localTools.isEmpty && onResponseTurn != nil
            guard !text.isEmpty || downloadsFiles || !terminal.functionCalls.isEmpty || attachmentOnlyFinal else {
                throw ClientError.message("服务商未返回文本。")
            }
            let completed = CompletedReply(text: text, citations: ResponseWebCitations.collect(from: terminal.output, matching: text),
                                           fileCount: downloadsFiles ? terminal.files.count + terminal.images.count : 0)
            if let onResponseTurn {
                let output = stream.completedOutput(&coreError)
                try checkStreamError(coreError)
                try await onResponseTurn(.init(reply: completed, outputJSON: Data(output.utf8), calls: terminal.functionCalls))
            }
            try await onReplyReady?(completed)
            if downloadsFiles, let onGeneratedFiles {
                let generated = await downloadGeneratedFiles(terminal.files, images: terminal.images,
                                                             configuration: configuration, proxy: proxy,
                                                             validateRoute: validateRoute, validateCredential: validateCredential)
                try await onGeneratedFiles(generated)
            }
            return text
        }
        let (data, response) = try await session.data(for: request)
        if !isSuccessful(response) {
            throw serviceError(response, body: data.prefix(8192), key: configuration.key,
                               chatGPTPlan: configuration.credentialKind == "chatgpt_plan")
        }
        if let onUsage, let usage = try? JSONDecoder().decode(ReplyEnvelope.self, from: data).usage {
            await onUsage(usage)
        }
        let text = AauvcoreDecodeCompletion(String(decoding: data, as: UTF8.self), &coreError)
        if let coreError { throw coreError }
        guard !text.isEmpty else { throw ClientError.message("服务商未返回文本。") }
        try await onReplyReady?(.init(text: text))
        return text
    }

    private struct HTTPRequestPlan: Decodable {
        let url: URL
        let streaming: Bool
    }

    private struct ReplyEnvelope: Decodable {
        let text: String?
        let usage: UsageCounts?
        let files: [ContainerFile]
        let output: [ResponseWebCitations.Item]
        let images: [ResponseGeneratedImages.OutputItem]
        let functionCalls: [LocalToolCall]

        private enum CodingKeys: String, CodingKey { case text, usage, files, output, functionCalls = "function_calls" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decodeIfPresent(String.self, forKey: .text)
            usage = try? values.decode(UsageCounts.self, forKey: .usage)
            files = (try? values.decode([ContainerFile].self, forKey: .files)) ?? []
            output = (try? values.decode([ResponseWebCitations.Item].self, forKey: .output)) ?? []
            images = ((try? values.decode([ResponseGeneratedImages.OutputItem].self, forKey: .output)) ?? [])
                .filter { $0.type == "image_generation_call" }
            functionCalls = try values.decodeIfPresent([LocalToolCall].self, forKey: .functionCalls) ?? []
        }
    }

    private struct ContainerFile: Decodable {
        let container_id: String
        let file_id: String
        let filename: String
    }

    static func session(proxy: ProxyConfiguration?, resourceTimeout: TimeInterval? = nil, bodyFile: URL? = nil,
                        requestTimeout: TimeInterval = 60) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = requestTimeout
        if let resourceTimeout { config.timeoutIntervalForResource = resourceTimeout }
        if let proxy { config.proxyConfigurations = [proxy] }
        let delegate: NoRedirects = bodyFile.map { FileBodyDelegate(url: $0) } ?? NoRedirects()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private static func downloadGeneratedFiles(
        _ files: [ContainerFile], images: [ResponseGeneratedImages.OutputItem],
        configuration: Configuration, proxy: ProxyConfiguration?, validateRoute: ProxyRouteCheck?,
        validateCredential: AsyncCredentialCheck?
    ) async -> GeneratedFiles {
        let session = session(proxy: proxy, resourceTimeout: 20)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        var remaining = max(0, min(configuration.generatedByteLimit, 32 * 1024 * 1024))
        let fileLimit = max(0, min(configuration.generatedFileLimit, 32))
        var result = GeneratedFiles()
        if !images.isEmpty {
            do {
                try await validateCredential?()
                try Task.checkCancellation()
                try await validateRoute?()
                let byteLimit = remaining
                let processing = Task.detached(priority: .userInitiated) {
                    ResponseGeneratedImages.decode(images, maximumBytes: byteLimit, maximumCount: fileLimit)
                }
                let decoded = await withTaskCancellationHandler {
                    await processing.value
                } onCancel: {
                    processing.cancel()
                }
                result.files = decoded.files
                remaining -= decoded.files.reduce(0) { $0 + $1.data.count }
            } catch {
                return .init(unavailable: files.count + images.count)
            }
        }
        for file in files.prefix(fileLimit - result.files.count) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
            do {
                try await validateCredential?()
                try Task.checkCancellation()
                try await validateRoute?()
            }
            catch { break }
            let url = configuration.baseURL
                .appending(component: "containers")
                .appending(component: file.container_id)
                .appending(component: "files")
                .appending(component: file.file_id)
                .appending(component: "content")
            var request = URLRequest(url: url)
            if !configuration.key.isEmpty {
                request.setValue("Bearer " + configuration.key, forHTTPHeaderField: "Authorization")
            }
            if let data = try? await download(request, session: session, limit: remaining) {
                remaining -= data.count
                result.files.append(.init(name: file.filename, data: data))
            }
        }
        result.unavailable = files.count + images.count - result.files.count
        return result
    }

    private static func download(_ request: URLRequest, session: URLSession, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw ClientError.message("无法获取完整的生成文件。")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else {
                bytes.task.cancel()
                throw ClientError.message("生成文件超过下载限制。")
            }
            data.append(byte)
        }
        return data
    }

    private struct StreamUpdate: Decodable {
        let type: String
        let text: String?
        let status: String?
        let item_id: String?
        let completed: Bool?
    }

    private struct StreamFailure: Decodable {
        let kind: String
        let code: String?
        let param: String?
    }

    static func isSuccessful(_ response: URLResponse) -> Bool {
        (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func serviceError(_ response: URLResponse, body: Data, key: String, chatGPTPlan: Bool = false) -> ClientError {
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = payload?["error"] as? [String: Any]
        let detail = error?["message"] as? String ?? payload?["detail"] as? String
        let redacted = key.isEmpty ? detail : detail?.replacingOccurrences(of: key, with: "•••")
        let shape = error != nil ? "error" : payload?["detail"] != nil ? "detail" : "unknown"
        return .service(diagnostic(response, shape: shape, code: error?["code"] as? String, param: error?["param"] as? String,
                                   key: key, chatGPTPlan: chatGPTPlan), redacted.map { String($0.prefix(500)) })
    }

    private static func diagnostic(_ response: URLResponse, shape: String, code: String?, param: String?,
                                   key: String, chatGPTPlan: Bool) -> ServiceDiagnostic {
        let http = response as? HTTPURLResponse
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-[]")
        func identifier(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 256,
                  value.unicodeScalars.allSatisfy(allowed.contains), key.isEmpty || !value.contains(key) else { return nil }
            return value
        }
        return ServiceDiagnostic(status: http?.statusCode ?? 0, shape: shape, code: identifier(code),
                                 parameter: identifier(param), requestID: identifier(http?.value(forHTTPHeaderField: "x-request-id")),
                                 chatGPTPlan: chatGPTPlan)
    }

    class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private final class FileBodyDelegate: NoRedirects, @unchecked Sendable {
        private let url: URL

        init(url: URL) { self.url = url }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
            completionHandler(InputStream(url: url))
        }
    }

    enum ClientError: LocalizedError {
        case message(String)
        case service(ServiceDiagnostic, String?)
        case stream(String)
        var errorDescription: String? {
            switch self {
            case .message(let message): message
            case .service(let diagnostic, let detail):
                ([diagnostic.summary, diagnostic.supportDetails] + [detail].compactMap { $0 }).joined(separator: "\n")
            case .stream(let code):
                switch code {
                case "stream_ended_without_completion", "truncated_stream_event":
                    "连接已中断，回复没有完整接收。可以重新请求。"
                case "event_too_large", "response_too_large":
                    "模型服务返回的数据超过本机处理上限。请缩小请求后重试。"
                case "client_tool_execution_disabled":
                    "模型服务要求客户端执行工具。请改用服务商托管的工具后重试。"
                case "provider_response_failed", "provider_response_incomplete":
                    "模型服务未能完成回复。可以重新请求。"
                default:
                    "模型服务返回了无法识别的回复。请核对 API 协议后重试。"
                }
            }
        }
    }
}
