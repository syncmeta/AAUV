import Foundation
import Security

private actor KeychainReader {
    static let shared = KeychainReader()

    func read<Value: Sendable>(_ operation: @Sendable () throws -> Value) throws -> Value {
        try Task.checkCancellation()
        let result = Result(catching: operation)
        try Task.checkCancellation()
        return try result.get()
    }
}

// Only non-secret defaults belong here. The credential vault stays in Keychain.
struct ImportedBotMetadata: Codable, Sendable {
    let endpoint: String
    let model: String
    let loginMethod: LoginMethod?
    let hostedTools: [String]?
    let chatGPTClientID: String?
    let apiProtocol: String?
    let providerDefaults: ProviderDefaults?

    init(_ configuration: PortableSettings) {
        endpoint = configuration.endpoint
        model = configuration.model
        loginMethod = configuration.loginMethod
        hostedTools = configuration.hostedTools
        chatGPTClientID = (try? configuration.loginCredentials())?.chatGPTAuthorization()?.clientID
        apiProtocol = configuration.apiProtocol
        providerDefaults = configuration.providerDefaults
    }

    var configuration: PortableSettings {
        PortableSettings(endpoint: endpoint, model: model, loginMethod: loginMethod, apiProtocol: apiProtocol,
                         hostedTools: hostedTools, providerDefaults: providerDefaults)
    }
}

final class ImportedBotMetadataCache: @unchecked Sendable {
    static let key = "importedBotMetadata"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var generation = UUID()

    init(defaults: UserDefaults) { self.defaults = defaults }

    func readGeneration() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func readConfiguration(_ read: () throws -> String) throws -> PortableSettings? {
        let generation = readGeneration()
        let text = try read()
        let configuration = text.isEmpty ? nil : try JSONDecoder().decode(PortableSettings.self, from: Data(text.utf8))
        record(configuration, ifCurrent: generation)
        return configuration
    }

    func publish(_ configuration: PortableSettings, write: (String) throws -> Void) throws {
        let data = try JSONEncoder().encode(configuration)
        try write(String(decoding: data, as: UTF8.self))
        record(configuration)
    }

    func record(_ configuration: PortableSettings?, ifCurrent expected: UUID? = nil) {
        let metadata = configuration.map(ImportedBotMetadata.init)
        let data = metadata.flatMap { try? JSONEncoder().encode($0) }
        lock.lock()
        defer { lock.unlock() }
        guard expected == nil || expected == generation else { return }
        generation = UUID()
        if let data { defaults.set(data, forKey: Self.key) }
        else { defaults.removeObject(forKey: Self.key) }
    }

    static func read(defaults: UserDefaults = .standard) -> ImportedBotMetadata? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ImportedBotMetadata.self, from: data)
    }
}

enum APIKey {
    private static let importedConfigurationURL = URL(string: "https://aauv.invalid/imported-configuration")!
    private static let pendingImportURL = URL(string: "https://aauv.invalid/pending-configuration-import")!
    private static let nativeCopilotURL = URL(string: "https://aauv.invalid/github-copilot")!
    private static let importedCopilotURL = URL(string: "https://aauv.invalid/imported-github-copilot")!
    private static let nativeChatGPTRoot = URL(string: "https://aauv.invalid/chatgpt/")!
    private static let preferNativeCopilotKey = "preferNativeCopilot"
    private static let metadata = ImportedBotMetadataCache(defaults: .standard)

    static let revisionKey = "importedCredentialsRevision"
    static let byokRevisionKey = "byokCredentialsRevision"
    static let copilotRevisionKey = "copilotCredentialsRevision"
    static let copilotSignOutPendingKey = "copilotLocalSignOutPending"
    private static let nativeChatGPTReadRevisionPrefix = "nativeChatGPTReadRevision."

    static func readInBackground<Value: Sendable>(_ operation: @Sendable () throws -> Value) async throws -> Value {
        try await KeychainReader.shared.read(operation)
    }

    static func isReservedHost(_ host: String) -> Bool {
        host.lowercased() == "aauv.invalid" || host.lowercased() == "aauv.invalid."
    }

    static func importedConfiguration() throws -> PortableSettings? {
        try metadata.readConfiguration { try readRaw(for: importedConfigurationURL) }
    }

    static func saveConfiguration(_ settings: PortableSettings) throws {
        try requireNoPendingImport()
        try publishConfiguration(settings)
    }

