import SwiftUI
import UniformTypeIdentifiers

enum LetterTextFormat {
    case plainText, markdown

    var contentType: UTType {
        switch self {
        case .plainText: .plainText
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

/// Exports exactly the selected saved assistant body, without its prompt,
/// conversation metadata, credentials or attachments. No network is involved.
struct LetterTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, LetterTextFormat.markdown.contentType] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
