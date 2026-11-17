import SwiftUI
import MarkdownUI
import SwiftMath
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
private typealias PlatformColor = UIColor
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
private typealias PlatformColor = NSColor
private typealias PlatformImage = NSImage
#endif

private extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

// MARK: - LaTeX → platform image

/// Typesets LaTeX into a platform image via SwiftMath and memoises the result.
/// Rendering is fast (sub-millisecond) but a chat scroll re-lays out
/// constantly, so the cache keeps it off the hot path.
@MainActor
final class MathImageRenderer {
    static let shared = MathImageRenderer()
    private let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    fileprivate func image(latex: String, display: Bool, color: Color, fontSize: CGFloat, scheme: ColorScheme) -> PlatformImage {
        // The palette colors are appearance-adaptive, so both the cache key and
        // the rasterised color must be pinned to an explicit scheme — keying on
        // `String(describing: color)` (identical for both variants of a dynamic
        // color) would serve light-ink bitmaps in dark mode.
        let platformColor = Self.resolve(color, for: scheme)
        let key = "\(display)|\(Int(fontSize * 2))|\(scheme == .dark ? "dark" : "light")|\(latex)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let image = Self.render(latex: latex, display: display, color: platformColor, fontSize: fontSize)
        let bytes = Int(min(image.size.width * image.size.height * 16, CGFloat(Int32.max)))
        cache.setObject(image, forKey: key as NSString, cost: bytes)
        return image
    }

    /// Resolve a (possibly dynamic) Color to the concrete variant for `scheme`,
    /// independent of whatever appearance is ambient on the calling thread.
    private static func resolve(_ color: Color, for scheme: ColorScheme) -> PlatformColor {
        #if canImport(UIKit)
        return PlatformColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        )
        #elseif canImport(AppKit)
        let dynamic = PlatformColor(color)
        guard let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) else {
            return dynamic
        }
        var resolved = dynamic
        appearance.performAsCurrentDrawingAppearance {
            // `.cgColor` resolves a dynamic NSColor against the appearance that
            // is current at access time.
            resolved = PlatformColor(cgColor: dynamic.cgColor) ?? dynamic
        }
        return resolved
        #endif
    }

    private static func render(latex: String, display: Bool, color: PlatformColor, fontSize: CGFloat) -> PlatformImage {
        let math = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: color,
            labelMode: display ? .display : .text
        )
        let (error, image) = math.asImage()
        if error == nil, let image { return image }
        // SwiftMath couldn't parse the LaTeX — show the raw source rather
        // than dropping the formula entirely.
        return textFallback(latex, color: color, fontSize: fontSize)
    }

    private static func textFallback(_ source: String, color: PlatformColor, fontSize: CGFloat) -> PlatformImage {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
        #elseif canImport(AppKit)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
        #endif
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let sample = String(source.prefix(140))
        let string = NSAttributedString(string: sample == source ? sample : sample + "…", attributes: attrs)
        let size = string.size()
        let pixelSize = CGSize(width: max(1, ceil(size.width)), height: max(1, ceil(size.height)))
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        return renderer.image { _ in string.draw(at: .zero) }
        #elseif canImport(AppKit)
        let image = NSImage(size: pixelSize)
        image.lockFocus()
        string.draw(at: .zero)
        image.unlockFocus()
        return image
        #endif
    }
}

// MARK: - MarkdownUI providers

/// Inline images use a local placeholder unless they contain a formula.
struct MathInlineImageProvider: InlineImageProvider {
    let textColor: Color
    let fontSize: CGFloat
    /// Pinned by the hosting view (MarkdownText reads `\.colorScheme`); the
    /// provider value changing on a mode flip is what re-triggers MarkdownUI
    /// to re-request inline images in the new ink color.
    let scheme: ColorScheme

    func image(with url: URL, label: String) async throws -> Image {
        if let math = MathMarkup.parse(url) {
            let platformImage = await MathImageRenderer.shared.image(
                latex: math.latex,
                display: math.display,
                color: textColor,
                fontSize: fontSize,
                scheme: scheme
            )
            return Image(platformImage: platformImage)
        }
        return Image(systemName: "photo")
    }
}

/// Block images are either local formulae or links the user can open explicitly.
struct MathBlockImageProvider: ImageProvider {
    let textColor: Color
    let fontSize: CGFloat

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, let math = MathMarkup.parse(url) {
            MathBlockImage(
                latex: math.latex,
                textColor: textColor,
                // Display math gets a touch more size than body text.
                fontSize: fontSize * 1.1
            )
        } else {
            if let url, MessageMarkdown.allowsExternalURL(url) {
                Link(destination: url) { Label("打开外部图片", systemImage: "photo") }
            } else {
                Label("图片不可用", systemImage: "photo")
                    .foregroundStyle(AAUV.Theme.Palette.inkMuted)
            }
        }
    }
}

private struct MathBlockImage: View {
    private struct RenderKey: Equatable {
        let latex: String
        let scheme: ColorScheme
    }

    let latex: String
    let textColor: Color
    let fontSize: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width)
            } else {
                Color.clear.frame(height: fontSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
        // Re-render on appearance change so the formula color tracks the
        // surrounding text.
        .task(id: RenderKey(latex: latex, scheme: colorScheme)) {
            image = MathImageRenderer.shared.image(
                latex: latex,
                display: true,
                color: textColor,
                fontSize: fontSize,
                scheme: colorScheme
            )
        }
    }
}