    static func publishConfiguration(_ settings: PortableSettings) throws {
        // Provider token rotations rewrite the shared vault. Only a changed
        // effective BYOK map invalidates a captured BYOK request.
        let previousKeys = try savedCredentials(importedConfiguration()).byokKeys ?? [:]
        let nextKeys = try savedCredentials(settings).byokKeys ?? [:]
        try metadata.publish(settings) { try saveRaw($0, for: importedConfigurationURL) }
        announceCredentialChange()
        if previousKeys != nextKeys { announceBYOKCredentialChange() }
    }

    static func configurationToStore(_ settings: PortableSettings, previous: PortableSettings?) throws -> PortableSettings {
        let incoming = try settings.loginCredentials()
        let existing = try savedCredentials(previous)
        var retained = settings.loginMethod == .copilot ? previous ?? settings : settings
        retained.version = 4
        retained.key = nil
        retained.oauth = nil
        retained.credentials = try existing.merging(incoming)
        let nodes = (previous?.nodeLinks ?? []) + (settings.nodeLinks ?? [])
        retained.nodeLinks = nodes.isEmpty ? nil : try ProxyNodes.normalize(nodes)
        retained.bots = nil
        retained.botInstructions = nil
        return retained
    }

    @MainActor static func stageConfigurationImport(_ settings: PortableSettings) throws -> ConfigurationImport {
        try requireNoPendingImport()
        let previous = try importedConfiguration()
        let incoming = try settings.loginCredentials()
        var retained = try configurationToStore(settings, previous: previous)
        if incoming.copilot == nil, previous?.credentials?.copilot == nil,
           let latest = try storedCopilot(at: importedCopilotURL) {
            retained.credentials?.copilot = latest.transferable
        }
        let pending = ConfigurationImport(settings: settings, vault: retained, previous: previous, incoming: incoming)
        let data = try JSONEncoder().encode(pending)
        try saveRaw(String(decoding: data, as: UTF8.self), for: pendingImportURL)
        return pending
    }

    static func pendingConfigurationImport() throws -> ConfigurationImport? {
        let text = try readRaw(for: pendingImportURL)
        return text.isEmpty ? nil : try JSONDecoder().decode(ConfigurationImport.self, from: Data(text.utf8))
    }

    // Called by startup recovery on the background keychain actor. Older app
    // versions have no metadata cache, so seed it before enabling new requests.
    // An uncommitted journal is discarded; its previous vault remains active.
    static func startupConfigurationImport() throws -> ConfigurationImport? {
        try startupConfigurationImport(readPending: pendingConfigurationImport, readConfiguration: importedConfiguration)
    }

    static func startupConfigurationImport(
        readPending: () throws -> ConfigurationImport?, readConfiguration: () throws -> PortableSettings?
    ) throws -> ConfigurationImport? {
        let pending = try readPending()
        _ = try readConfiguration()
        return pending
    }

    static func clearConfigurationImport() throws {
        try saveRaw("", for: pendingImportURL)
    }

    static func announceConfigurationImport(_ id: UUID, selectsImportedCopilot: Bool) {
        let defaults = UserDefaults.standard
        if selectsImportedCopilot {
            defaults.set(false, forKey: preferNativeCopilotKey)
            defaults.removeObject(forKey: copilotSignOutPendingKey)
            defaults.set(id.uuidString, forKey: copilotRevisionKey)
        }
        defaults.set(id.uuidString, forKey: revisionKey)
        defaults.set(id.uuidString, forKey: byokRevisionKey)
    }

    static func checkNoPendingConfigurationImport() throws {
        try requireNoPendingImport()
    }

    private static func requireNoPendingImport() throws {
        guard try readRaw(for: pendingImportURL).isEmpty else {
            throw ChatClient.ClientError.message("有配置导入正在恢复。请在会话列表重试恢复后再更改凭证或节点。")
        }
    }

    private static func savedCredentials(_ configuration: PortableSettings?) throws -> PortableCredentials {
        guard let configuration else { return PortableCredentials() }
        var credentials = try configuration.loginCredentials()
        if (configuration.loginMethod ?? .byok) == .byok, configuration.key == "" {
            // Older settings used an empty entry to shadow a key in the per-endpoint slot.
            var keys = credentials.byokKeys ?? [:]
            if keys[configuration.endpoint] == nil { keys[configuration.endpoint] = "" }
            credentials.byokKeys = keys
        }
        return credentials
    }

