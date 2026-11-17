import Foundation

struct ShareInbox: Sendable {
    static let group = "group.com.pendingname.aauv"
    private static let snapshotFile = ".bot-snapshot.json"
    private static let recentBotFile = ".recent-bot.json"
    private static let snapshotLimit = 4 * 1024 * 1024

    struct Item: Sendable {
        let id: UUID
        let file: URL
        let folder: URL
        let botSnapshot: Data?
    }

    let root: URL

    #if os(iOS)
    static func shared() -> Self? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group).map {
            Self(root: $0.appending(path: "Library/Application Support/ShareInbox", directoryHint: .isDirectory))
        }
    }
    #endif

    private static var directoryAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        return attributes
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
        var inbox = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try inbox.setResourceValues(values)
    }

    func rememberBotSnapshot(_ snapshot: Data) throws {
        try prepareRoot()
        try Self.writeSnapshot(snapshot, to: root.appending(path: Self.recentBotFile))
    }

    func recentBotSnapshot() -> Data? {
        Self.readSnapshot(root.appending(path: Self.recentBotFile))
    }

    func begin(botSnapshot: Data? = nil) throws -> URL {
        try prepareRoot()
        if let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            for folder in folders where folder.lastPathComponent.hasPrefix(".")
                && UUID(uuidString: String(folder.lastPathComponent.dropFirst())) != nil && Self.isDirectory(folder) {
                if let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   created.timeIntervalSinceNow < -86_400 {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
        let stage = root.appending(path: "." + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: Self.directoryAttributes)
        if let botSnapshot {
            do { try Self.writeSnapshot(botSnapshot, to: stage.appending(path: Self.snapshotFile)) }
            catch {
                try? FileManager.default.removeItem(at: stage)
                throw error
            }
        }
        return stage
    }

    // Copy files while the system-provided URLs are still accessible. A failed
    // member of a multi-selection must not discard the files already copied.
    func capture(_ sources: [URL], botSnapshot: Data? = nil) throws -> [String] {
        guard !sources.isEmpty else { return [] }
        let stage = try begin(botSnapshot: botSnapshot)
        defer { try? FileManager.default.removeItem(at: stage) }
        var failures: [String] = []
        for (index, source) in sources.enumerated() {
            do { try copyCoordinated(source, index: index, into: stage) }
            catch { failures.append("\(source.lastPathComponent) · \(error.localizedDescription)") }
        }
        if failures.count < sources.count { try publish(stage) }
        return failures
    }

    func copyCoordinated(_ source: URL, index: Int, into stage: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { file in
            result = Result { try copy(file, name: source.lastPathComponent, index: index, into: stage) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        try result.get()
    }

    func copy(_ source: URL, name: String, index: Int, into stage: URL) throws {
        let folder = stage.appending(path: String(format: "%08d-", index) + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let name = Self.safeName(name)
            let destination = folder.appending(path: name)
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            #endif
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func publish(_ stage: URL) throws {
        let batch = root.appending(path: String(stage.lastPathComponent.dropFirst()), directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: stage, to: batch)
    }

    func pending() throws -> [Item] {
        let batches = try Self.contents(root, properties: [.creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        var ordered: [(url: URL, date: Date)] = []
        for batch in batches where UUID(uuidString: batch.lastPathComponent) != nil && Self.isDirectory(batch) {
            let date = (try? batch.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            ordered.append((batch, date))
        }
        ordered.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.url.lastPathComponent < rhs.url.lastPathComponent }
            return lhs.date < rhs.date
        }

        var items: [Item] = []
        for (batch, _) in ordered {
            let botSnapshot = Self.readSnapshot(batch.appending(path: Self.snapshotFile))
            let folders = try Self.contents(batch)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for folder in folders {
                let fields = folder.lastPathComponent.split(separator: "-", maxSplits: 1)
                guard fields.count == 2, Int(fields[0]) != nil,
                      let id = UUID(uuidString: String(fields[1])), Self.isDirectory(folder) else {
                    continue
                }
                let files = try Self.contents(folder, properties: [.isRegularFileKey, .isSymbolicLinkKey])
                guard files.count == 1, let file = files.first else { continue }
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                items.append(Item(id: id, file: file, folder: folder, botSnapshot: botSnapshot))
            }
        }
        return items
    }

    private static func contents(_ folder: URL, properties: [URLResourceKey]? = nil,
                                 options: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: properties, options: options)
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            // Another window can remove a delivered item during enumeration.
            return []
        }
    }

    func consume(_ item: Item) throws {
        do {
            try FileManager.default.removeItem(at: item.folder)
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            // A second window may already have removed this item.
        }
        let batch = item.folder.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: batch.path),
           contents.allSatisfy({ $0 == Self.snapshotFile }) {
            try? FileManager.default.removeItem(at: batch)
        }
    }

    private static func writeSnapshot(_ snapshot: Data, to url: URL) throws {
        guard snapshot.count <= snapshotLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        #if os(iOS)
        try snapshot.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try snapshot.write(to: url, options: .atomic)
        #endif
    }

    private static func readSnapshot(_ url: URL) -> Data? {
        guard let properties = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size <= snapshotLimit else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func safeName(_ name: String) -> String {
        let basename = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["", ".", ".."].contains(cleaned) { return "文件" }
        guard cleaned.utf8.count > 240 else { return cleaned }
        let suffix = (cleaned as NSString).pathExtension
        let ending = !suffix.isEmpty && suffix.utf8.count <= 32 ? "." + suffix : ""
        var trimmed = ""
        var remaining = 240 - ending.utf8.count
        let stem = ending.isEmpty ? cleaned : String(cleaned.dropLast(ending.count))
        for character in stem {
            let bytes = String(character).utf8.count
            guard bytes <= remaining else { break }
            trimmed.append(character)
            remaining -= bytes
        }
        return (trimmed.isEmpty ? "文件" : trimmed) + ending
    }
}
