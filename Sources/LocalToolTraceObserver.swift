import Foundation

// A breadcrumb describes only a trusted host invocation and observed helper
// outcome. Model arguments/results stay transient; they never become a generic
// trace dump. Metadata failures must not change or repeat the business action.
enum LocalToolTraceObserver {
    struct Images: Sendable {
        let prepared: Int
        let unavailable: Int
        let cancelled: Bool
    }

    struct Result: Sendable {
        let output: String
        var images: Images? = nil
    }

    @MainActor static func perform(
        call: LocalToolCall,
        persist: (LocalToolTrace.Event) throws -> Void,
        scopeIsCurrent: () -> Bool,
        operation: () async throws -> Result
    ) async throws -> String {
        guard let function = LocalToolTrace.Function(rawValue: call.name) else {
            return try await operation().output
        }
        let start = running(call: call, function: function)
        try? persist(start)
        do {
            let result = try await operation()
            // A confirmed success stays terminal even if the parent model round
            // is later cancelled or its bridge cannot write the result.
            try? persist(completed(start, result: result))
            return result.output
        } catch {
            var finish = start
            if Task.isCancelled || error is CancellationError ||
                (error as? URLError)?.code == .cancelled || error is LocalCloudTools.ScopeError || !scopeIsCurrent() {
                finish.state = .interrupted
            } else {
                finish.state = .failed
                finish.failure = (error as? URLError)?.code == .timedOut ? .timeout : .toolFailed
            }
            try? persist(finish)
            throw error
        }
    }

    static func running(call: LocalToolCall, function: LocalToolTrace.Function, id: UUID = UUID()) -> LocalToolTrace.Event {
        var entry = LocalToolTrace.Event(id: id, function: function, state: .running)
        // The concrete tool accepts at most a bounded JSON object. Never scan an
        // arbitrary image/data argument merely to prepare a display label.
        if call.arguments.utf8.count <= 1024 * 1024,
           let object = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any] {
            if function == .searchChatHistory, let query = object["query"] as? String,
               let preview = queryPreview(query) {
                entry.query = preview.text
                entry.queryTruncated = preview.truncated ? true : nil
            }
            if function == .createSkill, let name = object["name"] as? String {
                entry.skillName = skillName(name)
            }
        }
        return entry
    }

    static func completed(_ start: LocalToolTrace.Event, result: Result) -> LocalToolTrace.Event {
        var finish = start
        finish.state = .failed
        finish.failure = .toolFailed
        if start.function == .sendImages, let images = result.images {
            guard (0...5).contains(images.prepared), images.unavailable >= 0 else { return finish }
            if images.prepared > 0 {
                finish.state = images.unavailable > 0 || images.cancelled ? .partial : .succeeded
                finish.quantity = images.prepared
                finish.failure = nil
                return finish
            }
            if images.cancelled { finish.state = .interrupted; finish.failure = nil; return finish }
        }
        guard result.output.utf8.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return finish }
        if let error = object["error"], !(error is NSNull) {
            let mapped = failure(error as? String)
            finish.state = mapped.interrupted ? .interrupted : .failed
            finish.failure = mapped.failure
            return finish
        }
        switch start.function {
        case .searchChatHistory:
            guard let values = object["results"] as? [[String: Any]], values.count <= 30 else { return finish }
            finish.quantity = values.count
        case .createSkill:
            guard let name = object["name"] as? String, skillName(name) == start.skillName,
                  start.skillName != nil, object["subscribed"] as? Bool == true,
                  let id = object["skill_id"] as? String, UUID(uuidString: id) != nil else { return finish }
        case .readAttachment, .delegateToSpecialist:
            guard let answer = object["answer"] as? String, answer.utf16.count <= 4 * 1024 * 1024 else { return finish }
            finish.quantity = answer.utf16.count
        case .sendImages:
            // A JSON sent/count claim is insufficient. Only the concrete image
            // helper's prepared in-memory files can confirm acquisition.
            return finish
        }
        finish.state = .succeeded
        finish.failure = nil
        return finish
    }

    private static func failure(_ code: String?) -> (failure: LocalToolTrace.Failure?, interrupted: Bool) {
        guard let code else { return (.toolFailed, false) }
        if ["cancelled", "tool_cancelled", "cloud_request_cancelled"].contains(code) { return (nil, true) }
        if code == "cloud_request_timed_out" { return (.timeout, false) }
        if ["needs_bound_bot", "attachment_unavailable", "attachment_not_found", "delegation_not_configured", "model_not_configured"].contains(code) {
            return (.unavailable, false)
        }
        if ["image_limit_exceeded", "result_limit_too_small", "tool arguments too large"].contains(code) ||
            code == "skill library or conversation instructions exceed their 100-skill / 512-KB limit" {
            return (.limit, false)
        }
        let invalid = ["invalid_limits", "invalid_arguments", "attachment_id_required", "question_required", "question_too_long",
                       "invalid_attachment_id", "attachment_ambiguous", "model_slug_required", "invalid_model_slug", "prompt_required",
                       "prompt_too_long", "ambiguous_model_use_bot_id", "invalid_images_arguments", "invalid_images_arguments_or_limit",
                       "at least one of query / since / until is required", "name, description and body must be strings", "name is required",
                       "name must be lowercase kebab-case, at most 80 characters", "description exceeds 2000 characters",
                       "body must be nonempty and at most 65536 characters", "since is not a valid ISO date", "until is not a valid ISO date"]
        if invalid.contains(code) || code.hasPrefix("invalid query syntax: ") { return (.invalidInput, false) }
        return (.toolFailed, false)
    }

    static func skillName(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 80, text.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return text
    }

    static func queryPreview(_ input: String) -> (text: String, truncated: Bool)? {
        guard input.unicodeScalars.count <= 1024, input.utf8.count <= 4096 else { return nil }
        // Remove invisible formatting before detection so it cannot split a
        // credential prefix. Normalize whitespace/controls before matching
        // authorization spans, then canonicalize again after bounded clipping.
        var text = String(String.UnicodeScalarView(input.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let patterns = [
            #"(?i)(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>]+"#,
            #"(?i)(?<![A-Za-z0-9_])["']?(?:authorization|bearer|basic|access[_-]?token|refresh[_-]?token|client[_-]?secret|api[_-]?key|password)(?![A-Za-z0-9_])["']?\s*[:=]?\s*(?:(?:bearer|basic)\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            #"(?<![A-Za-z0-9_])(?:sk-[A-Za-z0-9_-]{6,}|gh[pousr]_[A-Za-z0-9_]{6,}|github_pat_[A-Za-z0-9_]{6,}|eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})(?![A-Za-z0-9_])"#
        ]
        // A URL's non-whitespace span is removed before controls can split
        // it; authorization/key detection runs after normalization, so e.g.
        // Bearer<NUL>value cannot become a newly exposed secret afterwards.
        guard let urls = try? NSRegularExpression(pattern: patterns[0]) else { return nil }
        text = urls.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[omitted]")
        text = normalizingWhitespace(text)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[omitted]")
        }
        text = normalizingWhitespace(text)
        guard !text.isEmpty else { return nil }
        let truncated = text.unicodeScalars.count > 256
        let clipped = String(String.UnicodeScalarView(text.unicodeScalars.prefix(256))).trimmingCharacters(in: .whitespacesAndNewlines)
        return (clipped, truncated)
    }

    private static func normalizingWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        return scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
