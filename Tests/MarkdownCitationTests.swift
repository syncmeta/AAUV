import Foundation

@main
struct MarkdownCitationTests {
    static func main() {
        let text = """
        证据🙂第一段。

        ```swift
        print(1)
        ```

        | 列 | 值 |
        |---|---|
        | a | b |

        第二段 \\(x^2\\)。
        """

        func citation(_ location: String, url: String, title: String) -> WebCitation {
            let range = text.range(of: location)!
            return WebCitation(url: url, title: title,
                               start: text[..<range.lowerBound].unicodeScalars.count,
                               end: text[..<range.upperBound].unicodeScalars.count)
        }
        let repeated = "https://example.invalid/shared"
        let document = MarkdownCitations(text: text, citations: [
            citation("证据🙂第一段。", url: repeated, title: "来源一"),
            citation("print(1)", url: "https://example.invalid/code", title: "代码旁的来源"),
            citation("| a | b |", url: "https://example.invalid/table", title: "表格旁的来源"),
            citation("第二段", url: repeated, title: "重复来源"),
            WebCitation(url: "file:///private/tmp/secret", title: "bad", start: nil, end: nil),
            WebCitation(url: "https://example.invalid/fallback", title: "", start: nil, end: nil)
        ], scope: "fixture")
        let html = document.content.renderHTML()
        precondition(document.sources.map(\.title) == ["来源一", "代码旁的来源", "表格旁的来源", "example.invalid"])
        precondition(document.links.count == 2)
        precondition(document.links.values.allSatisfy { $0.absoluteString == repeated })
        precondition(html.contains(">〔1〕</a>") && html.contains("<table>") && html.contains("print(1)\n</code>"))
        precondition(!html.contains("print(1) [") && html.contains("aauv-math://"))
        print("Inline markers followed Unicode offsets, skipped code and tables, and kept safe fallback sources.")
    }
}
