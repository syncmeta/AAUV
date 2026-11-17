import Foundation

/// Offline names from PendingBot's attributed GeoNames corpus. UUID-based
/// PendingChatAvatar identity stays independent of a bot's editable name.
enum BotPlaceNames {
    static let all: [String] = {
        guard let url = Bundle.main.url(forResource: "bot-place-names", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return ["Atlantis"] }
        var seen = Set<String>()
        let names = contents.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.hasPrefix("#"), name.count <= 80,
                  seen.insert(key(name)).inserted else { return nil }
            return name
        }
        return names.isEmpty ? ["Atlantis"] : names
    }()

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func random(excluding names: Set<String> = []) -> String {
        let used = Set(names.map(key))
        if let name = all.filter({ !used.contains(key($0)) }).randomElement() { return name }
        // Even an exhausted/missing corpus must not repeat an existing name.
        if !used.contains(key("Atlantis")) { return "Atlantis" }
        var suffix = 2
        while used.contains(key("Atlantis \(suffix)")) { suffix += 1 }
        return "Atlantis \(suffix)"
    }
}
