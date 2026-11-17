import ImageIO
import SwiftUI

struct AttachmentImagePreview: View {
    let url: URL
    let name: String
    @State private var thumbnail: Thumbnail?

    private struct Thumbnail: @unchecked Sendable {
        // CGImage is immutable; ImageIO finishes decoding on the worker before publication.
        let image: CGImage
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(name)
            } else {
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .task(id: url) {
            thumbnail = nil
            guard ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp"]
                .contains((name as NSString).pathExtension.lowercased()) else { return }
            let processing = Task.detached(priority: .userInitiated) { Self.readThumbnail(url) }
            let value = await withTaskCancellationHandler {
                await processing.value
            } onCancel: {
                processing.cancel()
            }
            guard !Task.isCancelled else { return }
            thumbnail = value
        }
    }

    nonisolated private static func readThumbnail(_ url: URL) -> Thumbnail? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        return Thumbnail(image: image)
    }
}
