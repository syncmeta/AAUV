import SwiftUI

/// Purely local avatar identity. Uses PendingBot's exact 31x Int32 hash and
/// emoji ordering; no image requests, account lookup, or server path exists.
enum PendingChatIdentity {
    private static func hash(_ seed: String) -> Int {
        var hash: Int32 = 0
        for scalar in seed.unicodeScalars {
            hash = hash &* 31 &+ Int32(bitPattern: scalar.value)
        }
        return abs(Int(hash))
    }

    static func hue(for seed: String) -> Double {
        Double(hash(seed) % 360) / 360.0
    }

    static func softBackground(for seed: String) -> Color {
        Color(hue: hue(for: seed), saturation: 0.22, brightness: 0.94)
    }

    static func emoji(for seed: String) -> String {
        avatarEmoji[hash(seed) % avatarEmoji.count]
    }

    private static let avatarEmoji: [String] = [
        "🦊", "🐼", "🐯", "🦁", "🐸", "🐧", "🐳", "🐙",
        "🦉", "🦄", "🐝", "🦋", "🐢", "🐬", "🦒", "🦔",
        "🦕", "🦖", "🐲", "🦚", "🦩", "🐌", "🐞", "🦜",
        "🌵", "🌻", "🌸", "🌙", "⭐", "🔥", "🍄", "🍀",
        "🍓", "🍑", "🍋", "🍇", "🥑", "🌽", "🥨", "🍪",
        "🎈", "🎨", "🎭", "🎪", "🎲", "🧩", "🪁", "🪐",
        "🚀", "⛵", "🏕", "🗿", "🪴", "🪨", "💎", "🧊",
        "🦤", "🦥", "🦦", "🦨", "🐿", "🦫", "🪼", "🪿",
    ]
}

struct PendingChatAvatar: View {
    let emojiSeed: String
    let colorSeed: String
    var size: CGFloat = 36

    init(seed: String, size: CGFloat = 36) {
        self.emojiSeed = seed
        self.colorSeed = seed
        self.size = size
    }

    init(emojiSeed: String, colorSeed: String, size: CGFloat = 36) {
        self.emojiSeed = emojiSeed
        self.colorSeed = colorSeed
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle().fill(PendingChatIdentity.softBackground(for: colorSeed))
            Text(PendingChatIdentity.emoji(for: emojiSeed))
                .font(Theme.Fonts.glyph(size: size * 0.55))
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
    }
}
