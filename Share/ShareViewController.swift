import SwiftUI
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { SharedProvider.accepts($0) }
        let content = ShareSheet(providers: providers) { [weak self] saved in
            if saved { self?.extensionContext?.completeRequest(returningItems: nil) }
            else { self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
        }
        let host = UIHostingController(rootView: content)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}

private struct ShareSheet: View {
    let providers: [NSItemProvider]
    let close: (Bool) -> Void
    @State private var task: Task<Void, Never>?
    @State private var savedCount: Int?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let savedCount {
                    Text("已存入 \(savedCount) 个文件。打开大绿豆查看。")
                } else if providers.isEmpty {
                    Text("没有可以导入的文件。")
                } else if task != nil {
                    ProgressView("正在保存文件…")
                } else if failure == nil {
                    Text("将 \(providers.count) 个文件存入大绿豆。")
                }
                if let failure {
                    ScrollView { Text(failure).foregroundStyle(.secondary) }
                        .frame(maxHeight: 140)
                }
                if savedCount != nil {
                    Button("完成") { close(true) }.buttonStyle(.borderedProminent)
                } else if !providers.isEmpty {
                    Button("存入大绿豆", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(task != nil)
                }
            }
            .padding(20)
            .navigationTitle(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AAUV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if savedCount == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            task?.cancel()
                            close(false)
                        }
                    }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func save() {
        failure = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                guard let inbox = ShareInbox.shared() else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                guard providers.count <= 100 else {
                    throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey: "一次最多可分享 100 个文件。"])
                }
                let stage = try inbox.begin(botSnapshot: inbox.recentBotSnapshot())
                defer { try? FileManager.default.removeItem(at: stage) }
                var failures: [String] = []
                for (index, provider) in providers.enumerated() {
                    try Task.checkCancellation()
                    do { try await SharedProvider.copy(provider, index: index, into: stage, inbox: inbox) }
                    catch {
                        try Task.checkCancellation()
                        failures.append(provider.suggestedName ?? "第 \(index + 1) 个文件")
                    }
                }
                try Task.checkCancellation()
                let count = providers.count - failures.count
                if count > 0 {
                    try inbox.publish(stage)
                    savedCount = count
                }
                if !failures.isEmpty { failure = "无法保存以下文件：\n" + failures.joined(separator: "\n") }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

private enum SharedProvider {
    static func accepts(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || !fileTypes(provider).isEmpty
    }

    static func copy(_ provider: NSItemProvider, index: Int, into stage: URL, inbox: ShareInbox) async throws {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        continuation.resume(with: Result {
                            if let error { throw error }
                            guard let url = item as? URL, url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
                            try inbox.copyCoordinated(url, index: index, into: stage)
                        })
                    }
                }
                return
            } catch {
                if fileTypes(provider).isEmpty { throw error }
            }
        }

        var failure: Error = CocoaError(.fileReadUnknown)
        let suggestion = provider.suggestedName
        for type in fileTypes(provider) {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        continuation.resume(with: Result {
                            if let error { throw error }
                            guard let url else { throw CocoaError(.fileReadUnknown) }
                            var name = suggestion ?? url.lastPathComponent
                            if (name as NSString).pathExtension.isEmpty {
                                let suffix = url.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "" : url.pathExtension
                                if !suffix.isEmpty { name += "." + suffix }
                            }
                            // The provider's URL expires as soon as this callback returns.
                            try inbox.copy(url, name: name, index: index, into: stage)
                        })
                    }
                }
                return
            } catch { failure = error }
        }
        throw failure
    }

    private static func fileTypes(_ provider: NSItemProvider) -> [UTType] {
        provider.registeredTypeIdentifiers.compactMap { UTType($0) }.filter { type in
            !type.conforms(to: .url) && !type.conforms(to: .directory)
                && (type.conforms(to: .data) || type.conforms(to: .content))
        }
    }
}
