import Foundation

private final class CredentialFixture: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream()
        events = stream.stream
        started = stream.continuation
    }

    func read(_ endpoint: URL) -> String {
        precondition(!Thread.isMainThread && endpoint.host == "127.0.0.1")
        started.yield(())
        precondition(release.wait(timeout: .now() + 5) == .success,
                     "A waiting BYOK read blocked the main actor.")
        return "synthetic-only"
    }
}

@main
struct RequestCredentialsTests {
    @MainActor static func main() async throws {
        let suite = "com.pendingname.aauv.fixture.request-credentials.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = URL(string: "http://127.0.0.1:1/v1")!
        var routeRevision = 0
        func route() -> ProxyRouteCheck {
            let revision = routeRevision
            return {
                guard revision == routeRevision else { throw URLError(.networkConnectionLost) }
            }
        }

        for invalidateCredential in [false, true] {
            let fixture = CredentialFixture()
            let capturedRoute = route()
            let read = Task { @MainActor in
                try await RequestCredentials.read(for: endpoint, validateRoute: capturedRoute, defaults: defaults,
                                                  read: { fixture.read($0) })
            }
            for await _ in fixture.events.prefix(1) {}
            if invalidateCredential { defaults.set(UUID().uuidString, forKey: APIKey.byokRevisionKey) }
            else { routeRevision += 1 }
            fixture.release.signal()
            do {
                _ = try await read.value
                fatalError("A stale credential or route escaped the background read.")
            } catch is ChatClient.ClientError {
                precondition(invalidateCredential)
            } catch is URLError {
                precondition(!invalidateCredential)
            }
        }

        let fixture = CredentialFixture()
        let capturedRoute = route()
        let cancelled = Task { @MainActor in
            try await RequestCredentials.read(for: endpoint, validateRoute: capturedRoute, defaults: defaults,
                                              read: { fixture.read($0) })
        }
        for await _ in fixture.events.prefix(1) {}
        cancelled.cancel()
        fixture.release.signal()
        do {
            _ = try await cancelled.value
            fatalError("A cancelled preparation could use a late keychain result.")
        } catch is CancellationError {}

        let valid = try await RequestCredentials.read(for: endpoint, validateRoute: route(), defaults: defaults,
                                                       read: { _ in "synthetic-only" })
        precondition(valid.key == "synthetic-only")
        try valid.validate()
        defaults.set(UUID().uuidString, forKey: APIKey.byokRevisionKey)
        do {
            try valid.validate()
            fatalError("A prepared voice request retained an obsolete API key.")
        } catch is ChatClient.ClientError {}

        let independent = try await RequestCredentials.read(for: endpoint, validateRoute: route(), defaults: defaults,
                                                             read: { _ in "synthetic-only" })
        defaults.set(UUID().uuidString, forKey: APIKey.revisionKey)
        try independent.validate() // Another provider can rotate the shared vault.
        defaults.set(UUID().uuidString, forKey: ProxyNodes.revisionKey)
        do {
            try independent.validate()
            fatalError("A full configuration import retained the old request intent.")
        } catch is ChatClient.ClientError {}

        let proxy = SingBox(defaults: defaults)
        for registration in [nil, ""] as [String?] {
            let unbound = BotSnapshot(name: "unbound", endpoint: ChatGPTPlanSession.endpoint.absoluteString,
                                      model: "fixture", loginMethod: .chatgpt, apiProtocol: "responses",
                                      chatGPTClientID: registration)
            do {
                _ = try await ModelSession(bot: unbound, instructions: "", proxy: proxy)
                fatalError("An unbound ChatGPT session could select the current account.")
            } catch let error as ChatClient.ClientError {
                precondition(error.localizedDescription.contains("尚未绑定 ChatGPT 账户"))
            }
        }
        let bot = BotSnapshot(name: "fixture", endpoint: endpoint.absoluteString, model: "fixture",
                              loginMethod: .byok, apiProtocol: "responses")
        let session = try await ModelSession(bot: bot, instructions: "", proxy: proxy, readBYOK: { endpoint, validate in
            try await RequestCredentials.read(for: endpoint, validateRoute: validate, defaults: defaults,
                                              read: { _ in "synthetic-only" })
        })
        defaults.set(UUID().uuidString, forKey: APIKey.byokRevisionKey)
        do {
            _ = try await session.reply(to: [.init(role: .user, content: "fixture")], willSend: {
                fatalError("An obsolete key reached model submission.")
            })
            fatalError("A prepared model session retained an obsolete API key.")
        } catch is ChatClient.ClientError {}
        print("BYOK preparation stayed responsive and rejected cancellation, changed routes/credentials and unbound ChatGPT sessions before submission.")
    }
}
