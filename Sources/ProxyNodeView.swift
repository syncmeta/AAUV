import SwiftUI

struct ProxyNodeView: View {
    let proxy: SingBox
    @AppStorage(ProxyNodes.revisionKey) private var revision = ""
    @State private var catalog = ProxyNodeCatalog()
    @AppStorage("selectedProxyNode") private var selection = ""
    @State private var confirmation: ProxyNodes.Entry?
    @State private var busy = false
    @State private var problem: String?
    @State private var nodeLink = ""
    @State private var importTask: Task<Void, Never>?
    @State private var importMessage: String?

    private var selected: ProxyNodes.Entry? { catalog.entries.first { $0.id == selection } }

    var body: some View {
        Section("单节点代理") {
            TextField("粘贴单节点链接", text: $nodeLink, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .privacySensitive()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .disabled(proxy.canStop || busy)
            Button("导入节点", action: importNode)
                .disabled(proxy.canStop || busy || !catalog.ready || nodeLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if importTask != nil { ProgressView("正在导入节点…") }
            Text("支持 VLESS、VMess、Shadowsocks（ss）、Trojan、Hysteria2（hy2）、TUIC 和 SOCKS5。导入后不会自动连接。")
                .font(.footnote)
            if let importMessage { Text(importMessage).font(.footnote) }
            if catalog.loading { ProgressView("正在读取本机钥匙串…") }
            if catalog.problem != nil { Button("重新读取钥匙串", action: reload) }
            if catalog.ready && catalog.entries.isEmpty {
                Text("导入单节点链接后，可在这里选择连接。").font(.footnote)
            } else if !catalog.entries.isEmpty {
                Picker("节点", selection: $selection) {
                    if !selection.isEmpty && selected == nil {
                        Text("所选节点尚未导入").tag(selection)
                    }
                    ForEach(catalog.entries) { entry in Text(entry.label).tag(entry.id) }
                }
                .disabled(proxy.canStop || busy || !catalog.ready)
                if let selected {
                    if let detail = selected.problem { Text(detail).font(.footnote) }
                    Button("连接所选节点") {
                        if selected.description?.insecure == true { confirmation = selected }
                        else { connect(selected, allowInsecure: false) }
                    }
                    .disabled(selected.description == nil || proxy.canStop || busy || !catalog.ready)
                    Button("移除所选节点", role: .destructive) {
                        do {
                            try ProxyNodes.remove(selected.link)
                            selection = ""
                            reload()
                        } catch { problem = error.localizedDescription }
                    }
                    .disabled(proxy.canStop || busy || !catalog.ready)
                }
            }
            if catalog.ready && !selection.isEmpty && selected == nil {
                Text("所选节点尚未导入。可导入对应节点凭证，或手动选择其他节点。")
                    .font(.footnote)
            }
            if let problem { Text(problem).font(.footnote) }
            if let problem = catalog.problem { Text(problem).font(.footnote) }
            #if os(iOS)
            Text("连接使用系统 VPN，设备流量会按隧道规则转发。").font(.footnote)
            Text("未启用内置隧道时，AAUV 使用系统网络，可能经过已连接的 VPN 或 Wi-Fi 代理。浏览器授权页面使用浏览器的网络设置。").font(.footnote)
            #elseif os(macOS)
            Text("未启用内置代理时，AAUV 使用系统网络设置，可能经过系统代理。浏览器授权页面使用浏览器的网络设置。").font(.footnote)
            #endif
        }
        .onAppear { reload() }
        .onChange(of: revision) { reload() }
        .onChange(of: catalog.entries.map(\.id)) {
            if selection.isEmpty { selection = catalog.entries.first?.id ?? "" }
        }
        .onDisappear { importTask?.cancel(); catalog.cancel() }
        .alert("允许此节点跳过证书校验？", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { entry in
            Button("取消", role: .cancel) {}
            Button("仍然连接") { connect(entry, allowInsecure: true) }
        } message: { _ in
            Text("无法验证节点服务器的身份。请只连接你信任的节点。")
        }
    }

    private func reload() {
        problem = nil
        confirmation = nil
        catalog.reload()
    }

    private func importNode() {
        guard !busy, !proxy.canStop, catalog.ready else { return }
        let input = nodeLink
        busy = true
        problem = nil
        importMessage = nil
        importTask = Task { @MainActor in
            defer { busy = false; importTask = nil }
            do {
                let entry = try await APIKey.readInBackground { try ProxyNodes.prepareImport(input) }
                try Task.checkCancellation()
                guard !proxy.canStop, catalog.ready else {
                    throw ChatClient.ClientError.message(String(localized: "代理状态已变化，请重新导入节点。"))
                }
                // Keep the existing synchronous update boundary: it reads the
                // latest configuration here and changes only nodeLinks.
                try ProxyNodes.add(entry.link)
                selection = entry.id
                nodeLink = ""
                reload()
                importMessage = String(localized: "节点已导入并选中，尚未连接。")
            } catch is CancellationError {
                return
            } catch let error as ChatClient.ClientError {
                problem = error.localizedDescription
            } catch let error as APIKey.KeychainError {
                problem = error.localizedDescription
            } catch {
                problem = String(localized: "未能导入节点，请重试。")
            }
        }
    }

    private func connect(_ entry: ProxyNodes.Entry, allowInsecure: Bool) {
        guard !busy, !proxy.canStop, catalog.ready, selected?.id == entry.id else { return }
        busy = true
        problem = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let config = try ProxyNodes.config(for: entry, allowInsecure: allowInsecure)
                try await proxy.start(with: config)
            } catch is CancellationError {
                return
            } catch { problem = error.localizedDescription }
        }
    }
}
