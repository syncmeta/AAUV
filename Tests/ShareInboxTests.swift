import Foundation

@main
struct ShareInboxTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "aauv-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(root: root.appending(path: "inbox"))
        let empty = try inbox.pending()
        precondition(empty.isEmpty)

        let ordinary = root.appending(path: "original.unrecognized")
        let largeConfig = root.appending(path: "large.aauv")
        let backup = root.appending(path: "backup.aauvbackup")
        let genericJSON = root.appending(path: "config.json")
        let ordinaryJSON = root.appending(path: "data.json")
        let bytes = Data([255, 3, 0, 128, 40])
        let big = Data(repeating: 32, count: ConfigurationLink.maximumBytes + 1)
        try bytes.write(to: ordinary)
        try bytes.write(to: backup)
        try big.write(to: largeConfig)
        let marked = Data((#"{"ignored":""# + String(repeating: "x", count: ConfigurationLink.maximumBytes) +
                           #"","format":"aauv-config","version":4,"endpoint":"https://example.invalid","model":"fixture"}"#).utf8)
        try marked.write(to: genericJSON)
        try Data(#"{"name":"ordinary JSON","nested":{"format":"aauv-config"}}"#.utf8).write(to: ordinaryJSON)

        let stage = try inbox.begin()
        try inbox.copy(ordinary, name: "../nested/原文件.unrecognized", index: 0, into: stage)
        try inbox.copy(largeConfig, name: "large.aauv", index: 1, into: stage)
        try inbox.copy(backup, name: "backup.aauvbackup", index: 2, into: stage)
        try inbox.copy(genericJSON, name: "config.json", index: 3, into: stage)
        try inbox.copy(ordinaryJSON, name: "data.json", index: 4, into: stage)
        let symbolicLink = root.appending(path: "symlink")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: ordinary)
        precondition((try? inbox.copy(symbolicLink, name: "symlink", index: 5, into: stage)) == nil)
        let beforePublish = try inbox.pending()
        precondition(beforePublish.isEmpty, "The app must not observe a partial share batch")
        try inbox.publish(stage)
        try FileManager.default.removeItem(at: ordinary)

        let items = try inbox.pending()
        precondition(items.allSatisfy { $0.botSnapshot == nil })
        precondition(items.map { $0.file.lastPathComponent } ==
                     ["原文件.unrecognized", "large.aauv", "backup.aauvbackup", "config.json", "data.json"])
        guard case .attachment(let source) = try FileOpenRequest.read(items[0].file),
              case .configurationFile(let named) = try FileOpenRequest.read(items[1].file),
              case .backup(let backupURL) = try FileOpenRequest.read(items[2].file),
              case .configuration(let detected) = try FileOpenRequest.read(items[3].file),
              case .attachment = try FileOpenRequest.read(items[4].file) else {
            fatalError("Incorrect document routing")
        }
        let namedBytes = try PortableSettings.readFile(named)
        precondition(named == items[1].file && namedBytes == big && backupURL == items[2].file && detected == marked)
        let configuration = try PortableSettings.decode(detected)
        precondition(configuration.model == "fixture")

        let file = root.appending(path: "db/chats.json")
        let store = ConversationStore(file: file)
        let bot = BotSnapshot(name: "最近使用", endpoint: "https://example.invalid/v1", model: "fixture", loginMethod: .byok)
        let staged = try await store.stageFileOpen(source, shareID: items[0].id)
        let abandoned = try store.attachmentURL(staged.attachment)
        try Data("abandoned copy".utf8).write(to: abandoned)
        let id = try store.openFile(staged, bot: bot, shareID: items[0].id)
        let resumed = ConversationStore(file: file)
        let duplicate = try resumed.openFile(staged, bot: bot, shareID: items[0].id)
        precondition(id == items[0].id && duplicate == id && resumed.conversations.count == 1)
        let chat = resumed.conversations[0]
        precondition(chat.bot == bot && chat.title == "原文件.unrecognized" && chat.messages.isEmpty)
        let copied = try Data(contentsOf: resumed.attachmentURL(chat.attachments![0]))
        precondition(copied == bytes)

        try resumed.delete(id)
        let receiptSurvived = try resumed.sharedImportCommitted(id)
        _ = try resumed.openFile(staged, bot: bot, shareID: id)
        precondition(receiptSurvived && resumed.conversations.isEmpty)

        let unavailable = ConversationStore(file: root.appending(path: "unavailable/chats.json"))
        let rollback = try await unavailable.stageFileOpen(items[4].file)
        let destination = try unavailable.attachmentURL(rollback.attachment)
        try unavailable.requireDatabase().close()
        precondition((try? unavailable.openFile(rollback, bot: bot)) == nil)
        precondition(!FileManager.default.fileExists(atPath: destination.path) && unavailable.conversations.isEmpty)
        precondition(FileManager.default.fileExists(atPath: items[4].file.path))
        for item in items { try inbox.consume(item) }
        try inbox.consume(items[0])
        let drained = try inbox.pending()
        precondition(drained.isEmpty)

        let openedRoot = root.appending(path: "OpenInbox")
        let opened = ShareInbox(root: openedRoot)
        let originalBot = try JSONEncoder().encode(bot)
        try opened.rememberBotSnapshot(originalBot)
        let capturedBot = opened.recentBotSnapshot()
        precondition(capturedBot == originalBot)
        var laterBot = bot
        laterBot.name = "随后使用的机器人"
        laterBot.model = "new-model"
        let secondSource = root.appending(path: "second.bin")
        let secondBytes = Data([1, 3, 5, 7])
        try secondBytes.write(to: secondSource)
        let missing = root.appending(path: "missing.bin")
        let failures = try await Task.detached {
            try opened.capture([ordinaryJSON, missing, secondSource], botSnapshot: capturedBot)
        }.value
        precondition(failures.count == 1 && failures[0].contains("missing.bin"))
        try FileManager.default.removeItem(at: ordinaryJSON)
        try FileManager.default.removeItem(at: secondSource)
        let currentBot = try JSONEncoder().encode(laterBot)
        try opened.rememberBotSnapshot(currentBot)
        let restartedInbox = ShareInbox(root: openedRoot)
        let queued = try restartedInbox.pending()
        precondition(restartedInbox.recentBotSnapshot() == currentBot)
        precondition(queued.map { $0.file.lastPathComponent } == ["data.json", "second.bin"])
        precondition(queued.allSatisfy { $0.botSnapshot == originalBot })
        for item in queued {
            guard case .attachment(let file) = try FileOpenRequest.read(item.file) else {
                fatalError("A captured ordinary file was routed to a configuration preview")
            }
            let staged = try await resumed.stageFileOpen(file, shareID: item.id)
            let id = try resumed.openFile(staged, bot: laterBot, shareID: item.id, capturedBot: item.botSnapshot)
            precondition(id == item.id)
            try restartedInbox.consume(item)
        }
        precondition(resumed.conversations.count == 2 && resumed.conversations.allSatisfy { $0.bot == bot && $0.messages.isEmpty })
        let secondChat = resumed.conversations.first { $0.title == "second.bin" }!
        let secondRestored = try Data(contentsOf: resumed.attachmentURL(secondChat.attachments!.first!))
        precondition(secondRestored == secondBytes)
        let emptyAfterCapture = try restartedInbox.pending()
        precondition(emptyAfterCapture.isEmpty)
        let remainingBatches = try FileManager.default.contentsOfDirectory(at: openedRoot, includingPropertiesForKeys: nil,
                                                                          options: .skipsHiddenFiles)
        precondition(remainingBatches.isEmpty)
        print("File inbox survived partial copy, reopen and robot changes, and committed each attachment once.")
    }
}
