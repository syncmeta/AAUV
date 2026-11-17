import Foundation

enum FileOpenRequest: Sendable {
    case configuration(Data)
    case configurationFile(URL)
    case backup(URL)
    case attachment(URL)

    static func read(_ url: URL) throws -> Self {
        if url.scheme == "aauv" { return .configuration(try ConfigurationLink.decode(url.absoluteString)) }
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let suffix = url.pathExtension.lowercased()
        if suffix == "aauvbackup" { return .backup(url) }
        let named = suffix == "aauv" || url.lastPathComponent.lowercased().hasSuffix(".aauv.json")
        if named { return .configurationFile(url) }
        guard suffix == "json" else { return .attachment(url) }

        do {
            let data = try PortableSettings.readFile(url)
            if (try? JSONDecoder().decode(Marker.self, from: data))?.format == "aauv-config" {
                return .configuration(data)
            }
            return .attachment(url)
        } catch let error as CocoaError where error.code == .fileReadTooLarge {
            return .attachment(url)
        }
    }

    private struct Marker: Decodable {
        let format: String
    }
}
