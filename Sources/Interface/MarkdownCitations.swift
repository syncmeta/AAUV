import Foundation
import MarkdownUI

struct MarkdownCitations {
    struct Source: Identifiable {
        let id: Int
        let url: URL
        let title: String
    }

    private struct Placement {
        let offset: Int
        let source: Source
        let link: String
    }

    let content: MarkdownContent
    let sources: [Source]
    let links: [String: URL]

    init(text: String, citations: [WebCitation], scope: String) {
        var ordered: [Source] = []
        var known: [URL: Source] = [:]
        var placements: [Placement] = []
        var inserted: [Int: Set<Int>] = [:]
        let scalars = !citations.isEmpty && text.utf8.count <= 256_000 ? Array(text.unicodeScalars) : []

        for citation in citations.prefix(128) {
            guard let url = citation.safeURL else { continue }
            let source: Source
            if let previous = known[url] {
                source = previous
            } else {
                let title = String(citation.title.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
                source = Source(id: ordered.count + 1, url: url, title: title.isEmpty ? url.host ?? url.absoluteString : title)
                known[url] = source
                ordered.append(source)
            }
            guard let end = citation.end, let offset = Self.anchor(for: end, in: scalars),
                  inserted[offset, default: []].insert(source.id).inserted else { continue }
            let link = "aauv-cite://\(scope)/\(placements.count + 1)"
            placements.append(Placement(offset: offset, source: source, link: link))
        }
        sources = ordered

        guard !placements.isEmpty else {
            content = Self.parse(text)
            links = [:]
            return
        }
        let orderedPlacements = placements.sorted {
            if $0.offset == $1.offset { return $0.source.id < $1.source.id }
            return $0.offset < $1.offset
        }
        let candidate = Self.parse(Self.insert(orderedPlacements, into: scalars))
        // A location inside a fence, literal span or raw HTML can look like prose.
        // Keep markers only where the Markdown parser produced a real link.
        let html = candidate.renderHTML()
        let visible = orderedPlacements.filter { html.contains("href=\"\($0.link)\"") }
        if visible.count == orderedPlacements.count {
            content = candidate
        } else if visible.isEmpty {
            content = Self.parse(text)
        } else {
            content = Self.parse(Self.insert(visible, into: scalars))
        }
        links = Dictionary(uniqueKeysWithValues: visible.map { ($0.link, $0.source.url) })
    }

    private static func parse(_ source: String) -> MarkdownContent {
        MarkdownContent(MathMarkup.containsMath(source) ? MathMarkup.rewrite(source) : source)
    }

    private static func insert(_ placements: [Placement], into text: [UnicodeScalar]) -> String {
        var result = ""
        var start = 0
        for placement in placements {
            result += String(String.UnicodeScalarView(text[start..<placement.offset]))
            result += " [〔\(placement.source.id)〕](\(placement.link))"
            start = placement.offset
        }
        result += String(String.UnicodeScalarView(text[start..<text.count]))
        return result
    }

    private static func anchor(for end: Int, in text: [UnicodeScalar]) -> Int? {
        guard end > 0, end <= text.count else { return nil }
        let anchor = end - 1
        var start = anchor
        while start > 0, !isNewline(text[start - 1]) { start -= 1 }
        var finish = anchor
        while finish < text.count, !isNewline(text[finish]) { finish += 1 }
        guard start < finish else { return nil }
        while finish > start, text[finish - 1] == " " || text[finish - 1] == "\t" { finish -= 1 }
        let line = String(String.UnicodeScalarView(text[start..<finish])).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.contains("|"), !line.hasSuffix("\\"),
              !(line.hasPrefix("[") && line.contains("]:")),
              !line.hasPrefix("```"), !line.hasPrefix("~~~"), !line.hasPrefix("<"),
              !line.hasPrefix("$$"), !line.hasPrefix("\\[") else { return nil }
        return finish
    }

    private static func isNewline(_ scalar: UnicodeScalar) -> Bool {
        scalar == "\n" || scalar == "\r"
    }
}
