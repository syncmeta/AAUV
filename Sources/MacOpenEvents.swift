#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor
final class MacOpenEvents: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var pending: [URL] = []
    private weak var foregroundSync: CloudSync?
    private var hasResignedActive = false

    func bindForegroundSync(_ sync: CloudSync) {
        foregroundSync = sync
    }

    func applicationDidResignActive(_ notification: Notification) {
        hasResignedActive = true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Initial activation belongs to RunIntent startup. Multiple windows use
        // this same delegate, so one return dispatches one coalesced request.
        guard hasResignedActive else { return }
        hasResignedActive = false
        Task { [weak sync = foregroundSync] in
            await sync?.foregroundActivated()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
    }

    func takePending() -> [URL] {
        guard !pending.isEmpty else { return [] }
        let urls = pending
        pending.removeAll()
        return urls
    }
}
#endif
