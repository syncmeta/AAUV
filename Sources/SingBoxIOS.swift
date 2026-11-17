#if os(iOS)
import Foundation
import Network
import NetworkExtension
import Observation

@MainActor @Observable
final class SingBox {
    static let instructions = "导入受信任的 sing-box JSON，需包含 TUN 入站。iOS 会在首次启动时请求添加 VPN 配置。"
    private static let bundleID = "com.pendingname.aauv.Tunnel"
    private var manager: NETunnelProviderManager?
    private var state: NEVPNStatus = .invalid
    private var startup = ProxyStartup.idle
    private var submittedStart = false
    private var lastStatusAfterStop: NEVPNStatus?
    private var lastError: String?
    @ObservationIgnored private(set) var routeRevision = UUID()
    private let preference: ProxyRoutePreference
    // Configuration imports can change the persisted request intent while this
    // instance lives. Never let a stale cache silently permit direct requests.
    private var requiresTunnel: Bool { preference.required }

    var status: String {
        if startup == .cancelled { return "正在取消连接…" }
        if startup == .pending { return submittedStart ? "正在连接…" : "正在准备 VPN 配置…" }
        switch state {
        case .connected: return "sing-box 隧道已连接"
        case .connecting, .reasserting: return "正在连接…"
        case .disconnecting: return "正在断开…"
        default: return lastError ?? (requiresTunnel ? "代理已启用，等待重新连接" : String(localized: "使用系统网络"))
        }
    }

    var canStop: Bool {
        startup.inProgress || [.connected, .connecting, .disconnecting, .reasserting].contains(state)
    }

    init(defaults: UserDefaults = .standard, observeTunnel: Bool = true) {
        preference = ProxyRoutePreference(defaults: defaults)
        guard observeTunnel else { return }
        Task { [weak self] in
            guard let self else { return }
            let existing = try? await Self.existingManager()
            if self.manager == nil { self.manager = existing }
            self.refresh()
            for await _ in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
                let previous = self.state
                self.refresh()
                guard self.state == .disconnected,
                      previous == .connecting || previous == .connected || previous == .reasserting,
                      let connection = self.manager?.connection else { continue }
                connection.fetchLastDisconnectError { [weak self] error in
                    guard error != nil else { return }
                    Task { @MainActor in
                        guard let self, self.state == .disconnected, !self.startup.inProgress,
                              self.lastStatusAfterStop == nil else { return }
                        self.lastError = "隧道已断开。请检查配置、节点和 iOS 的 VPN 设置。"
                    }
                }
            }
        }
    }

    func start(with data: Data) async throws {
        guard !canStop else { return }
        try Task.checkCancellation()
        guard let content = String(data: data, encoding: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = root["inbounds"] as? [[String: Any]],
              inbounds.contains(where: { $0["type"] as? String == "tun" }) else {
            throw ChatClient.ClientError.message("配置需要包含 TUN 入站。")
        }
        lastError = nil
        routeRevision = UUID()
        guard preference.setRequired(true) else {
            let message = "无法保存代理设置，请重试。"
            lastError = message
            throw ChatClient.ClientError.message(message)
        }
        startup = .pending
        defer {
            submittedStart = false
            startup = .idle
            refresh()
        }
        do {
            let vpn = try await Self.existingManager() ?? NETunnelProviderManager()
            try startup.check()
            manager = vpn
            try requireIdle(vpn.connection)

            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = Self.bundleID
            configuration.serverAddress = "AAUV sing-box"
            vpn.protocolConfiguration = configuration
            vpn.localizedDescription = "AAUV 大绿豆"
            vpn.isEnabled = true
            try await vpn.saveToPreferences()
            try startup.check()
            try await vpn.loadFromPreferences()
            try startup.check()
            try requireIdle(vpn.connection)

            lastStatusAfterStop = nil
            try vpn.connection.startVPNTunnel(options: ["config": content as NSString])
            submittedStart = true
            try await waitForConnection(vpn.connection)
        } catch {
            let cancelled = startup == .cancelled || Task.isCancelled
            if submittedStart, lastStatusAfterStop == nil { stop() }
            if cancelled { throw CancellationError() }
            lastError = "隧道未能连接。请检查配置、节点和 iOS 的 VPN 设置。"
            throw error
        }
    }

    func stop() {
        startup.cancel()
        routeRevision = UUID()
        guard let connection = manager?.connection,
              submittedStart || [.connected, .connecting, .reasserting, .disconnecting].contains(connection.status) else { return }
        lastStatusAfterStop = connection.status
        state = .disconnecting
        connection.stopVPNTunnel()
    }

    func reset() {
        guard !canStop else { return }
        if preference.setRequired(false) {
            routeRevision = UUID()
            lastError = nil
        } else {
            lastError = String(localized: "无法切换至系统网络，仍需内置隧道")
        }
    }

    func configurationForRequest() throws -> ProxyConfiguration? {
        if requiresTunnel && (startup.inProgress || lastStatusAfterStop != nil || state != .connected || manager?.connection.status != .connected) {
            throw ChatClient.ClientError.message(String(localized: "代理隧道未连接。请等待连接，或在设置中选择“使用系统网络”。"))
        }
        return nil
    }

    private func refresh() {
        let current = manager?.connection.status ?? .invalid
        if let previous = lastStatusAfterStop {
            if current != previous { lastStatusAfterStop = current }
            // A submitted start can report progress after the stop call returns.
            if [.connecting, .connected, .reasserting].contains(current) {
                if state != .disconnecting {
                    state = .disconnecting
                    routeRevision = UUID()
                }
                if current != previous { manager?.connection.stopVPNTunnel() }
                return
            }
        }
        guard current != state else { return }
        state = current
        routeRevision = UUID()
    }

    private func requireIdle(_ connection: NEVPNConnection) throws {
        guard [.invalid, .disconnected].contains(connection.status) else {
            throw ChatClient.ClientError.message("系统 VPN 仍在连接或断开，请稍后再试。")
        }
    }

    private func waitForConnection(_ connection: NEVPNConnection) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var observedStartup = false
        while ContinuousClock.now < deadline {
            try startup.check()
            switch connection.status {
            case .connected: return
            case .connecting, .reasserting: observedStartup = true
            case .disconnected where !observedStartup: break
            default:
                throw ChatClient.ClientError.message("系统 VPN 未能连接，请检查节点或 VPN 设置。")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatClient.ClientError.message("等待系统 VPN 连接超时，请重试。")
    }

    private static func existingManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
        }
    }
}
#endif
