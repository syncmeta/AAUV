import Darwin
import Foundation

// A refresh must keep this lease from before its provider exchange until its
// compare-and-replace finishes. Imports take an exclusive lock on the same file,
// so they cannot stage a journal containing a token being rotated.
@MainActor
final class CredentialRefreshLease {
    nonisolated static var defaultStoreFile: URL {
        URL.applicationSupportDirectory.appending(path: "AAUV/conversations.json")
    }

    private var descriptor: Int32?

    private init(file: URL) throws {
        let path = file.deletingLastPathComponent().appending(path: "configuration-import.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            close(descriptor)
            throw ChatClient.ClientError.message("配置导入正在进行，请稍后重试授权续期。")
        }
        self.descriptor = descriptor
    }

    static func acquire(
        file: URL = CredentialRefreshLease.defaultStoreFile,
        checkPending: @escaping @Sendable () throws -> Void = { try APIKey.checkNoPendingConfigurationImport() }
    ) async throws -> CredentialRefreshLease {
        try Task.checkCancellation()
        let lease = try CredentialRefreshLease(file: file)
        do {
            // An earlier interrupted import may have released its lock while
            // leaving a durable journal. Check it while our shared lock is held.
            try await APIKey.readInBackground(checkPending)
            try Task.checkCancellation()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    // Call explicitly from defer; do not rely on ARC to hold the descriptor for
    // the whole exchange and save. Releasing twice must not close a reused fd.
    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        if let descriptor { close(descriptor) }
    }
}