    static func importedChatGPT(clientID: String? = nil) throws -> OAuthCredentials? {
        try savedCredentials(importedConfiguration()).chatGPTAuthorization(clientID: clientID)
    }

    static func importedChatGPTRegistrations() throws -> [String] {
        try savedCredentials(importedConfiguration()).chatGPT?.compactMap(\.clientID) ?? []
    }

    static func replaceImportedChatGPT(_ previous: OAuthCredentials, with credentials: OAuthCredentials) throws {
        guard var configuration = try importedConfiguration() else { throw credentialChanged("ChatGPT") }
        var vault = try savedCredentials(configuration)
        guard let id = credentials.clientID,
              let index = vault.chatGPT?.firstIndex(where: { $0.clientID == id }),
              vault.chatGPT?[index].accessToken == previous.accessToken,
              vault.chatGPT?[index].refreshToken == previous.refreshToken else {
            throw credentialChanged("ChatGPT")
        }
        vault.chatGPT?[index] = credentials.transferable
        configuration.key = nil
        configuration.oauth = nil
        configuration.credentials = vault
        try saveConfiguration(configuration)
    }

    private static func credentialChanged(_ provider: String) -> ChatClient.ClientError {
        .message("续期期间 \(provider) 凭证已更换，请重新发送。")
    }

    static func copilotCredentials() throws -> OAuthCredentials? {
        try selectedCopilot()?.credentials
    }

    private static func selectedCopilot() throws -> (credentials: OAuthCredentials, endpoint: URL)? {
        try requireCopilotActive()
        let preferNative = UserDefaults.standard.bool(forKey: preferNativeCopilotKey)
        if preferNative, let native = try storedCopilot(at: nativeCopilotURL) {
            return (native, nativeCopilotURL)
        }
        let configuration = try importedConfiguration()
        if let bundle = configuration?.credentials?.copilot { return (bundle, importedConfigurationURL) }
        if let legacy = try storedCopilot(at: importedCopilotURL) { return (legacy, importedCopilotURL) }
        if let oauth = configuration?.oauth, oauth.flow == .githubCopilot { return (oauth, importedConfigurationURL) }
        if let native = try storedCopilot(at: nativeCopilotURL) { return (native, nativeCopilotURL) }
        return nil
    }

    private static func storedCopilot(at endpoint: URL) throws -> OAuthCredentials? {
        let text = try readRaw(for: endpoint)
        guard !text.isEmpty else { return nil }
        let credentials = try JSONDecoder().decode(OAuthCredentials.self, from: Data(text.utf8))
        guard credentials.flow == .githubCopilot else { throw CocoaError(.fileReadCorruptFile) }
        return credentials
    }

    static func saveNativeCopilot(_ credentials: OAuthCredentials) throws {
        guard credentials.verifiedSubject?.isEmpty == false else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try saveCopilot(credentials, at: nativeCopilotURL)
        UserDefaults.standard.set(true, forKey: preferNativeCopilotKey)
        UserDefaults.standard.removeObject(forKey: copilotSignOutPendingKey)
        UserDefaults.standard.set(UUID().uuidString, forKey: copilotRevisionKey)
    }

    static func requireCopilotActive(defaults: UserDefaults = .standard) throws {
        guard !defaults.bool(forKey: copilotSignOutPendingKey) else {
            throw ChatClient.ClientError.message("GitHub Copilot 正在本机退出。请重试完成凭证清理。")
        }
    }

    @MainActor static func beginCopilotSignOut(defaults: UserDefaults = .standard) -> String {
        let revision = UUID().uuidString
        // Persist the block before invalidating readers. A partial deletion or
        // interrupted app must never fall back to another retained token slot.
        defaults.set(true, forKey: copilotSignOutPendingKey)
        defaults.set(revision, forKey: copilotRevisionKey)
        return revision
    }

