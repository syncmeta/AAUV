#if os(macOS)
import Foundation
import Network
import Observation
import AAUVCore

@MainActor @Observable
final class SingBox {
    static let instructions = String(localized: "导入受信任的 sing-box JSON。使用一个监听 127.0.0.1 的 mixed 入站，出站按配置运行。内置代理不会修改系统或浏览器的代理设置。")
    private(set) var status: String
    var canStop: Bool { startup.inProgress || process != nil }
    private var startup = ProxyStartup.idle
    private var process: Process?
    private var proxy: ProxyConfiguration?
    private var httpProxyURL: URL?
    @ObservationIgnored private(set) var routeRevision = UUID()
    private let preference: ProxyRoutePreference
    private let checkLocalProxy: @Sendable (Int, String) async -> Bool

    init(defaults: UserDefaults = .standard, checkLocalProxy: @escaping @Sendable (Int, String) async -> Bool = { port, password in
        await Task.detached { AauvcoreCheckLocalProxy(port, "aauv", password) }.value
    }) {
        preference = ProxyRoutePreference(defaults: defaults)
        self.checkLocalProxy = checkLocalProxy
        status = preference.required ? "代理已启用，等待重新连接" : String(localized: "使用系统网络")
    }

    func start(with data: Data) async throws {
        guard !canStop else { return }
        try Task.checkCancellation()
        let password = UUID().uuidString
        let (port, configData) = try Self.securedConfig(data, password: password)
        routeRevision = UUID()
        status = "代理已启用，等待重新连接"
        guard preference.setRequired(true) else {
            throw ChatClient.ClientError.message("无法保存代理设置，请重试。")
        }
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "sing-box") else {
            throw ChatClient.ClientError.message("应用包里找不到 sing-box。")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "aauv-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var launched: Process?
        startup = .pending
        defer { startup = .idle }
        do {
            let config = directory.appending(path: "config.json")
            try configData.write(to: config, options: .atomic)
            let configInput = try FileHandle(forReadingFrom: config)
            try FileManager.default.removeItem(at: config)

            let child = Process()
            child.executableURL = binary
            child.currentDirectoryURL = directory
            child.arguments = ["run", "-c", "stdin"]
            child.standardInput = configInput
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] finished in
                try? FileManager.default.removeItem(at: directory)
                Task { @MainActor in
                    guard let self, self.process === finished else { return }
                    self.process = nil
                    self.proxy = nil
                    self.httpProxyURL = nil
                    self.routeRevision = UUID()
                    self.status = "sing-box 已退出（\(finished.terminationStatus)）。"
                }
            }
            try child.run()
            process = child
            launched = child
            status = "正在验证本机代理…"
            var ready = false
            for _ in 0..<20 {
                try startup.check()
                guard process === child, child.isRunning else { break }
                ready = await checkLocalProxy(Int(port.rawValue), password)
                try startup.check()
                if ready { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try startup.check()
            guard ready, process === child, child.isRunning else {
                if child.isRunning { child.terminate() }
                throw ChatClient.ClientError.message("本机代理未能启动，请检查配置或重试。")
            }
            var route = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
            route.applyCredential(username: "aauv", password: password)
            route.allowFailover = false
            var http = URLComponents()
            http.scheme = "http"
            http.host = "127.0.0.1"
            http.port = Int(port.rawValue)
            http.user = "aauv"
            http.password = password
            httpProxyURL = http.url
            proxy = route
            status = "sing-box 已启动 · 127.0.0.1:\(port)"
        } catch {
            if let launched, process === launched, launched.isRunning, proxy == nil { launched.terminate() }
            if process == nil, !(error is CancellationError) { status = "代理启动失败" }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() {
        guard canStop else { return }
        startup.cancel()
        routeRevision = UUID()
        proxy = nil
        httpProxyURL = nil
        if let process {
            status = "正在停止…"
            if process.isRunning { process.terminate() }
        }
    }

    func reset() {
        guard !canStop else { return }
        routeRevision = UUID()
        status = preference.setRequired(false) ? String(localized: "使用系统网络") : String(localized: "无法切换至系统网络，仍需内置代理")
    }

    func configurationForRequest() throws -> ProxyConfiguration? {
        if preference.required && (proxy == nil || process?.isRunning != true) {
            throw ChatClient.ClientError.message(String(localized: "sing-box 当前不可用。请重新启动，或在设置中选择“使用系统网络”。"))
        }
        return proxy
    }

    func copilotProxyURL() throws -> URL? {
        if try configurationForRequest() != nil, httpProxyURL == nil {
            throw ChatClient.ClientError.message("Copilot 无法使用当前代理。")
        }
        return httpProxyURL
    }

    static func securedConfig(_ data: Data, password: String) throws -> (NWEndpoint.Port, Data) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = root["inbounds"] as? [[String: Any]], inbounds.count == 1,
              var inbound = inbounds.first, inbound["type"] as? String == "mixed",
              inbound["listen"] as? String == "127.0.0.1",
              let port = inbound["listen_port"] as? Int, (1024...65535).contains(port),
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)),
              inbound["set_system_proxy"] as? Bool != true else {
            throw ChatClient.ClientError.message("请配置单个 mixed 入站，监听 127.0.0.1 和 1024–65535 端口，并关闭 set_system_proxy。")
        }
        inbound["users"] = [["username": "aauv", "password": password]]
        root["inbounds"] = [inbound]
        return (endpointPort, try JSONSerialization.data(withJSONObject: root))
    }
}
#endif
