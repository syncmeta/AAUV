import Foundation

@main
struct PendingBotMigrationTests {
    @MainActor static func main() async throws {
        let directory = try PrivateTemporaryDirectory()
        let backupURL = directory.url.appending(path: "synthetic.aauvbackup")
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "pendingbot-migration-tests.py")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [fixture.path, "--fixture", backupURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)

        let file = directory.url.appending(path: "import/conversations.json")
        let backup = try PreparedBackup.read(backupURL)
        try backup.validate()
        let store = ConversationStore(file: file)
        try await store.importBackup(backup)
        let reopened = ConversationStore(file: file)
        let chat = reopened.conversations[0]
        precondition(chat.title == "旧标题" && chat.bot?.name == "旧机器人")
        precondition(chat.messages.count == 6 && chat.turns.count == 2)
        precondition(chat.contextMessages().map(\.content) == ["问题", "原回答第一段", "原回答第二段", "下个问题", "下一轮回答"])
        let turn = chat.turns[0]
        let alternative = turn.alternatives[0]
        precondition(alternative.content == "候选第一段\n\n候选第二段")
        precondition(alternative.replyTo == turn.id && turn.original.count == 2)
        precondition(turn.original.allSatisfy { $0.date?.timeIntervalSince1970 == 1750000000 })
        try reopened.selectReply(alternative.id, for: turn.id, in: chat.id)
        let selected = ConversationStore(file: file)
        precondition(selected.conversations[0].contextMessages().map(\.content) ==
                     ["问题", "候选第一段\n\n候选第二段", "下个问题", "下一轮回答"])

        let exported = try BackupFile.create(snapshot: PortableArchive(version: 2, conversations: selected.conversations,
                                                                       bots: selected.bots),
                                             attachments: selected.attachmentDirectory)
        let roundTrip = ConversationStore(file: directory.url.appending(path: "round-trip/conversations.json"))
        try await roundTrip.importBackup(PreparedBackup.read(exported.url))
        let copied = roundTrip.conversations[0]
        precondition(copied.contextMessages().map(\.content) == selected.conversations[0].contextMessages().map(\.content))
        let copiedTurn = copied.turns[0]
        try roundTrip.selectReply(copiedTurn.original[0].id, for: copiedTurn.id, in: copied.id)
        let final = ConversationStore(file: roundTrip.file)
        precondition(final.conversations[0].contextMessages().map(\.content) == chat.contextMessages().map(\.content))
        print("Migrated split answers survived import, SQLite reopen, reply selection and backup round trip without mixing candidates.")
    }
}
