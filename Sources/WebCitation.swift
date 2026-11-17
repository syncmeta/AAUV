import Foundation

struct WebCitation: Codable, Hashable, Sendable {
    let url: String
    let title: String
    let start: Int?
    let end: Int?

    var safeURL: URL? {
        guard url.utf8.count <= 8_192, let parsed = URL(string: url), Self.allows(parsed) else { return nil }
        return parsed
    }

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }
}

// Decode the same terminal output used by the Go stream parser to form the final text.
enum ResponseWebCitations {
    struct Item: Decodable {
        let type: String?
        let content: [Part]

        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: Keys.self)
            type = try? fields?.decode(String.self, forKey: .type)
            content = (try? fields?.decode([Part].self, forKey: .content)) ?? []
        }

        private enum Keys: String, CodingKey { case type, content }
    }

    struct Part: Decodable {
        let type: String?
        let text: String
        let annotations: [Annotation]

        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: Keys.self)
            let kind = try? fields?.decode(String.self, forKey: .type)
            type = kind
            text = (try? fields?.decode(String.self, forKey: kind == "refusal" ? .refusal : .text)) ?? ""
            annotations = (try? fields?.decode([Annotation].self, forKey: .annotations)) ?? []
        }

        private enum Keys: String, CodingKey { case type, text, refusal, annotations }
    }

    struct Annotation: Decodable {
        let type: String?
        let url: String?
        let title: String
        let start: Int?
        let end: Int?

        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: Keys.self)
            type = try? fields?.decode(String.self, forKey: .type)
            url = try? fields?.decode(String.self, forKey: .url)
            title = (try? fields?.decode(String.self, forKey: .title)) ?? ""
            start = try? fields?.decode(Int.self, forKey: .start_index)
            end = try? fields?.decode(Int.self, forKey: .end_index)
        }

        private enum Keys: String, CodingKey { case type, url, title, start_index, end_index }
    }

    static func collect(from output: [Item], matching finalText: String) -> [WebCitation] {
        var citations: [WebCitation] = []
        var seen = Set<WebCitation>()
        var offset = 0
        var assembled = ""
        for item in output {
            for part in item.content where part.type == "output_text" || part.type == "refusal" {
                assembled += part.text
                let length = part.text.unicodeScalars.count
                if item.type == "message", part.type == "output_text" {
                    for annotation in part.annotations where annotation.type == "url_citation" && citations.count < 128 {
                        guard let url = annotation.url else { continue }
                        let range: Range<Int>?
                        if let start = annotation.start, let end = annotation.end,
                           start >= 0, end >= start, end <= length {
                            range = (offset + start)..<(offset + end)
                        } else {
                            range = nil
                        }
                        let title = String(annotation.title.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
                        let citation = WebCitation(url: url, title: title, start: range?.lowerBound, end: range?.upperBound)
                        if citation.safeURL != nil, seen.insert(citation).inserted { citations.append(citation) }
                    }
                }
                offset += length
            }
        }
        if assembled.utf8.elementsEqual(finalText.utf8) { return citations }
        return citations.map { WebCitation(url: $0.url, title: $0.title, start: nil, end: nil) }
    }
}
