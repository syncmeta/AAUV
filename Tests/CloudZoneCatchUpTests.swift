import CloudKit
import Foundation

private enum CheckFailure: Error { case failed(String), apply }

@main @MainActor
struct CloudZoneCatchUpTests {
    private static var checks = 0
    private static let a = Data("token-a".utf8)
    private static let b = Data("token-b".utf8)
    private static let c = Data("token-c".utf8)
    private static func expect(_ condition: Bool, _ name: String) throws {
        checks += 1
        if !condition { throw CheckFailure.failed(name) }
    }
    private final class Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { let c = continuation; continuation = nil; c?.resume() }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure.failed("gate_timeout")
    }
    private static func page(_ token: Data, more: Bool = false) -> CloudZoneChangePage {
        .init(records: [], deletions: [], token: token, moreComing: more)
    }
    private static func fixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "aauv-zone-cursor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root.appending(path: "cursor.json"))
    }
    private static func feed(_ file: URL, owner: String = "owner", allowed: @escaping @MainActor () -> Bool = { true },
                             fetch: @escaping @MainActor (Data?) async throws -> CloudZoneChangePage,
                             apply: @escaping @MainActor (CloudZoneChangePage) async throws -> Void = { _ in }) -> CloudZoneCatchUp {
        .init(file: file, owner: owner, scope: "synthetic-zone", permitted: allowed, fetch: fetch, apply: apply)
    }
    private static func seed(_ file: URL) async throws {
        try await feed(file, fetch: { token in try expect(token == nil, "seed_starts_empty"); return page(a) }).run()
    }
    private static func failure(_ operation: () async throws -> Void) async throws {
        var failed = false
        do { try await operation() } catch { failed = true }
        try expect(failed, "expected_failure")
    }
    static func main() async {
        do {
            try await paginationAndRestart()
            try await rejectedApplyDoesNotAdvance()
            try await cancelledLatePageDoesNotApply()
            try await revokedPermissionDoesNotApply()
            try await overlappingChecksCoalesce()
            try await wrongOwnerDoesNotFetch()
            try await expiryAndNetworkFailure()
            try await stalledPaginationDoesNotApply()
            print("Cloud zone catch-up passed \(checks) checks: pagination/restart, apply failure, late cancellation/permission fence, coalescing, owner binding, explicit token expiry, transient failure and nonprogress. Cloud containers/network/Keychain calls0.")
        } catch { print("Cloud zone catch-up FAIL: \(error)"); exit(1) }
    }
    private static func paginationAndRestart() async throws {
        try await fixture { file in
            var fetched: [Data?] = []; var applied: [Data] = []
            let original = feed(file, fetch: { token in
                fetched.append(token)
                return token == nil ? page(a, more: true) : page(b)
            }, apply: { applied.append($0.token) })
            try await original.run()
            try expect(fetched == [nil, a] && applied == [a, b], "ordered_pages")
            var restartedToken: Data?
            try await feed(file, fetch: { token in restartedToken = token; return page(c) }).run()
            try expect(restartedToken == b, "restart_uses_last_applied_page")
        }
    }
    private static func rejectedApplyDoesNotAdvance() async throws {
        try await fixture { file in
            try await seed(file); let original = try Data(contentsOf: file)
            let rejected = feed(file, fetch: { _ in page(b) }, apply: { _ in throw CheckFailure.apply })
            try await failure { try await rejected.run() }
            try expect(try Data(contentsOf: file) == original, "failed_apply_preserves_cursor")
            var resumed: Data?
            try await feed(file, fetch: { token in resumed = token; return page(c) }).run()
            try expect(resumed == a, "failed_page_is_replayed")
        }
    }
    private static func cancelledLatePageDoesNotApply() async throws {
        try await fixture { file in
            let gate = Gate(); var applied = 0
            let current = feed(file, fetch: { _ in await gate.wait(); return page(a) }, apply: { _ in applied += 1 })
            let task = Task { try await current.run() }
            try await wait { gate.entered }
            let pending = current.cancel(); gate.release()
            try await failure { try await task.value }
            _ = try? await pending?.value
            try expect(applied == 0 && !FileManager.default.fileExists(atPath: file.path), "cancelled_late_page_fenced")
        }
    }
    private static func revokedPermissionDoesNotApply() async throws {
        try await fixture { file in
            let gate = Gate(); var allowed = true; var applied = 0
            let current = feed(file, allowed: { allowed }, fetch: { _ in await gate.wait(); return page(a) }, apply: { _ in applied += 1 })
            let task = Task { try await current.run() }
            try await wait { gate.entered }; allowed = false; gate.release()
            try await failure { try await task.value }
            try expect(applied == 0 && !FileManager.default.fileExists(atPath: file.path), "late_account_or_configuration_fenced")
        }
    }
    private static func overlappingChecksCoalesce() async throws {
        try await fixture { file in
            let gate = Gate(); var fetched = 0; var applied = 0
            let current = feed(file, fetch: { _ in fetched += 1; await gate.wait(); return page(a) }, apply: { _ in applied += 1 })
            let first = Task { try await current.run() }; try await wait { gate.entered }
            let second = Task { try await current.run() }
            await Task.yield(); gate.release()
            try await first.value; try await second.value
            try expect(fetched == 1 && applied == 1, "simultaneous_checks_share_page")
        }
    }
    private static func wrongOwnerDoesNotFetch() async throws {
        try await fixture { file in
            try await seed(file); let original = try Data(contentsOf: file); var fetched = 0
            let other = feed(file, owner: "other", fetch: { _ in fetched += 1; return page(b) })
            try await failure { try await other.run() }
            try expect(fetched == 0 && (try Data(contentsOf: file)) == original, "owner_mismatch_preserved")
        }
    }
    private static func expiryAndNetworkFailure() async throws {
        try await fixture { file in
            try await seed(file); var tokens: [Data?] = []
            try await feed(file, fetch: { token in
                tokens.append(token)
                if token != nil { throw CKError(.changeTokenExpired) }
                return page(b)
            }).run()
            try expect(tokens == [a, nil], "only_explicit_expiry_restarts_once")
            let original = try Data(contentsOf: file); var failures = 0
            let failed = feed(file, fetch: { _ in failures += 1; throw CKError(.networkUnavailable) })
            try await failure { try await failed.run() }
            try expect(failures == 1 && (try Data(contentsOf: file)) == original, "network_error_does_not_reset_or_retry")
        }
    }
    private static func stalledPaginationDoesNotApply() async throws {
        try await fixture { file in
            try await seed(file); let original = try Data(contentsOf: file); var applied = 0
            let stalled = feed(file, fetch: { _ in page(a, more: true) }, apply: { _ in applied += 1 })
            try await failure { try await stalled.run() }
            try expect(applied == 0 && (try Data(contentsOf: file)) == original, "stalled_page_rejected")
        }
    }
}
