import Foundation
import Libbox
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var platform = TunnelPlatformInterface(self)
    private var server: LibboxCommandServer?
    private var config: String?

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let config = options?["config"] as? String, !config.isEmpty else {
            throw TunnelError.message("请在 AAUV 中导入 sing-box 配置。")
        }
        let base = URL.applicationSupportDirectory.appending(path: "AAUV")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = base.path
        setup.tempPath = NSTemporaryDirectory()
        setup.logMaxLines = 32
        setup.oomKillerEnabled = true
        var setupError: NSError?
        guard LibboxSetup(setup, &setupError) else {
            throw TunnelError.message("无法初始化 sing-box。")
        }

        var creationError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &creationError) else {
            throw TunnelError.message("无法创建 sing-box 服务。")
        }
        self.server = server
        self.config = config
        do {
            try server.start()
            try await reloadService()
        } catch {
            close()
            throw TunnelError.message("sing-box 无法启动，请检查配置和节点。")
        }
    }

    func reloadService() async throws {
        guard let server, let config else { throw TunnelError.message("sing-box 未启动。") }
        try server.startOrReloadService(config, options: LibboxOverrideOptions())
    }

    func stopService() {
        cancelTunnelWithError(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async { close() }

    override func sleep() async { server?.pause() }
    override func wake() { server?.wake() }

    private func close() {
        try? server?.closeService()
        platform.reset()
        server?.close()
        server = nil
        config = nil
    }
}
