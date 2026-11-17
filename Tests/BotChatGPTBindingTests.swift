import Foundation
import Darwin

private enum FixtureFailure: Error { case unavailable }

private final class BlockingNativeRead: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let value: OAuthCredentials

    init(_ value: OAuthCredentials) {
        self.value = value
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func read(_ id: String) -> OAuthCredentials? {
        precondition(!Thread.isMainThread, "The editor blocked the UI thread to read credentials")
        started.yield(())
        precondition(release.wait(timeout: .now() + 5) == .success, "The main actor could not release a background read")
        return id == value.clientID ? value : nil
    }
}

@MainActor
private final class AsyncSelectionGate {
    private var continuation: CheckedContinuation<ChatGPTPlanSession.Selection?, Error>?
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func read() async throws -> ChatGPTPlanSession.Selection? {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.yield(())
        }
    }

    // Deliberately ignores Task cancellation so the coordinator, rather than the
    // fake transport, must reject a superseded late completion.
    func complete(_ result: ChatGPTPlanSession.Selection?) {
        let pending = continuation
        continuation = nil
        precondition(pending != nil)
        pending?.resume(returning: result)
    }
}

@main
struct BotChatGPTBindingTests {
    @MainActor static func main() async throws {
        let first = OAuthCredentials(flow: .chatgptPlan, accessToken: "synthetic-first-access",
                                    refreshToken: "synthetic-first-refresh", clientID: "oaiapp_binding_first")
        let second = OAuthCredentials(flow: .chatgptPlan, accessToken: "synthetic-second-access",
                                     refreshToken: "synthetic-second-refresh", clientID: "oaiapp_binding_second")
        if CommandLine.arguments.contains("--legacy-probe") {
            var bot = BotSnapshot(name: "fixture", endpoint: "https://preview.invalid/v1", model: "fixture",
                                  loginMethod: .chatgpt, chatGPTClientID: first.clientID)
            let failedRead: () throws -> OAuthCredentials? = { throw FixtureFailure.unavailable }
            // Exact original onChange assignment, with only the credential read
            // injected. A transient read failure must not discard this binding.
            bot.chatGPTClientID = (try? failedRead())?.clientID
            if bot.chatGPTClientID != first.clientID {
                print("BEFORE: injected failed read executed the original automatic-binding expression; existing CID was cleared (expected retained, actual nil).")
                exit(42)
            }
            exit(0)
        }

        let suite = "com.pendingname.aauv.synthetic.bot-binding.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if let metadata = ProcessInfo.processInfo.environment["AAUV_BOT_BINDING_METADATA_FILE"] {
            try JSONSerialization.data(withJSONObject: ["privateDefaultsSuite": suite])
                .write(to: URL(fileURLWithPath: metadata))
        }
        func reset() {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(first.clientID, forKey: ChatGPTPlanSession.selectionKey)
            defaults.set([first.clientID!], forKey: "preferredNativeChatGPTRegistrations")
        }

        reset()
        let coordinator = BotChatGPTBinding()
        let gate = BlockingNativeRead(first)
        let ticket = coordinator.begin()
        var applied: String?
        let pending = Task {
            try await coordinator.readCurrentAccount(for: ticket, apply: { id in
                precondition(coordinator.isReading && !coordinator.canSave(method: .chatgpt, clientID: first.clientID),
                             "Save became available before the selected account was published")
                applied = id
            }) {
                try await ChatGPTPlanSession.selectionForRequest(clientID: nil, defaults: defaults,
                    native: { gate.read($0) }, imported: { _ in nil })
            }
        }
        for await _ in gate.events.prefix(1) {}
        var heartbeat = false
        let pulse = Task { @MainActor in heartbeat = true }
        await pulse.value
        precondition(heartbeat && coordinator.isReading)
        precondition(!coordinator.canSave(method: .chatgpt, clientID: nil))
        precondition(!coordinator.canSave(method: .chatgpt, clientID: first.clientID))
        do {
            try coordinator.requireReadyToSave(method: .chatgpt, clientID: nil)
            preconditionFailure("Save escaped an in-progress automatic binding")
        } catch BotChatGPTBinding.BindingError.reading {}
        gate.release.signal()
        let selected = try await pending.value
        precondition(selected == first.clientID && applied == selected && !coordinator.isReading)
        precondition(coordinator.canSave(method: .chatgpt, clientID: selected))
        print("Background native selection released the main actor; automatic binding blocks premature save, then returns the selected synthetic CID.")

        for result in ["error", "nil", "empty"] {
            let keeper = BotChatGPTBinding()
            let ticket = keeper.begin()
            var original = first.clientID
            do {
                original = try await keeper.readCurrentAccount(for: ticket, read: {
                    if result == "error" { throw FixtureFailure.unavailable }
                    if result == "nil" { return nil }
                    var empty = first
                    empty.clientID = "  "
                    return .init(credentials: empty, source: .native)
                })
                preconditionFailure("An invalid/failed read produced an account")
            } catch {}
            precondition(original == first.clientID && !keeper.isReading)
            precondition(keeper.canSave(method: .chatgpt, clientID: original))
            precondition(!keeper.canSave(method: .chatgpt, clientID: nil))
            do {
                try keeper.requireReadyToSave(method: .chatgpt, clientID: nil)
                preconditionFailure("An unbound ChatGPT profile could be saved")
            } catch BotChatGPTBinding.BindingError.missingAccount {}
        }
        print("Failed, missing and empty-account reads preserve existing bindings; unbound ChatGPT profiles cannot save.")

