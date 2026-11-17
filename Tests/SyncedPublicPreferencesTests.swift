import Foundation

// Real isolated SQLite peers and explicitly supplied private suites only.
// No standard defaults, vault, CloudSync/container, model or network operation.
@main @MainActor struct SyncedPublicPreferencesTests {
    private static let names: Set<String> = ["p-profile", "p-model-services"]
    private static let seedRevision = "0000000000000000001"
    private static var checks = 0

    private static func check(_ value: Bool, _ label: String = "public preference invariant",
                              file: StaticString = #file, line: UInt = #line) {
        checks += 1
        precondition(value, label, file: file, line: line)
    }
    private static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, label) } catch { check(true, label) }
    }
    private static func profile(_ name: String, _ number: Int) -> LocalDisplayProfile {
        .init(name: name, avatarSeed: String(format: "C5100000-0000-4000-8000-%012d", number))
    }
    private static func service(_ name: String, _ slug: String) -> ModelService {
        .init(name: name, loginMethod: .byok, endpoint: "https://\(slug).invalid/v1", apiProtocol: "responses",
              models: [.init(id: "\(slug)-one", name: "One"), .init(id: "\(slug)-two", name: "Two")])
    }
    private static func data<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    @MainActor private final class Peer {
        let directory: PrivateTemporaryDirectory
        let suite: String
        let defaults: UserDefaults
        let store: ConversationStore
        let sentinels: [String: Any]
        let forbidden: [String]

        init(_ role: String) throws {
            let ownedDirectory = try PrivateTemporaryDirectory()
            let suiteName = "com.pendingname.aauv.synced-public-tests.\(role).\(UUID().uuidString)"
            guard let privateDefaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileReadUnknown) }
            directory = ownedDirectory
            suite = suiteName
            defaults = privateDefaults
            let key = "SYNTHETIC_BYOK_PRIVATE_\(role)_DO_NOT_SYNC"
            let access = "SYNTHETIC_OAUTH_PRIVATE_\(role)_DO_NOT_SYNC"
            let refresh = "SYNTHETIC_REFRESH_PRIVATE_\(role)_DO_NOT_SYNC"
            let node = "socks5://fixture:PRIVATE_NODE_\(role)@node.invalid:1234"
            let activeEndpoint = "https://active-\(role.lowercased()).invalid/v1"
            let activeModel = "ACTIVE_PRIVATE_MODEL_\(role)"
            let oauth = try JSONSerialization.data(withJSONObject: ["accessToken": access, "refreshToken": refresh])
            let nodeData = Data(node.utf8)
            let recent = try SyncedPublicPreferencesTests.data(BotSnapshot(name: "Active private \(role)", endpoint: activeEndpoint,
                model: activeModel, loginMethod: .byok, apiProtocol: "responses"))
            sentinels = ["apiKey": key, "oauth": oauth, "activeNodeCredentials": nodeData,
                "selectedProxyNode": String(repeating: role == "A" ? "a" : "b", count: 64),
                "proxyRequiresTunnel": true, "endpoint": activeEndpoint, "model": activeModel,
                "apiProtocol": "responses", "loginMethod": "byok", "recentBot": recent]
            forbidden = [key, access, refresh, node, nodeData.base64EncodedString(), oauth.base64EncodedString(),
                         activeEndpoint, activeModel, recent.base64EncodedString()]
            store = ConversationStore(file: ownedDirectory.url.appending(path: "State/conversations.json"))
            SyncedPublicPreferencesTests.check(defaults.persistentDomain(forName: suite) == nil, "new private suite")
            for (key, value) in sentinels { defaults.set(value, forKey: key) }
            SyncedPublicPreferencesTests.check(store.loadError == nil && store.conversations.isEmpty && store.bots.isEmpty, "actual empty private SQLite")
        }
        func clearSuite() { defaults.removePersistentDomain(forName: suite) }
        func install(_ profile: LocalDisplayProfile, _ catalog: [ModelService], registered: Bool = false) throws {
            let values = [LocalDisplayProfile.storageKey: try SyncedPublicPreferencesTests.data(profile),
                          ModelServices.storageKey: try SyncedPublicPreferencesTests.data(catalog)]
            if registered { defaults.register(defaults: values) }
            else { for (key, value) in values { defaults.set(value, forKey: key) } }
        }
    }

    private static func records(_ peer: Peer) throws -> [String: ReplicaRecord] {
        let queued = try peer.store.pendingReplica()
        check(queued.allSatisfy { names.contains($0.name) && $0.conversation.isEmpty }, "only two public record kinds queued")
        return Dictionary(uniqueKeysWithValues: queued.map { ($0.name, $0) })
    }
    private static func fingerprint(_ peer: Peer) throws -> [String: String] {
        try records(peer).mapValues { $0.revision + ":" + $0.payload }
    }
    private static func acknowledge(_ peer: Peer) throws {
        for record in try records(peer).values {
            try peer.store.acknowledgeReplica(name: record.name, revision: record.revision)
        }
        check(try records(peer).isEmpty, "real outbox acknowledgments")
    }
    private static func inlinePacket(_ record: ReplicaRecord) -> ReplicaPayload {
        .inline(ReplicaPacket(record: record, files: [:]))
    }
    private static func deliver(_ records: [ReplicaRecord], to peer: Peer) throws {
        for record in records { try peer.store.applyReplicaPayload(inlinePacket(record)) }
        try peer.store.reloadReplica()
    }
    private static func projection(_ peer: Peer, _ profile: LocalDisplayProfile, _ catalog: [ModelService]) throws {
        check(try SyncedPublicPreferences.capture(defaults: peer.defaults) == .init(profile: profile, modelServices: catalog),
              "actual private cache projection")
    }
    private static func strings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let values = value as? [Any] { return values.flatMap(strings) }
        if let values = value as? [String: Any] { return Array(values.keys) + values.values.flatMap(strings) }
        return []
    }
    private static func privacy(_ peers: [Peer]) throws {
        let forbidden = peers.flatMap(\.forbidden)
        for peer in peers {
            let current = peer.defaults.persistentDomain(forName: peer.suite) ?? [:]
            for (key, original) in peer.sentinels {
                check(NSDictionary(dictionary: ["v": current[key] ?? NSNull()]).isEqual(to: ["v": original]), "private sentinel unchanged")
            }
            let packets = try records(peer).values
            for record in packets {
                let fields = try JSONSerialization.jsonObject(with: Data(record.payload.utf8))
                let text = strings(fields).joined(separator: "\n")
                check(forbidden.allSatisfy { !text.contains($0) }, "no local key/OAuth/node/active selection in actual pending payload")
                check((record.name == "p-profile" && record.kind == "profile") ||
                      (record.name == "p-model-services" && record.kind == "model_services"), "public names/kinds paired")
            }
            let captured = try data(SyncedPublicPreferences.capture(defaults: peer.defaults))
            let text = strings(try JSONSerialization.jsonObject(with: captured)).joined(separator: "\n")
            check(forbidden.allSatisfy { !text.contains($0) }, "captured public DTO excludes private sentinels")
        }
    }

    private static func verifySeedAndIndependentRoundTrip() throws {
        let a = try Peer("A"), b = try Peer("B"), missing = try Peer("Missing"), simultaneous = try Peer("Simultaneous")
        defer { for peer in [a, b, missing, simultaneous] { peer.clearSuite() } }
        let pa = profile("Profile A", 1), pb = profile("Local fallback B", 2)
        let sa = service("Catalog A", "catalog-a"), sb = service("Catalog B", "catalog-b")
        try a.install(pa, [sa]); a.store.enablePublicPreferenceSync(defaults: a.defaults)
        let first = try records(a)
        check(Set(first.keys) == names && first.values.allSatisfy { $0.revision == seedRevision }, "first default observation seeds both at1")
        try b.install(pb, [sb], registered: true)
        try deliver(Array(first.values), to: b) // Received durable records precede first local observation.
        b.store.enablePublicPreferenceSync(defaults: b.defaults)
        try projection(b, pa, [sa]); check(try records(b).isEmpty, "initial fallback cannot replace existing remote records")

        try missing.install(pb, [sb])
        try deliver([first["p-profile"]!], to: missing)
        missing.store.enablePublicPreferenceSync(defaults: missing.defaults)
        try projection(missing, pa, [sb])
        let one = try records(missing)
        check(Set(one.keys) == ["p-model-services"] && one.values.first?.revision == seedRevision, "seed only individually absent record")

        try simultaneous.install(pb, [sb]); simultaneous.store.enablePublicPreferenceSync(defaults: simultaneous.defaults)
        check(try records(simultaneous).values.allSatisfy { $0.revision == seedRevision }, "second device has pending fallback seeds")
        try deliver(Array(first.values), to: simultaneous)
        try projection(simultaneous, pa, [sa])
        check(try records(simultaneous).isEmpty, "received server seed wins local pending seed at equal clock1")
        try acknowledge(a)

        // Local profile and remote catalog can advance independently, then merge.
        let edited = profile("Profile A edited", 3), freshCatalog = service("Catalog B edited", "catalog-b-edited")
        try PortableAppPreferences(localProfile: edited).persist(defaults: a.defaults)
        a.store.publicPreferencesDidChange() // The app forwards didChange to this same entry point.
        try PortableAppPreferences(modelServices: [freshCatalog]).persist(defaults: b.defaults)
        b.store.publicPreferencesDidChange()
        let profileEdit = try records(a), catalogEdit = try records(b)
        check(Set(profileEdit.keys) == ["p-profile"] && profileEdit["p-profile"]!.revision > seedRevision, "only profile staged for local profile edit")
        check(Set(catalogEdit.keys) == ["p-model-services"] && catalogEdit["p-model-services"]!.revision > seedRevision, "only catalog staged for local catalog edit")
        let oldTicket = try ModelServices.capture(sa, defaults: a.defaults)
        let retainedTicket = try ModelServices.capture(freshCatalog, defaults: b.defaults)
        let bCatalogRevision = b.defaults.string(forKey: ModelServices.revisionKey)
        var aSignals = 0, bSignals = 0
        a.store.onLocalChange = { aSignals += 1 }; b.store.onLocalChange = { bSignals += 1 }
        try deliver([profileEdit["p-profile"]!], to: b)
        try retainedTicket.validate()
        check(b.defaults.string(forKey: ModelServices.revisionKey) == bCatalogRevision, "profile-only projection does not rewrite catalog")
        try deliver([catalogEdit["p-model-services"]!], to: a)
        rejects("remote catalog invalidates captured refresh ticket") { try oldTicket.validate() }
        try projection(a, edited, [freshCatalog]); try projection(b, edited, [freshCatalog])
        check(try records(a)["p-profile"]?.revision == profileEdit["p-profile"]?.revision, "receiving catalog retains local profile clock")
        check(try records(b)["p-model-services"]?.revision == catalogEdit["p-model-services"]?.revision, "receiving profile retains local catalog clock")
        check(try records(a)["p-model-services"] == nil && records(b)["p-profile"] == nil, "remote projections do not enqueue echo revisions")
        check(aSignals == 0 && bSignals == 0, "remote-only projection emits no new local-change outbox event")
        try acknowledge(a); try acknowledge(b)
        try deliver(Array(first.values), to: a); try deliver(Array(first.values), to: b)
        a.store.publicPreferencesDidChange(); b.store.publicPreferencesDidChange()
        try a.store.synchronizePublicPreferences(force: true); try b.store.synchronizePublicPreferences(force: true)
        try projection(a, edited, [freshCatalog]); try projection(b, edited, [freshCatalog])
        check(try records(a).isEmpty && records(b).isEmpty, "stale/replayed records and refresh notifications cannot churn revisions")

        // [] is explicit intent, unlike an absent catalog; it also fences tickets.
        let clearTicket = try ModelServices.capture(freshCatalog, defaults: a.defaults)
        try ModelServices.replace([], defaults: b.defaults); b.store.publicPreferencesDidChange()
        let clear = try records(b)["p-model-services"]!
        check(try JSONDecoder().decode([ModelService].self, from: Data(clear.payload.utf8)).isEmpty, "real pending [] clear payload")
        try deliver([clear], to: a)
        try projection(a, edited, []); rejects("remote clear invalidates old catalog ticket") { try clearTicket.validate() }
        check(try records(a).isEmpty, "remote [] clear does not become a local edit")
        try acknowledge(b)

        // Actual portable persistence plus the real app notification entry stages both records.
        let importedProfile = profile("Portable profile", 4), importedService = service("Portable catalog", "catalog-portable")
        try PortableAppPreferences(localProfile: importedProfile, modelServices: [importedService]).persist(defaults: a.defaults)
        a.store.publicPreferencesDidChange()
        let imported = try records(a);check(Set(imported.keys) == names, "portable profile/catalog persisted changes reach both outbox records")
        try deliver(Array(imported.values), to: b)
        try projection(b, importedProfile, [importedService]);check(try records(b).isEmpty, "portable remote projection has no echo")
        try privacy([a, b, missing, simultaneous])
    }

    private static func verifyRejectedInputsAndDamagedCaches() throws {
        let peer = try Peer("Invalid")
        defer { peer.clearSuite() }
        let good = profile("Preserved valid profile", 10), catalog = service("Preserved catalog", "catalog-preserved")
        try peer.install(good, [catalog]);peer.store.enablePublicPreferenceSync(defaults: peer.defaults);try acknowledge(peer)
        let profileBytes = peer.defaults.data(forKey: LocalDisplayProfile.storageKey)!
        let catalogBytes = peer.defaults.data(forKey: ModelServices.storageKey)!
        let goodProfile = try JSONSerialization.jsonObject(with: data(good)) as! [String: Any]
        let goodService = try JSONSerialization.jsonObject(with: data(catalog)) as! [String: Any]
        var badProfile = goodProfile;badProfile["key"] = "SYNTHETIC_REJECTED_KEY"
        var badService = goodService;badService["credentials"] = ["accessToken":"SYNTHETIC_REJECTED_OAUTH"]
        var nested = goodService;var model = (nested["models"] as! [[String: Any]])[0]
        model["token"] = "SYNTHETIC_REJECTED_NESTED_TOKEN";nested["models"] = [model]
        let invalid: [(String, String, Any)] = [
            ("p-profile", "profile", badProfile),
            ("p-model-services", "model_services", [badService]),
            ("p-model-services", "model_services", [nested])
        ]
        func rejectRecord(_ name: String, _ kind: String, _ payload: String) throws {
            let record = ReplicaRecord(name: name, kind: kind, conversation: "", revision: "9000000000000000000", payload: payload)
            rejects("invalid public payload rejected before overwrite") { try peer.store.applyReplicaPayload(inlinePacket(record)) }
            try peer.store.reloadReplica()
            check(peer.defaults.data(forKey: LocalDisplayProfile.storageKey) == profileBytes &&
                  peer.defaults.data(forKey: ModelServices.storageKey) == catalogBytes, "rejected incoming leaves cache raw bytes unchanged")
            check(try records(peer).isEmpty, "rejected incoming cannot stage or echo")
            try projection(peer, good, [catalog])
        }
        for (name, kind, object) in invalid {
            try rejectRecord(name, kind, String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        for endpoint in ["https://SYNTHETIC_USERINFO_KEY@catalog.invalid/v1",
                         "https://catalog.invalid/v1?token=SYNTHETIC_QUERY_TOKEN",
                         "https://catalog.invalid/v1#SYNTHETIC_FRAGMENT_TOKEN", "http://nonlocal.invalid/v1"] {
            var service = goodService;service["endpoint"] = endpoint
            try rejectRecord("p-model-services", "model_services", String(decoding: JSONSerialization.data(withJSONObject: [service]), as: UTF8.self))
        }
        try rejectRecord("p-profile", "profile", "{\"name\":\"first\",\"name\":\"second\",\"avatarSeed\":\"\(good.avatarSeed)\"}")

        // Wrong-typed/corrupt local public cache is a failure, never an overwrite/clear intent.
        peer.defaults.set(Data("corrupt profile".utf8), forKey: LocalDisplayProfile.storageKey)
        rejects("corrupt profile capture rejects") { try peer.store.synchronizePublicPreferences(force: true) }
        peer.store.publicPreferencesDidChange(force: true)
        check(peer.store.publicPreferencesError != nil && peer.defaults.data(forKey: LocalDisplayProfile.storageKey) == Data("corrupt profile".utf8), "corrupt profile retained with observable sync error")
        check(try records(peer).isEmpty, "corrupt profile not staged")
        peer.defaults.set(profileBytes, forKey: LocalDisplayProfile.storageKey)
        peer.defaults.set("wrong-typed catalog", forKey: ModelServices.storageKey)
        rejects("wrong-typed catalog capture rejects") { try peer.store.synchronizePublicPreferences(force: true) }
        check(peer.defaults.string(forKey: ModelServices.storageKey) == "wrong-typed catalog" && peer.defaults.data(forKey: LocalDisplayProfile.storageKey) == profileBytes, "damaged catalog cannot partially publish profile")
        check(try records(peer).isEmpty, "damaged catalog not staged")
        peer.defaults.set(catalogBytes, forKey: ModelServices.storageKey)
        try peer.store.synchronizePublicPreferences(force: true)
        try projection(peer, good, [catalog])
        let repairedPending = try records(peer)
        check(peer.store.publicPreferencesError == nil && repairedPending.isEmpty, "explicit fixture repair recovers without revision churn")

        // The exact high revision used above is accepted for valid input, so
        // rejection is not merely a malformed/unsupported-clock false positive.
        let validRemoteProfile = profile("Valid remote control", 11)
        let validRemoteCatalog = service("Valid remote control catalog", "catalog-valid-control")
        for (name, kind, payload) in [
            ("p-profile", "profile", String(decoding: try data(validRemoteProfile), as: UTF8.self)),
            ("p-model-services", "model_services", String(decoding: try data([validRemoteCatalog]), as: UTF8.self))
        ] {
            let record = ReplicaRecord(name: name, kind: kind, conversation: "", revision: "9000000000000000000", payload: payload)
            try deliver([record], to: peer)
        }
        try projection(peer, validRemoteProfile, [validRemoteCatalog])
        check(try records(peer).isEmpty, "valid high-clock control projects without echo")
        try privacy([peer])
    }

    private static func verifyConfigurationGuard() throws {
        let peer = try Peer("Guard")
        defer { peer.clearSuite() }
        let original = profile("Guard original", 20), changed = profile("Guard changed", 21)
        let oldCatalog = service("Guard catalog", "guard-old"), newCatalog = service("Guard new catalog", "guard-new")
        try peer.install(original, [oldCatalog]);peer.store.enablePublicPreferenceSync(defaults: peer.defaults);try acknowledge(peer)
        peer.store.configurationRecovering = true
        try PortableAppPreferences(localProfile: changed, modelServices: [newCatalog]).persist(defaults: peer.defaults)
        peer.store.publicPreferencesDidChange(force: true)
        check(try records(peer).isEmpty, "configuration recovery blocks outgoing stage")
        try projection(peer, changed, [newCatalog])
        peer.store.configurationRecovering = false;peer.store.configurationRecoveryError = "Synthetic blocked recovery"
        try peer.store.synchronizePublicPreferences(force: true)
        check(try records(peer).isEmpty, "configuration recovery error also blocks outgoing stage")
        peer.store.configurationRecoveryError = nil
        try peer.store.synchronizePublicPreferences(force: true)
        check(Set(try records(peer).keys) == names, "guard release stages the preserved local changes")
        try privacy([peer])
    }

    private static func verifyEquivalentUnicodeDoesNotEcho() throws {
        let peer = try Peer("Unicode")
        defer { peer.clearSuite() }
        let composed = profile("Caf\u{e9}", 30)
        let decomposed = profile("Cafe\u{301}", 30)
        let catalog = service("Caf\u{e9}", "unicode")
        var remoteCatalog = catalog
        remoteCatalog.name = "Cafe\u{301}"
        check(composed == decomposed && catalog == remoteCatalog, "same Unicode display identity")
        check(try data(composed.name) != data(decomposed.name), "different encoded Unicode representation")
        try peer.install(composed, [catalog])
        peer.store.enablePublicPreferenceSync(defaults: peer.defaults)
        try acknowledge(peer)
        for (name, kind, payload) in [
            ("p-profile", "profile", String(decoding: try data(decomposed), as: UTF8.self)),
            ("p-model-services", "model_services", String(decoding: try data([remoteCatalog]), as: UTF8.self))
        ] {
            try deliver([ReplicaRecord(name: name, kind: kind, conversation: "",
                                      revision: "9000000000000000000", payload: payload)], to: peer)
            try peer.store.synchronizePublicPreferences(force: true)
            check(try records(peer).isEmpty, "equivalent Unicode remote value never becomes a new local revision")
        }
        // The real application notification uses the non-force entry point.
        // Saving an equivalent but differently encoded value must update the
        // mirror now, rather than becoming a delayed edit over later cloud data.
        try PortableAppPreferences(localProfile: composed, modelServices: [catalog]).persist(defaults: peer.defaults)
        peer.store.publicPreferencesDidChange()
        check(Set(try records(peer).keys) == names, "nonforce equivalent Unicode save stages both public changes")
        try acknowledge(peer)
        let later = profile("Remote value after local save", 31)
        try deliver([ReplicaRecord(name: "p-profile", kind: "profile", conversation: "",
                                   revision: "9000000000000000020", payload: String(decoding: try data(later), as: UTF8.self))], to: peer)
        try projection(peer, later, [catalog])
        check(try records(peer).isEmpty, "older equivalent local bytes cannot override a later remote value")
        try privacy([peer])
    }

    static func main() throws {
        try verifySeedAndIndependentRoundTrip()
        try verifyRejectedInputsAndDamagedCaches()
        try verifyConfigurationGuard()
        try verifyEquivalentUnicodeDoesNotEcho()
        print("SyncedPublicPreferencesTests passed \(checks) checks: real private SQLite peers, independent LWW/seed protection, no echo, clear/portable staging, ticket fences, strict rejection, configuration guard and private sentinel preservation.")
    }
}
