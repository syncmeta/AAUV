import Foundation
import Observation

/// Short-lived editor intent only. Credential selection and its revision/source
/// checks stay in ChatGPTPlanSession; this type never retains a token or invents
/// a registration for an unbound profile.
@MainActor @Observable
final class BotChatGPTBinding {
    struct Ticket: Equatable {
        fileprivate let id: UUID
    }

    typealias ReadSelection = @MainActor () async throws -> ChatGPTPlanSession.Selection?

    private var current: Ticket?
    private(set) var isReading = false

    enum BindingError: LocalizedError {
        case reading, missingAccount
        var errorDescription: String? {
            switch self {
            case .reading: return String(localized: "正在读取 ChatGPT 账户，请稍候。")
            case .missingAccount: return String(localized: "请先在设置里通过 ChatGPT 登录，再选择当前账户。")
            }
        }
    }

    func begin() -> Ticket {
        let ticket = Ticket(id: UUID())
        current = ticket
        isReading = true
        return ticket
    }

    func cancel() {
        current = nil
        isReading = false
    }

    func isCurrent(_ ticket: Ticket) -> Bool { current == ticket }

    func validate(_ ticket: Ticket) throws {
        try Task.checkCancellation()
        guard isCurrent(ticket) else { throw CancellationError() }
    }

    func readCurrentAccount(
        for ticket: Ticket,
        apply: @MainActor (String) throws -> Void = { _ in },
        read: ReadSelection = { try await ChatGPTPlanSession.selectionForRequest(clientID: nil) }
    ) async throws -> String {
        defer { if isCurrent(ticket) { isReading = false } }
        try validate(ticket)
        let selection = try await read()
        try validate(ticket)
        guard let id = selection?.credentials.clientID,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BindingError.missingAccount
        }
        try ChatGPTPlanSession.requireNotSigningOut(id)
        // Keep the save guard through the synchronous MainActor publication.
        // No editor event can interleave between validation and this callback.
        try apply(id)
        return id
    }

    func canSave(method: LoginMethod, clientID: String?) -> Bool {
        !isReading && (method != .chatgpt || clientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    func requireReadyToSave(method: LoginMethod, clientID: String?) throws {
        guard !isReading else { throw BindingError.reading }
        guard canSave(method: method, clientID: clientID) else { throw BindingError.missingAccount }
    }
}
