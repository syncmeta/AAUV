import Foundation

@main
struct KeychainReadTests {
    @MainActor static func main() async throws {
        let release = DispatchSemaphore(value: 0)
        let (events, started) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await APIKey.readInBackground {
                precondition(!Thread.isMainThread)
                started.yield(())
                precondition(release.wait(timeout: .now() + 5) == .success,
                             "A waiting keychain read blocked the main actor.")
                return 1
            }
        }
        for await _ in events.prefix(1) {}
        let cancelled = Task {
            try await APIKey.readInBackground { () -> Int in
                fatalError("A cancelled queued read accessed the keychain.")
            }
        }
        cancelled.cancel()
        release.signal()
        let completed = try await first.value
        precondition(completed == 1)
        do {
            _ = try await cancelled.value
            fatalError("A cancelled read returned a result.")
        } catch is CancellationError {}

        for shouldFail in [false, true] {
            let releaseSecond = DispatchSemaphore(value: 0)
            let (secondEvents, secondStarted) = AsyncStream<Void>.makeStream()
            let inFlight = Task {
                try await APIKey.readInBackground {
                    secondStarted.yield(())
                    precondition(releaseSecond.wait(timeout: .now() + 5) == .success)
                    if shouldFail { throw CocoaError(.fileReadNoPermission) }
                    return "a stale fixture result"
                }
            }
            for await _ in secondEvents.prefix(1) {}
            inFlight.cancel()
            releaseSecond.signal()
            do {
                _ = try await inFlight.value
                fatalError("An old read overwrote a newer credential selection.")
            } catch is CancellationError {}
        }
        print("Credential reads kept the main actor responsive and rejected cancelled queued and in-flight results.")
    }
}
