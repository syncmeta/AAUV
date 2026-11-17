import Foundation

private final class CatalogFixture: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var count = 0
    private let failFirst: Bool

    init(failFirst: Bool = false) {
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
        self.failFirst = failFirst
    }

    func read() throws -> [ProxyNodes.Entry] {
        precondition(!Thread.isMainThread)
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        if current == 1 {
            started.yield(())
            precondition(release.wait(timeout: .now() + 5) == .success,
                         "Waiting for a node credential blocked the main actor.")
            if failFirst { throw CocoaError(.fileReadNoPermission) }
        }
        return [.init(link: "socks5://127.0.0.1:1080#\(current)", description: nil,
                      label: "fixture \(current)", problem: nil)]
    }
}

@main
struct ProxyNodeCatalogTests {
    @MainActor static func main() async throws {
        let link = "trojan://SYNTHETIC_NODE_SECRET@node.example:443?allowInsecure=1#Test"
        let entry = try ProxyNodes.prepareImport("  " + link + "\n")
        precondition(entry.link == link && entry.description?.insecure == true)
        precondition(!entry.label.contains("SYNTHETIC_NODE_SECRET") && entry.problem == nil)
        for invalid in ["https://example.invalid/subscription", link + "\n" + link, "vless://invalid", ""] {
            do {
                _ = try ProxyNodes.prepareImport(invalid)
                preconditionFailure("Invalid single-node import was accepted")
            } catch {}
        }
        for failFirst in [false, true] {
            let fixture = CatalogFixture(failFirst: failFirst)
            let catalog = ProxyNodeCatalog(read: { try fixture.read() })
            let old = catalog.reload()
            for await _ in fixture.events.prefix(1) {}
            precondition(catalog.loading && !catalog.ready)
            let replacement = catalog.reload()
            fixture.release.signal()
            await old.value
            await replacement.value
            precondition(catalog.ready && !catalog.loading && catalog.problem == nil)
            precondition(catalog.entries.map(\.label) == ["fixture 2"])
        }

        let cancelledFixture = CatalogFixture()
        let cancelled = ProxyNodeCatalog(read: { try cancelledFixture.read() })
        let pending = cancelled.reload()
        for await _ in cancelledFixture.events.prefix(1) {}
        cancelled.cancel()
        cancelledFixture.release.signal()
        await pending.value
        precondition(!cancelled.ready && !cancelled.loading && cancelled.entries.isEmpty && cancelled.problem == nil)

        let retryFixture = CatalogFixture(failFirst: true)
        let retry = ProxyNodeCatalog(read: { try retryFixture.read() })
        let failed = retry.reload()
        for await _ in retryFixture.events.prefix(1) {}
        retryFixture.release.signal()
        await failed.value
        precondition(!retry.ready && !retry.loading && retry.problem != nil)
        await retry.reload().value
        precondition(retry.ready && retry.problem == nil && retry.entries.map(\.label) == ["fixture 2"])
        print("Node credential reads kept the main actor responsive, rejected late success/error after reload or dismissal, and retried failed reads.")
    }
}