        for reason in ["method-switch", "closed-editor", "task-cancel"] {
            let keeper = BotChatGPTBinding()
            let gate = AsyncSelectionGate()
            let ticket = keeper.begin()
            var original = first.clientID
            let task = Task {
                _ = try await keeper.readCurrentAccount(for: ticket, apply: { original = $0 }) { try await gate.read() }
            }
            for await _ in gate.events.prefix(1) {}
            if reason == "task-cancel" { task.cancel() }
            else { keeper.cancel() }
            gate.complete(.init(credentials: second, source: .native))
            do { try await task.value; preconditionFailure("A cancelled editor published a late account") }
            catch is CancellationError {}
            precondition(original == first.clientID && !keeper.isReading)
        }
        print("Method switching, closing and task cancellation reject late completions without clearing the previous account.")

        for newestFinishesFirst in [false, true] {
            let keeper = BotChatGPTBinding()
            let older = AsyncSelectionGate(), newer = AsyncSelectionGate()
            let oldTicket = keeper.begin()
            var published = first.clientID
            let old = Task {
                _ = try await keeper.readCurrentAccount(for: oldTicket, apply: { published = $0 }) { try await older.read() }
            }
            for await _ in older.events.prefix(1) {}
            let newTicket = keeper.begin()
            let new = Task {
                _ = try await keeper.readCurrentAccount(for: newTicket, apply: { published = $0 }) { try await newer.read() }
            }
            for await _ in newer.events.prefix(1) {}
            if newestFinishesFirst {
                newer.complete(.init(credentials: second, source: .native))
                try await new.value
                precondition(published == second.clientID && !keeper.isReading)
                older.complete(.init(credentials: first, source: .native))
            } else {
                older.complete(.init(credentials: first, source: .native))
                do { try await old.value; preconditionFailure("Superseded result was accepted") }
                catch is CancellationError {}
                precondition(keeper.isReading, "The old read cleared the new read's progress/save guard")
                newer.complete(.init(credentials: second, source: .native))
                try await new.value
            }
            do { try await old.value; preconditionFailure("Superseded result was accepted") }
            catch is CancellationError {}
            precondition(published == second.clientID && !keeper.isReading)
        }
        print("Both completion orders preserve the newest selection; old reads cannot reset new progress or overwrite the new CID.")

        let superseded = BotChatGPTBinding()
        let oldTicket = superseded.begin()
        _ = superseded.begin()
        var readCalled = false
        do {
            _ = try await superseded.readCurrentAccount(for: oldTicket, read: { readCalled = true; return nil })
            preconditionFailure("A stale pre-start ticket read credentials")
        } catch is CancellationError {}
        precondition(!readCalled && superseded.isReading)
        superseded.cancel()

        for change in ["default", "revision", "native-write", "source"] {
            reset()
            let keeper = BotChatGPTBinding(), gate = BlockingNativeRead(first)
            let ticket = keeper.begin()
            var original = first.clientID
            let task = Task {
                let id = try await keeper.readCurrentAccount(for: ticket, read: {
                    try await ChatGPTPlanSession.selectionForRequest(clientID: nil, defaults: defaults,
                        native: { gate.read($0) }, imported: { _ in nil })
                })
                try keeper.validate(ticket)
                original = id
            }
            for await _ in gate.events.prefix(1) {}
            switch change {
            case "default": defaults.set(second.clientID, forKey: ChatGPTPlanSession.selectionKey)
            case "revision": defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
            case "native-write": APIKey.announceNativeChatGPTWrite(clientID: first.clientID!, defaults: defaults)
            default: defaults.set([], forKey: "preferredNativeChatGPTRegistrations")
            }
            gate.release.signal()
            do { try await task.value; preconditionFailure("An outdated global account/source read was accepted") }
            catch is ChatClient.ClientError {}
            precondition(original == first.clientID && !keeper.isReading)
        }
        print("The existing async selector still rejects default/source/import/native-revision changes during editor reads.")

        for method in [LoginMethod.byok, .copilot] {
            var bot = LocalBot(configuration: .init(name: "fixture", endpoint: "https://preview.invalid/v1", model: "fixture",
                                                    loginMethod: method, apiProtocol: "responses", chatGPTClientID: first.clientID))
            try coordinator.requireReadyToSave(method: method, clientID: bot.configuration.chatGPTClientID)
            bot = try bot.validated()
            precondition(bot.configuration.chatGPTClientID == nil)
        }
        print("Keeping the hidden draft CID across method changes does not persist ChatGPT bindings into BYOK/Copilot profiles.")
        print("BotChatGPTBindingTests passed with synthetic credentials/private defaults only; no real Keychain/network/GUI.")
    }
}
