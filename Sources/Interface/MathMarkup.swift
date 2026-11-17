import Foundation

/// Detects LaTeX math in message text and rewrites the delimiters into
/// markdown image references. Supported delimiters: `\(…\)` and `$…$`
/// inline, `\[…\]` and `$$…$$` display. Math inside fenced or inline code
/// is left untouched. Pure Foundation — cross-platform.
enum MathMarkup {
    static let scheme = "aauv-math"

    /// Cheap pre-check so messages with no math skip the regex work.
    static func containsMath(_ text: String) -> Bool {
        text.contains("\\(") || text.contains("\\[") || text.contains("$")
    }

    /// Rewrite every math span outside code regions into image markdown.
    static func rewrite(_ text: String) -> String {
        guard text.utf8.count <= 128_000 else { return text }
        var out = ""
        for segment in segments(text) {
            switch segment {
            case .code(let s):
                out += s
            case .text(let s):
                out += rewriteMath(in: s)
            }
        }
        return out
    }

    // ── Code-aware segmentation ──────────────────────────────────────────

    private enum Segment {
        case code(String)
        case text(String)
    }

    /// Split `text` into code segments (fenced blocks + inline code spans)
    /// and plain-text segments. Only the plain-text segments get the math
    /// rewrite — a `$` inside a shell snippet must stay literal.
    private static func segments(_ text: String) -> [Segment] {
        let chars = Array(text)
        var result: [Segment] = []
        var buf = ""
        var i = 0

        func flushText() {
            if !buf.isEmpty { result.append(.text(buf)); buf = "" }
        }

        while i < chars.count {
            let atLineStart = i == 0 || chars[i - 1].isNewline

            // Fenced code may be indented by up to three spaces.
            var opener = i
            if atLineStart {
                while opener < chars.count, opener - i < 3, chars[opener] == " " { opener += 1 }
            }
            if atLineStart, opener < chars.count, chars[opener] == "`" || chars[opener] == "~" {
                let fence = chars[opener]
                var n = 0
                while opener + n < chars.count && chars[opener + n] == fence { n += 1 }
                if n >= 3 {
                    var j = opener + n
                    while j < chars.count && !chars[j].isNewline { j += 1 }   // rest of opening line
                    while j < chars.count {
                        j += 1                                             // step onto next line
                        let lineStart = j
                        var k = lineStart
                        while k < chars.count && (chars[k] == " " || chars[k] == "\t") { k += 1 }
                        var m = 0
                        while k + m < chars.count && chars[k + m] == fence { m += 1 }
                        if m >= n {
                            var end = k + m
                            while end < chars.count && (chars[end] == " " || chars[end] == "\t") { end += 1 }
                            if end == chars.count || chars[end].isNewline {
                                j = end
                                break
                            }
                        }
                        j = lineStart
                        while j < chars.count && !chars[j].isNewline { j += 1 }
                    }
                    flushText()
                    result.append(.code(String(chars[i..<j])))
                    i = j
                    continue
                }
            }

            // Link and image destinations may contain literal dollar signs.
            if i > 0, chars[i - 1] == "]", chars[i] == "(" {
                var depth = 1
                var end = i + 1
                while end < chars.count, !chars[end].isNewline {
                    if chars[end] == "\\" {
                        end = min(end + 2, chars.count)
                        continue
                    }
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" { depth -= 1 }
                    end += 1
                    if depth == 0 { break }
                }
                if depth == 0 {
                    flushText()
                    result.append(.code(String(chars[i..<end])))
                    i = end
                    continue
                }
            }

            // Inline code span: a run of N backticks closed by a run of N.
            if chars[i] == "`" {
                var n = 0
                while i + n < chars.count && chars[i + n] == "`" { n += 1 }
                var j = i + n
                var close = -1
                while j < chars.count {
                    if chars[j] == "`" {
                        var m = 0
                        while j + m < chars.count && chars[j + m] == "`" { m += 1 }
                        if m == n { close = j + m; break }
                        j += m
                    } else {
                        j += 1
                    }
                }
                if close >= 0 {
                    flushText()
                    result.append(.code(String(chars[i..<close])))
                    i = close
                    continue
                }
                buf += String(chars[i..<(i + n)])
                i += n
                continue
            }

            buf.append(chars[i])
            i += 1
        }
        flushText()
        return result
    }

    // ── Math span rewriting ──────────────────────────────────────────────

    private static func rewriteMath(in text: String) -> String {
        var s = text
        s = replace(s, Patterns.displayDollar, display: true)
        s = replace(s, Patterns.displayBracket, display: true)
        s = replace(s, Patterns.inlineParen, display: false)
        s = replace(s, Patterns.inlineDollar, display: false)
        return s
    }

    private enum Patterns {
        // Display: $$ … $$  and  \[ … \]  (may span lines).
        static let displayDollar = regex(#"\$\$([\s\S]+?)\$\$"#)
        static let displayBracket = regex(#"\\\[([\s\S]+?)\\\]"#)
        // Inline: \( … \)  (single line).
        static let inlineParen = regex(#"\\\(([^\n]+?)\\\)"#)
        // Inline: $ … $ — guarded so prose like "$5 and $10" is not eaten:
        // opener not preceded by \, $, or a digit and not followed by space
        // or $; content ends on a non-space; closer not followed by digit/$.
        static let inlineDollar = regex(#"(?<![\\$0-9])\$(?![ \t$])((?:\\.|[^$\n\\])*?\S)\$(?![0-9$])"#)

        private static func regex(_ p: String) -> NSRegularExpression {
            // Patterns are compile-time literals — a failure is a programmer
            // error, so an empty fallback (which matches nothing) is fine.
            (try? NSRegularExpression(pattern: p)) ?? NSRegularExpression()
        }
    }

    private static func replace(_ text: String, _ pattern: NSRegularExpression, display: Bool) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            if full.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let latex = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isRenderable(latex), let encoded = encode(latex) {
                let mode = display ? "b" : "i"
                result += "![](\(scheme)://\(mode)/\(encoded))"
            } else {
                result += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    // ── base64url codec (carries the LaTeX through the image URL) ─────────

    private static func isRenderable(_ source: String) -> Bool {
        guard !source.isEmpty, source.utf8.count <= 1_024 else { return false }
        var depth = 0
        for character in source {
            if character == "{" { depth += 1 }
            if character == "}" { depth = max(0, depth - 1) }
            if depth > 24 { return false }
        }
        return true
    }

    static func encode(_ s: String) -> String? {
        guard let data = s.data(using: .utf8) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> String? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pull `(display, latex)` back out of a `aauv-math://…` URL.
    static func parse(_ url: URL) -> (display: Bool, latex: String)? {
        guard url.scheme == scheme else { return nil }
        let display = (url.host == "b")
        let payload = String(url.path.dropFirst())   // strip leading "/"
        guard payload.utf8.count <= 1_400, let latex = decode(payload), isRenderable(latex) else { return nil }
        return (display, latex)
    }
}