    @MainActor static func finishCopilotSignOut(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: preferNativeCopilotKey)
        defaults.removeObject(forKey: copilotSignOutPendingKey)
        defaults.set(UUID().uuidString, forKey: copilotRevisionKey)
    }

    struct CopilotSignOutSnapshot: Sendable {
        let configurationWithoutCopilot: PortableSettings?
    }

    // Read/normalize on the background Keychain actor. Native and legacy slots
    // are removed unconditionally and need not be decoded to delete their data.
    static func copilotSignOutSnapshot(
        readConfiguration: () throws -> PortableSettings? = importedConfiguration
    ) throws -> CopilotSignOutSnapshot {
        guard var configuration = try readConfiguration() else {
            return CopilotSignOutSnapshot(configurationWithoutCopilot: nil)
        }
        guard configuration.credentials?.copilot != nil || configuration.oauth?.flow == .githubCopilot else {
            // A native/legacy-slot-only logout must not rewrite an unrelated
            // vault or invalidate another provider's in-flight credential read.
            return CopilotSignOutSnapshot(configurationWithoutCopilot: nil)
        }
        var vault = try savedCredentials(configuration)
        vault.copilot = nil
        configuration.key = nil
        configuration.oauth = nil
        configuration.credentials = vault
        return CopilotSignOutSnapshot(configurationWithoutCopilot: configuration)
    }

    // The caller holds a refresh/import lease and checks both identity and
    // vault revisions on MainActor immediately before this non-suspending write.
    @MainActor static func clearCopilotSignOut(
        _ snapshot: CopilotSignOutSnapshot,
        publish: (PortableSettings) throws -> Void = publishConfiguration,
        remove: (URL) throws -> Void = { try saveRaw("", for: $0) }
    ) throws {
        if let configuration = snapshot.configurationWithoutCopilot { try publish(configuration) }
        try remove(nativeCopilotURL)
        try remove(importedCopilotURL)
    }

    static func replaceCopilot(_ previous: OAuthCredentials, with credentials: OAuthCredentials) throws {
        guard let selected = try selectedCopilot(),
              selected.credentials.accessToken == previous.accessToken,
              selected.credentials.refreshToken == previous.refreshToken else {
            throw credentialChanged("GitHub")
        }
        if selected.endpoint == importedConfigurationURL, var configuration = try importedConfiguration() {
            var vault = try savedCredentials(configuration)
            vault.copilot = credentials.transferable
            configuration.key = nil
            configuration.oauth = nil
            configuration.credentials = vault
            try saveConfiguration(configuration)
        } else {
            try saveCopilot(credentials, at: selected.endpoint)
        }
    }

    private static func saveCopilot(_ credentials: OAuthCredentials, at endpoint: URL) throws {
        try requireNoPendingImport()
        try credentials.validateStructure()
        guard credentials.flow == .githubCopilot else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try JSONEncoder().encode(credentials)
        try saveRaw(String(decoding: data, as: UTF8.self), for: endpoint)
    }

    static func nativeChatGPT(clientID: String) throws -> OAuthCredentials? {
        guard let endpoint = nativeChatGPTURL(clientID) else { return nil }
        let text = try readRaw(for: endpoint)
        guard !text.isEmpty else { return nil }
        let credentials = try JSONDecoder().decode(OAuthCredentials.self, from: Data(text.utf8))
        guard credentials.clientID == clientID, credentials.flow == .chatgptPlan else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return credentials
    }

    static func nativeChatGPTRegistrations() throws -> [String] {
        var attributes = query(nativeChatGPTRoot)
        attributes.removeValue(forKey: kSecAttrAccount as String)
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        let prefix = nativeChatGPTRoot.absoluteString
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { return nil }
            let id = String(account.dropFirst(prefix.count))
            return nativeChatGPTURL(id)?.absoluteString == account ? id : nil
        }
    }

    static func saveNativeChatGPT(_ credentials: OAuthCredentials) throws {
        let endpoint = try nativeChatGPTSaveEndpoint(credentials)
        try requireNoPendingImport()
        let data = try JSONEncoder().encode(credentials)
        try saveRaw(String(decoding: data, as: UTF8.self), for: endpoint)
        announceNativeChatGPTWrite(clientID: credentials.clientID!)
    }

    enum NativeChatGPTSaveError: LocalizedError {
        case registration(prefixValid: Bool, length: Int, rejectedScalars: [UInt32])
        case identity
        case address

        var errorDescription: String? {
            switch self {
            case .registration:
                String(localized: "授权已返回，但注册标识无法保存。请保留此提示以便排查。")
            case .identity:
                String(localized: "缺少已验证的 ChatGPT 账户身份，未保存登录凭证。")
            case .address:
                String(localized: "注册标识已通过校验，但本机无法生成凭证存储地址。")
            }
        }
    }

    // Validate before touching Keychain, and distinguish a local registration
    // format failure from an actual Keychain write failure. Never retain the ID
    // or tokens inside the error or its diagnostic record.
    static func nativeChatGPTSaveEndpoint(_ credentials: OAuthCredentials) throws -> URL {
        try credentials.validateStructure()
        guard credentials.flow == .chatgptPlan, credentials.verifiedSubject?.isEmpty == false else {
            throw NativeChatGPTSaveError.identity
        }
        let id = credentials.clientID ?? ""
        guard isNativeRegistrationID(id) else {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
            let rejected = Set(id.unicodeScalars.filter { !allowed.contains($0) }.map(\.value)).sorted()
            throw NativeChatGPTSaveError.registration(prefixValid: id.hasPrefix("oaiapp_"),
                                                      length: id.utf8.count, rejectedScalars: rejected)
        }
        guard let endpoint = nativeChatGPTURL(id) else { throw NativeChatGPTSaveError.address }
        return endpoint
    }

    static func nativeChatGPTReadRevision(clientID: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: nativeChatGPTReadRevisionPrefix + clientID)
    }

    static func announceNativeChatGPTWrite(clientID: String, defaults: UserDefaults = .standard) {
        // This nonce invalidates only an in-flight read of this registration.
        // It is not a long-lived session identity or another provider's epoch.
        defaults.set(UUID().uuidString, forKey: nativeChatGPTReadRevisionPrefix + clientID)
    }

    // Pure identifier validation for references received with synced data.
    // This never queries or creates a Keychain entry.
    static func isNativeRegistrationID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        let prefix: [UInt8] = [111, 97, 105, 97, 112, 112, 95] // oaiapp_
        guard bytes.count > prefix.count, bytes.count <= 256, bytes.starts(with: prefix) else { return false }
        return bytes.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
                (48...57).contains(byte) || byte == 95 || byte == 45
        }
    }

    private static func nativeChatGPTURL(_ id: String) -> URL? {
        guard isNativeRegistrationID(id) else { return nil }
        // Only ASCII letters, digits, '_' and '-' can reach this point. The
        // account address is therefore deterministic, with no path inference or
        // normalization. Existing registrations keep exactly the same address.
        return URL(string: nativeChatGPTRoot.absoluteString + id)
    }

    private static func query(_ endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pendingname.aauv.byok",
            kSecAttrAccount as String: endpoint.absoluteString,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func read(for endpoint: URL) throws -> String {
        guard let host = endpoint.host, !isReservedHost(host) else { throw URLError(.badURL) }
        if let key = try savedCredentials(importedConfiguration()).byokKeys?[endpoint.absoluteString] {
            return key
        }
        return try readRaw(for: endpoint)
    }

    private static func readRaw(for endpoint: URL) throws -> String {
        var attributes = query(endpoint)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return key
    }

    static func save(_ key: String, for endpoint: URL) throws {
        try requireNoPendingImport()
        guard let host = endpoint.host, !isReservedHost(host) else { throw URLError(.badURL) }
        if var configuration = try importedConfiguration() {
            var vault = try savedCredentials(configuration)
            if vault.byokKeys?[endpoint.absoluteString] != nil {
                vault.byokKeys?[endpoint.absoluteString] = key
                configuration.key = nil
                configuration.oauth = nil
                configuration.credentials = vault
                let previousRevision = UserDefaults.standard.string(forKey: byokRevisionKey)
                try saveConfiguration(configuration)
                // An explicit save is also an intent boundary when the same
                // key was saved again; avoid a redundant bump when it changed.
                if previousRevision == UserDefaults.standard.string(forKey: byokRevisionKey) {
                    announceBYOKCredentialChange()
                }
                return
            }
        }
        try saveRaw(key, for: endpoint)
        announceCredentialChange()
        announceBYOKCredentialChange()
    }

    private static func announceBYOKCredentialChange() {
        UserDefaults.standard.set(UUID().uuidString, forKey: byokRevisionKey)
    }

    private static func announceCredentialChange() {
        UserDefaults.standard.set(UUID().uuidString, forKey: revisionKey)
    }

    private static func saveRaw(_ key: String, for endpoint: URL) throws {
        let attributes = query(endpoint)
        if key.isEmpty {
            let status = SecItemDelete(attributes as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let data = Data(key.utf8)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(attributes as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var newItem = attributes
        newItem[kSecValueData as String] = data
        #if os(iOS)
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            if status == errSecUserCanceled { return "已取消钥匙串授权。可以重新读取。" }
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                return "钥匙串尚未允许访问。请确认系统授权提示后重新读取。"
            }
            return "无法访问钥匙串（\(status)）。"
        }
    }
}
