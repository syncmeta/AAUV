import Foundation

enum HostedTool: String, CaseIterable, Sendable {
    case webSearch = "web_search"
    case codeInterpreter = "code_interpreter"
    case imageGeneration = "image_generation"

    var progressLabel: String {
        switch self {
        case .webSearch: "正在网页搜索…"
        case .codeInterpreter: "正在云端运行代码…"
        case .imageGeneration: "正在云端生成图片…"
        }
    }

    static func supported(_ values: [String], by login: LoginMethod) -> [String] {
        switch login {
        case .byok: allCases.map(\.rawValue).filter(values.contains)
        case .chatgpt: values.contains(webSearch.rawValue) ? [webSearch.rawValue] : []
        case .copilot: []
        }
    }
}

enum DefaultHostedTools {
    private static let byokEndpointKey = "byokHostedToolsEndpoint"
    private static let byokKey = "byokHostedTools"
    private static let chatGPTKey = "chatGPTHostedTools"

    static func byok(at endpoint: String, imported: PortableSettings?, defaults: UserDefaults = .standard) -> [String] {
        if defaults.string(forKey: byokEndpointKey) == endpoint, let tools = defaults.stringArray(forKey: byokKey) {
            return HostedTool.supported(tools, by: .byok)
        }
        guard let imported, imported.endpoint == endpoint, (imported.loginMethod ?? .byok) == .byok else { return [] }
        return HostedTool.supported(imported.hostedTools ?? [], by: .byok)
    }

    static func chatGPT(imported: PortableSettings?, defaults: UserDefaults = .standard) -> [String] {
        let tools = defaults.stringArray(forKey: chatGPTKey) ?? (imported?.loginMethod == .chatgpt ? imported?.hostedTools : nil) ?? []
        return HostedTool.supported(tools, by: .chatgpt)
    }

    static func saveBYOK(_ tools: [String], at endpoint: String, defaults: UserDefaults = .standard) {
        defaults.set(HostedTool.supported(tools, by: .byok), forKey: byokKey)
        defaults.set(endpoint, forKey: byokEndpointKey)
    }

    static func saveChatGPT(_ tools: [String], defaults: UserDefaults = .standard) {
        defaults.set(HostedTool.supported(tools, by: .chatgpt), forKey: chatGPTKey)
    }
}
