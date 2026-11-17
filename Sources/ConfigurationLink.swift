import AAUVCore
import Foundation

enum ConfigurationLink {
    static let maximumBytes = Int(AauvcoreConfigurationLinkMaximumBytes)

    static func encode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        var error: NSError?
        let link = AauvcoreEncodeConfigurationLink(data, &error)
        if error != nil { throw CocoaError(.fileWriteUnknown) }
        return link
    }

    static func decode(_ input: String) throws -> Data {
        var error: NSError?
        let decoded = AauvcoreDecodeConfigurationLink(input, &error)
        if error?.localizedDescription == "configuration_too_large" { throw CocoaError(.fileReadTooLarge) }
        guard error == nil, let decoded else { throw CocoaError(.fileReadCorruptFile) }
        return decoded
    }
}

enum LoginMethod: String, Codable, CaseIterable, Sendable {
    case chatgpt, copilot, byok
}
