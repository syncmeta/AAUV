import Foundation

/// Two conversation-scoped cloud helpers. The host must send exactly the supplied
/// prompt/files as one isolated user request, with all tools/history disabled,
/// record usage itself, and resolve modelOverride through the host's captured
/// local routes. Model input must never supply an endpoint or credentials.
@MainActor
struct LocalCloudTools {
    typealias CloudRequest = @MainActor @Sendable (_ prompt: String, _ files: [RequestAttachment], _ modelOverride: String?) async throws -> String
    typealias PrepareAttachment = @MainActor @Sendable (Attachment) throws -> RequestAttachment
    typealias ValidateScope = @MainActor @Sendable () throws -> Void

    /// Also usable by the injected request closure. Errors thrown directly by
    /// validateScope always propagate unchanged, whatever their concrete type.
    enum ScopeError: Error, Equatable { case staleScope }

    struct Limits: Sendable {
        var timeout: Duration = .seconds(300)
        var resultBytes: Int = 4 * 1024 * 1024
    }

    let attachments: [Attachment]
    let prepareAttachment: PrepareAttachment
    let cloud: CloudRequest
    let validateScope: ValidateScope
    var limits = Limits()

    func perform(_ call: LocalToolCall) async throws -> String {
        try Task.checkCancellation()
        try validateScope()
        guard limits.timeout > .zero, limits.timeout <= .seconds(300),
              (256...(4 * 1024 * 1024)).contains(limits.resultBytes) else {
            return Self.failure("invalid_limits")
        }
        guard call.arguments.utf8.count <= 128 * 1024,
              let data = call.arguments.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Self.failure("invalid_arguments")
        }

