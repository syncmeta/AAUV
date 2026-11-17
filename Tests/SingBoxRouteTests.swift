import Foundation

@main
struct SingBoxRouteTests {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3, let preferences = UserDefaults(suiteName: arguments[2]) {
            let proxy = SingBox(defaults: preferences)
            let blocked = isBlocked(proxy)
            precondition(blocked == (arguments[1] == "require-proxy"))
            return
        }

        precondition(arguments.count == 2)
        let suite = "com.pendingname.aauv.fixture.proxy.\(UUID())"
        guard let preferences = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        defer { preferences.removePersistentDomain(forName: suite) }
        let proxy = SingBox(defaults: preferences)
        let direct = try proxy.configurationForRequest()
        precondition(direct == nil)
        let directRoute = try proxy.requestRoute()

        let link = "socks5://synthetic:mock-password@127.0.0.1:\(arguments[1])#Loopback"
        let info = try ProxyNodes.inspect(link)
        let entry = ProxyNodes.Entry(link: link, description: info, label: info.name, problem: nil)
        let config = try ProxyNodes.config(for: entry, allowInsecure: false)
        try await checkStoppedStartup(config)
        try await proxy.start(with: config)
        defer { proxy.stop() }
        let route = try proxy.configurationForRequest()
        precondition(route != nil)
        let connectedRoute = try proxy.requestRoute()
        try connectedRoute.validate()
        expectInvalid(directRoute)
        try await checkRequestIsBlocked(directRoute)
        try checkAnotherProcess("require-proxy", suite: suite)

        let session = ChatClient.session(proxy: route, resourceTimeout: 5)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://aauv-test.invalid/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"mock"}"#.utf8)
        let (data, _) = try await session.data(for: request)
        precondition(String(decoding: data, as: UTF8.self).contains("proxy ok"))

        guard let connectProxy = try proxy.copilotProxyURL() else { throw URLError(.cannotConnectToHost) }
        try checkHTTPConnect(through: connectProxy)

        proxy.stop()
        precondition(isBlocked(proxy))
        expectInvalid(connectedRoute)
        for _ in 0..<100 {
            if !proxy.canStop { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!proxy.canStop)
        try checkAnotherProcess("require-proxy", suite: suite)
        proxy.reset()
        let restored = try proxy.configurationForRequest()
        precondition(restored == nil)
        let restoredRoute = try proxy.requestRoute()
        try restoredRoute.validate()
        expectInvalid(directRoute)
        expectInvalid(connectedRoute)
        try checkAnotherProcess("direct", suite: suite)

        guard var invalid = try JSONSerialization.jsonObject(with: config) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        invalid["outbounds"] = [["type": "fixture-invalid"]]
        let invalidConfig = try JSONSerialization.data(withJSONObject: invalid)
        do {
            try await proxy.start(with: invalidConfig)
            fatalError("Expected sing-box to reject the outbound")
        } catch {
            precondition(isBlocked(proxy))
        }
        try checkAnotherProcess("require-proxy", suite: suite)
        print("sing-box forwarded through SOCKS and HTTP CONNECT, and rejected late readiness and stale routes.")
    }

    @MainActor private static func checkStoppedStartup(_ config: Data) async throws {
        let suite = "com.pendingname.aauv.fixture.proxy.\(UUID())"
        guard let preferences = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        defer { preferences.removePersistentDomain(forName: suite) }
        let probe = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let proxy = SingBox(defaults: preferences) { _, _ in
            probe.continuation.yield(())
            probe.continuation.finish()
            for await _ in release.stream { break }
            return true
        }
        let start = Task { try await proxy.start(with: config) }
        defer {
            release.continuation.finish()
            proxy.stop()
        }
        for await _ in probe.stream { break }
        precondition(proxy.canStop && isBlocked(proxy))
        proxy.stop()
        precondition(isBlocked(proxy))
        release.continuation.yield(())
        do {
            try await start.value
            fatalError("Cancelled startup accepted a late successful readiness probe")
        } catch is CancellationError {}
        precondition(isBlocked(proxy))
        for _ in 0..<100 {
            if !proxy.canStop { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!proxy.canStop)
        try checkAnotherProcess("require-proxy", suite: suite)
    }

    @MainActor private static func expectInvalid(_ route: ProxyRequestRoute) {
        do {
            try route.validate()
            fatalError("Expected an invalidated network route")
        } catch is ChatClient.ClientError {
            return
        } catch {
            fatalError("Unexpected error from a stale route")
        }
    }

    private static func checkRequestIsBlocked(_ route: ProxyRequestRoute) async throws {
        let configuration = ChatClient.Configuration(baseURL: URL(string: "http://127.0.0.1:1/v1")!,
                                                     model: "fixture", key: "")
        do {
            _ = try await ChatClient.reply(to: [.init(role: .user, content: "测试")],
                                           configuration: configuration, proxy: route.configuration,
                                           validateRoute: route.validate, willSend: {
                                               fatalError("The stale request must not be marked as submitted")
                                           })
            fatalError("The stale request must not be sent")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("网络路径已改变"))
        }

        let scratch = try PrivateTemporaryDirectory()
        let source = scratch.url.appending(path: "fixture.bin")
        try Data().write(to: source)
        let size = 11 * 1024 * 1024
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: UInt64(size))
        try writer.close()
        let file = RequestAttachment(name: source.lastPathComponent, mediaType: "application/octet-stream",
                                     url: source, size: size)
        do {
            let _: String = try await ChatClient.withRequestFiles(
                [file], configuration: configuration, proxy: route.configuration,
                validateRoute: route.validate, onCleanupFailure: nil
            ) { _ in
                fatalError("The stale attachment request must not reach model submission")
            }
            fatalError("The stale attachment upload must not be sent")
        } catch let error as ChatClient.ClientError {
            precondition(error.localizedDescription.contains("网络路径已改变"))
        }
    }

    @MainActor private static func isBlocked(_ proxy: SingBox) -> Bool {
        do {
            _ = try proxy.configurationForRequest()
            return false
        } catch {
            return true
        }
    }

    private static func checkAnotherProcess(_ expectation: String, suite: String) throws {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = [expectation, suite]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
    }

    private static func checkHTTPConnect(through proxy: URL) throws {
        let curl = Process()
        let input = Pipe()
        let output = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "--config", "-", "--noproxy", "", "--proxytunnel", "--fail", "--silent",
                          "--max-time", "5", "--data", #"{"model":"mock"}"#, "http://aauv-test.invalid/v1/responses"]
        curl.standardInput = input
        curl.standardOutput = output
        try curl.run()
        try input.fileHandleForWriting.write(contentsOf: Data("proxy = \"\(proxy.absoluteString)\"\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        precondition(curl.terminationStatus == 0 && String(decoding: data, as: UTF8.self).contains("proxy ok"))
    }
}
