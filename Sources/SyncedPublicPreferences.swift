import Foundation

// These are public display/connection metadata. Provider keys, OAuth credentials,
// proxy nodes and the active account are intentionally absent from this schema.
struct SyncedPublicPreferences: Codable, Equatable {
    var profile: LocalDisplayProfile?
    var modelServices: [ModelService]?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func validated() throws -> Self {
        var copy = self
        copy.profile = try profile?.validated()
        copy.modelServices = try modelServices.map(ModelService.validateBatch)
        guard try copy.modelServices.map({ try JSONEncoder().encode($0).count <= 4 * 1024 * 1024 }) ?? true else {
            throw CocoaError(.fileReadTooLarge)
        }
        return copy
    }

    @MainActor static func capture(defaults: UserDefaults) throws -> Self {
        let profile: LocalDisplayProfile?
        if let object = defaults.object(forKey: LocalDisplayProfile.storageKey) {
            guard let data = object as? Data, let value = LocalDisplayProfile.decode(data) else {
                throw ChatClient.ClientError.message(String(localized: "无法读取地名和头像，原记录未被覆盖。"))
            }
            profile = value
        } else { profile = nil }
        let services = defaults.object(forKey: ModelServices.storageKey) == nil
            ? nil : try ModelServices.load(defaults: defaults)
        return try Self(profile: profile, modelServices: services).validated()
    }

    static func validate(_ record: ReplicaRecord) throws {
        guard record.conversation.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let data = Data(record.payload.utf8)
        switch record.kind {
        case "profile":
            guard record.name == "p-profile" else { throw CocoaError(.fileReadCorruptFile) }
            _ = try JSONDecoder().decode(LocalDisplayProfile.self, from: data).validated()
        case "model_services":
            guard record.name == "p-model-services" else { throw CocoaError(.fileReadCorruptFile) }
            _ = try ModelService.validateBatch(JSONDecoder().decode([ModelService].self, from: data))
        default: throw CocoaError(.fileReadCorruptFile)
        }
        // Core additionally rejects unknown fields at every nesting level.
    }
}

extension ConversationStore {
    // Explicit installation keeps standalone Store/CloudSync fixtures independent
    // of the user's standard preferences. The app installs its own suite once.
    func enablePublicPreferenceSync(defaults: UserDefaults) {
        publicPreferenceDefaults = defaults
        publicPreferencesDidChange(force: true)
    }

    func publicPreferencesDidChange(force: Bool = false) {
        do { try synchronizePublicPreferences(force: force) }
        catch {
            publicPreferencesError = String(localized: "个人资料或模型目录暂未同步，本机记录已保留。")
        }
    }

    func synchronizePublicPreferences(force: Bool = false) throws {
        guard let defaults = publicPreferenceDefaults, !publishingPublicPreferences,
              !configurationUnavailable, loadError == nil else { return }
        publishingPublicPreferences = true
        defer { publishingPublicPreferences = false }
        do {
            let local = try SyncedPublicPreferences.capture(defaults: defaults)
            let localBytes = try local.encoded()
            let previousBytes = try publicPreferencesLastObserved?.encoded()
            guard force || localBytes != previousBytes || publicPreferencesError != nil else { return }
            // The Core mirror must never get ahead of the durable cache: otherwise
            // a crash could make older defaults look like a fresh local edit.
            guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            let database = try requireDatabase()
            let names = ["p-profile", "p-model-services"]
            let before = try names.map(pendingReplicaRevision)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var error: NSError?
            let text = database.reconcilePublicPreferences(String(decoding: localBytes, as: UTF8.self), error: &error)
            if let error { throw error }
            // A committed local edit must still reach the outbox if cache publication fails.
            if try names.map(pendingReplicaRevision) != before { onLocalChange?() }
            let desired = try JSONDecoder().decode(SyncedPublicPreferences.self, from: Data(text.utf8)).validated()
            var published = desired
            guard try SyncedPublicPreferences.capture(defaults: defaults).encoded() == localBytes else {
                throw ChatClient.ClientError.message(String(localized: "个人资料或模型目录已变化，请稍后重试。"))
            }
            try publishPublicPreferences(desired, defaults: defaults)
            do {
                try database.markPublicPreferencesPublished(String(decoding: try encoder.encode(desired), as: UTF8.self))
            } catch {
                // A concurrent Core writer may have advanced the projection. Read that
                // projection directly; never mistake our older publication for a new edit.
                var readError: NSError?
                let latest = database.preparePublicPreferencesPublication(&readError)
                if let readError { throw readError }
                let value = try JSONDecoder().decode(SyncedPublicPreferences.self, from: Data(latest.utf8)).validated()
                try publishPublicPreferences(value, defaults: defaults)
                try database.markPublicPreferencesPublished(String(decoding: try encoder.encode(value), as: UTF8.self))
                published = value
            }
            publicPreferencesLastObserved = published
            publicPreferencesError = nil
        } catch {
            // Remote apply calls this throwing entry point directly. Preserve a
            // retry signal even when the Core commit succeeded but publication did not.
            publicPreferencesError = String(localized: "个人资料或模型目录暂未同步，本机记录已保留。")
            throw error
        }
    }

    private func publishPublicPreferences(_ value: SyncedPublicPreferences, defaults: UserDefaults) throws {
        let value = try value.validated()
        let current = try SyncedPublicPreferences.capture(defaults: defaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Swift String equality folds canonically equivalent Unicode. The Core
        // mirror hashes encoded values, so publication must retain their actual
        // representation too (for example a decomposed accent from another device).
        if let profile = value.profile, try encoder.encode(profile) != encoder.encode(current.profile) {
            defaults.set(try JSONEncoder().encode(profile), forKey: LocalDisplayProfile.storageKey)
        }
        if let services = value.modelServices, try encoder.encode(services) != encoder.encode(current.modelServices) {
            try ModelServices.replace(services, defaults: defaults)
        }
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }
}