        let prompt: String
        let files: [RequestAttachment]
        let model: String?
        let attachmentID: String?
        switch call.name {
        case "read_attachment":
            guard let identifier = Self.argument(arguments, "attachment_id") else {
                return Self.failure("attachment_id_required")
            }
            guard let question = Self.argument(arguments, "question") else {
                return Self.failure("question_required")
            }
            guard question.utf16.count <= 500 else { return Self.failure("question_too_long") }
            let match: Attachment
            switch resolveAttachment(identifier) {
            case .success(let attachment): match = attachment
            case .failure(let error): return Self.failure(error.rawValue)
            }
            do {
                files = [try prepareAttachment(match)]
            } catch {
                try Task.checkCancellation()
                try validateScope()
                if Self.isCancellation(error) { throw CancellationError() }
                if error is ScopeError { throw error }
                return Self.failure("attachment_unavailable")
            }
            prompt = question
            model = nil
            attachmentID = match.id.uuidString.lowercased()
        case "delegate_to_specialist":
            // Preserve the old runner's input aliases; the advertised schema
            // uses only model_slug. No alias can select an endpoint or key.
            guard let slug = ["model_slug", "model", "specialist"].compactMap({ Self.argument(arguments, $0) }).first else {
                return Self.failure("model_slug_required")
            }
            guard slug.utf16.count <= 512,
                  !slug.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return Self.failure("invalid_model_slug")
            }
            guard let question = Self.argument(arguments, "prompt") else { return Self.failure("prompt_required") }
            guard question.utf16.count <= 8_000 else { return Self.failure("prompt_too_long") }
            prompt = question
            files = []
            model = slug
            attachmentID = nil
        default:
            return Self.failure("unsupported_tool")
        }

        try Task.checkCancellation()
        try validateScope()
        let answer: String
        do {
            answer = try await LocalCloudDeadline.run(timeout: limits.timeout, validateScope: validateScope) {
                try await cloud(prompt, files, model)
            }
        } catch {
            try Task.checkCancellation()
            try validateScope()
            if let validation = error as? LocalCloudScopeFailure { throw validation.underlying }
            if error is ScopeError { throw error }
            if Self.isCancellation(error) { throw CancellationError() }
            if error is LocalCloudTimeout { return Self.failure("cloud_request_timed_out") }
            return Self.failure("cloud_request_failed")
        }
        try Task.checkCancellation()
        try validateScope()
        let maximumBytes = limits.resultBytes
        let formatter = Task.detached(priority: .userInitiated) {
            try Self.success(answer: answer, attachmentID: attachmentID, model: model, maximumBytes: maximumBytes)
        }
        let output = try await withTaskCancellationHandler {
            try await formatter.value
        } onCancel: {
            formatter.cancel()
        }
        try Task.checkCancellation()
        try validateScope()
        return output
    }

    private enum AttachmentFailure: String, Error {
        case invalid = "invalid_attachment_id"
        case missing = "attachment_not_found"
        case ambiguous = "attachment_ambiguous"
    }

    private func resolveAttachment(_ identifier: String) -> Result<Attachment, AttachmentFailure> {
        let fullID = UUID(uuidString: identifier)
        guard identifier.utf8.count <= 36, !identifier.isEmpty,
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45 }) else {
            return .failure(.invalid)
        }
        var matches: [UUID: Attachment] = [:]
        for attachment in attachments {
            let matched = fullID.map { attachment.id == $0 } ?? attachment.id.uuidString.lowercased().hasPrefix(identifier.lowercased())
            guard matched else { continue }
            if let previous = matches[attachment.id],
               previous.name != attachment.name || previous.fileName != attachment.fileName || previous.size != attachment.size {
                return .failure(.ambiguous)
            }
            matches[attachment.id] = attachment
        }
        guard !matches.isEmpty else { return .failure(.missing) }
        guard matches.count == 1, let match = matches.values.first else { return .failure(.ambiguous) }
        return .success(match)
    }

    private static func argument(_ input: [String: Any], _ key: String) -> String? {
        guard let raw = input[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private nonisolated static func failure(_ code: String) -> String { "{\"error\":\"\(code)\"}" }

    private struct Output: Encodable {
        var answer: String
        var attachmentID: String?
        var model: String?
        var truncated: Bool?
        var originalBytes: Int?
        enum CodingKeys: String, CodingKey {
            case answer, attachmentID = "attachment_id", model = "model_slug", truncated, originalBytes = "original_utf8_bytes"
        }
    }

    private nonisolated static func success(answer: String, attachmentID: String?, model: String?, maximumBytes: Int) throws -> String {
        try Task.checkCancellation()
        let originalBytes = answer.utf8.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func encoded(_ text: String, truncated: Bool) -> Data? {
            try? encoder.encode(Output(answer: text, attachmentID: attachmentID, model: model,
                                       truncated: truncated ? true : nil, originalBytes: truncated ? originalBytes : nil))
        }
        if originalBytes <= maximumBytes, let complete = encoded(answer, truncated: false), complete.count <= maximumBytes {
            return String(decoding: complete, as: UTF8.self)
        }
        let marker = "\n[AAUV: answer truncated]"
        guard let empty = encoded(marker, truncated: true), empty.count <= maximumBytes else {
            return failure("result_limit_too_small")
        }
        // At most maximumBytes of the source text need inspection. Actual JSON
        // encoding determines the budget, including control-character escaping.
        let prefix = Data(answer.utf8.prefix(maximumBytes))
        var lower = 0
        var upper = prefix.count
        var best = empty
        while lower <= upper {
            try Task.checkCancellation()
            let count = lower + (upper - lower) / 2
            var end = count
            var text = String(data: prefix.prefix(end), encoding: .utf8)
            while text == nil, end > 0 {
                end -= 1
                text = String(data: prefix.prefix(end), encoding: .utf8)
            }
            guard let candidate = encoded((text ?? "") + marker, truncated: true) else {
                return failure("result_encoding_failed")
            }
            if candidate.count <= maximumBytes {
                best = candidate
                lower = count + 1
            } else {
                upper = count - 1
            }
        }
        return String(decoding: best, as: UTF8.self)
    }
}

private struct LocalCloudTimeout: Error {}
private struct LocalCloudScopeFailure: Error { let underlying: Error }

/// A timeout must cancel the underlying request and reject late success without
/// waiting forever for a faulty injected operation that ignores cancellation.
/// A cooperating URLSession request still unwinds normally and records its usage.
@MainActor
private final class LocalCloudDeadline {
    private var continuation: CheckedContinuation<String, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private let cancellation = LocalCloudCancellation()

    static func run(timeout: Duration, validateScope: @escaping LocalCloudTools.ValidateScope,
                    operation: @escaping @MainActor @Sendable () async throws -> String) async throws -> String {
        let race = LocalCloudDeadline()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, timeout: timeout, validateScope: validateScope, operation: operation)
            }
        } onCancel: {
            race.cancellation.cancel()
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<String, Error>, timeout: Duration,
                       validateScope: @escaping LocalCloudTools.ValidateScope,
                       operation: @escaping @MainActor @Sendable () async throws -> String) {
        self.continuation = continuation
        guard !Task.isCancelled else { finish(.failure(CancellationError())); return }
        let worker = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                do { try validateScope() } catch { throw LocalCloudScopeFailure(underlying: error) }
                let outcome: Result<String, Error>
                do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
                do { try validateScope() } catch { throw LocalCloudScopeFailure(underlying: error) }
                try Task.checkCancellation()
                self?.finish(outcome)
            } catch {
                self?.finish(.failure(error))
            }
        }
        self.worker = worker
        cancellation.install(worker)
        timer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.finish(.failure(LocalCloudTimeout()))
            } catch { /* A completed/cancelled request no longer needs a timer. */ }
        }
    }

    private func finish(_ outcome: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        worker?.cancel()
        timer?.cancel()
        cancellation.clear()
        worker = nil
        timer = nil
        continuation.resume(with: outcome)
    }
}

/// Cancellation handlers run off the main actor. Relay cancellation directly to
/// an installed child before scheduling main-actor continuation completion.
private final class LocalCloudCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var worker: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        worker = task
        let cancelled = cancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = worker
        lock.unlock()
        task?.cancel()
    }

    func clear() {
        lock.lock()
        worker = nil
        lock.unlock()
    }
}
