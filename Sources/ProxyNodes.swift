import Foundation
import CryptoKit
import Network
import Observation
import AAUVCore

typealias ProxyRouteCheck = @MainActor @Sendable () throws -> Void

struct ProxyRequestRoute {
    let configuration: ProxyConfiguration?
    let validate: ProxyRouteCheck
}

enum ProxyStartup {
    case idle, pending, cancelled

    var inProgress: Bool { self != .idle }

    mutating func cancel() {
        if self == .pending { self = .cancelled }
    }

    func check() throws {
        try Task.checkCancellation()
        guard self == .pending else { throw CancellationError() }
    }
}

extension SingBox {
    func requestRoute() throws -> ProxyRequestRoute {
        let configuration = try configurationForRequest()
        let revision = routeRevision
        return ProxyRequestRoute(configuration: configuration) { [weak self] in
            guard let self, self.routeRevision == revision else {
                throw ChatClient.ClientError.message("网络路径已改变，请按当前代理设置重新请求。")
            }
            _ = try self.configurationForRequest()
        }
    }
}

struct ProxyRoutePreference {
    private static let key = "proxyRequiresTunnel"
    var defaults = UserDefaults.standard
    var required: Bool { defaults.bool(forKey: Self.key) }

    func setRequired(_ required: Bool) -> Bool {
        defaults.set(required, forKey: Self.key)
        // Persist the routing decision before starting a connection or permitting direct requests.
        if defaults.synchronize() { return true }
        defaults.set(true, forKey: Self.key)
        return false
    }
}

enum ProxyNodes {
    static let revisionKey = "proxyNodesRevision"
    private static let schemes: Set<String> = ["ss", "vmess", "vless", "trojan", "hysteria2", "hy2", "tuic", "socks5", "pendingnet"]

    struct Description: Decodable, Sendable {
        let name: String
        let kind: String
        let insecure: Bool
    }

    struct Entry: Identifiable, Sendable {
        let link: String
        let description: Description?
        let label: String
        let problem: String?

        var id: String {
            SHA256.hash(data: Data(link.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func recognizes(_ link: String) -> Bool {
        guard let separator = link.range(of: "://") else { return false }
        return schemes.contains(link[..<separator.lowerBound].lowercased())
    }

    static func normalize(_ links: [String]) throws -> [String] {
        var seen = Set<String>()
        let unique = links.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { seen.insert($0).inserted }
        guard unique.count <= 128, unique.reduce(0, { $0 + $1.utf8.count }) <= 768 * 1024,
              unique.allSatisfy({ recognizes($0) && $0.utf8.count <= 16_384 && !$0.contains(where: { $0.isNewline }) }) else {
            throw ChatClient.ClientError.message("节点列表无效，最多可保存 128 条单节点链接。")
        }
        return unique
    }

    static func load() throws -> [Entry] {
        let links = try APIKey.importedConfiguration()?.nodeLinks ?? []
        return links.map { link in
            do {
                let description = try inspect(link)
                return Entry(link: link, description: description, label: "\(description.name) · \(description.kind.uppercased())",
                             problem: nil)
            } catch {
                let scheme = link.components(separatedBy: "://").first?.lowercased() ?? ""
                let label = schemes.contains(scheme) ? scheme.uppercased() : "节点"
                return Entry(link: link, description: nil, label: "\(label) · 当前无法连接", problem: error.localizedDescription)
            }
        }
    }

    static func inspect(_ link: String) throws -> Description {
        if link.lowercased().hasPrefix("pendingnet://") {
            throw ChatClient.ClientError.message("PendingNet 专用链接需先由对应客户端兑换或导出标准单节点链接。")
        }
        var error: NSError?
        let text = AauvcoreInspectNodeLink(link, &error)
        if let error { throw localized(error) }
        return try JSONDecoder().decode(Description.self, from: Data(text.utf8))
    }

    // Validate one link without reading or writing credentials or connecting.
    static func prepareImport(_ input: String) throws -> Entry {
        guard let link = try normalize([input]).first else {
            throw ChatClient.ClientError.message(String(localized: "请粘贴一条单节点链接。"))
        }
        let description = try inspect(link)
        return Entry(link: link, description: description,
                     label: "\(description.name) · \(description.kind.uppercased())", problem: nil)
    }

    static func add(_ link: String) throws {
        try update { $0 + [link] }
    }

    static func remove(_ link: String) throws {
        try update { $0.filter { $0 != link } }
    }

    static func changed() {
        UserDefaults.standard.set(UUID().uuidString, forKey: revisionKey)
    }

    private static func update(_ change: ([String]) -> [String]) throws {
        var settings = try APIKey.importedConfiguration() ?? PortableSettings(endpoint: "https://api.openai.com/v1", model: "")
        settings.nodeLinks = try normalize(change(settings.nodeLinks ?? []))
        try APIKey.saveConfiguration(settings)
        changed()
    }

    static func config(for entry: Entry, allowInsecure: Bool) throws -> Data {
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        var error: NSError?
        let text = AauvcoreBuildSingBoxNode(entry.link, platform, 0, allowInsecure, &error)
        if let error { throw localized(error) }
        return Data(text.utf8)
    }

    private static func localized(_ error: NSError) -> ChatClient.ClientError {
        let text: String
        switch error.localizedDescription {
        case "unsupported_node_transport":
            text = "当前代理内核不支持此传输方式，例如 XHTTP 或多路 gRPC。"
        case "unsupported_shadowsocks_plugin":
            text = "当前内核只支持 obfs-local 和 v2ray-plugin 插件。"
        case "unsupported_node_ech":
            text = "当前连接方式无法应用此节点的 ECH 配置。"
        case "unsupported_certificate_pin":
            text = "当前内核无法应用此链接指定的证书指纹校验。"
        case "unsupported_certificate_names":
            text = "当前内核无法应用此链接指定的证书名称校验。"
        case "unsupported_reality_verification":
            text = "当前内核无法应用此 Reality 链接指定的 ML-DSA-65 验证。"
        case "unsupported_hysteria_obfuscation":
            text = "当前内核无法应用此 Hysteria2 混淆配置。"
        case "unsupported_vless_encryption", "unsupported_vless_flow":
            text = "当前内核不支持此 VLESS 加密或流控配置。"
        case "node_requires_insecure_confirmation":
            text = "此节点要求跳过证书校验，请先确认。"
        case "local_proxy_port_unavailable":
            text = "无法分配本机代理端口，请重试。"
        default:
            text = "节点链接格式无效，或包含当前内核不支持的配置。"
        }
        return .message(text)
    }
}

@MainActor @Observable
final class ProxyNodeCatalog {
    private(set) var entries: [ProxyNodes.Entry] = []
    private(set) var loading = false
    private(set) var problem: String?
    private var loaded = false
    var ready: Bool { loaded && !loading && problem == nil }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let read: @Sendable () throws -> [ProxyNodes.Entry]

    init(read: @escaping @Sendable () throws -> [ProxyNodes.Entry] = { try ProxyNodes.load() }) {
        self.read = read
    }

    @discardableResult func reload() -> Task<Void, Never> {
        task?.cancel()
        loading = true
        loaded = false
        problem = nil
        let read = read
        let pending = Task { @MainActor in
            defer { if !Task.isCancelled { loading = false } }
            do {
                let result = try await APIKey.readInBackground(read)
                try Task.checkCancellation()
                entries = result
                loaded = true
            } catch is CancellationError {
                return
            } catch {
                problem = error.localizedDescription
            }
        }
        task = pending
        return pending
    }

    func cancel() {
        task?.cancel()
        loading = false
        loaded = false
    }
}
