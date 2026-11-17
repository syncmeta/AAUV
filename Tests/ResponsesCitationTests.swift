import Foundation

@main
struct ResponsesCitationTests {
    @MainActor static func main() async throws {
        let first = "开头🙂。\n\n"
        let second = "证据在这里。"
        let text = first + second
        let response: [[String: Any]] = [
            ["type": "web_search_call", "id": "ws_fixture"],
            ["type": "message", "content": [
                ["type": "output_text", "text": first, "annotations": [
                    ["type": "url_citation", "url": "https://example.invalid/first", "title": "第一份", "start_index": 0, "end_index": 4]
                ]],
                ["type": "output_text", "text": second, "annotations": [
                    ["type": "url_citation", "url": "https://example.invalid/second", "title": "第二份", "start_index": 0, "end_index": 6],
                    ["type": "url_citation", "url": "https://example.invalid/fallback", "start_index": 9, "end_index": 99],
                    ["type": "url_citation", "url": "aauv://import", "start_index": 0, "end_index": 1],
                    ["type": "url_citation", "url": "https://user:password@example.invalid/secret", "start_index": 0, "end_index": 1],
                    ["type": "container_file_citation", "file_id": "file_fixture"],
                    NSNull()
                ] as [Any]]
            ]]
        ]
        let decoded = try JSONDecoder().decode([ResponseWebCitations.Item].self,
                                               from: JSONSerialization.data(withJSONObject: response))
        let expected = ResponseWebCitations.collect(from: decoded, matching: text)
        precondition(expected.count == 3)
        precondition(expected.map(\.end) == [4, first.unicodeScalars.count + 6, nil])
        let mismatched = ResponseWebCitations.collect(from: decoded, matching: "different terminal text")
        precondition(mismatched.map(\.end) == [nil, nil, nil])

        let saved: ChatMessage
        if CommandLine.arguments.count == 2 {
            let endpoint = URL(string: CommandLine.arguments[1])!
            let config = ChatClient.Configuration(baseURL: endpoint, model: "fixture", key: "fixture-key")
            var citations: [WebCitation] = []
            let reply = try await ChatClient.reply(to: [.init(role: .user, content: "找来源")], configuration: config,
                                                  proxy: nil, onReplyReady: { citations = $0.citations })
            precondition(reply == text && citations == expected)
            saved = ChatMessage(role: .assistant, content: reply, citations: citations)
        } else {
            saved = ChatMessage(role: .assistant, content: text, citations: expected)
        }

        let scratch = try PrivateTemporaryDirectory()
        let file = scratch.url.appending(path: "original/chats.json")
        let store = ConversationStore(file: file)
        let id = try store.create()
        let user = ChatMessage(role: .user, content: "找来源", date: Date(timeIntervalSince1970: 1))
        try store.append(user, to: id)
        let attempt = ReplyAttempt(userMessageID: user.id, phase: .submitted)
        try store.saveAttempt(attempt, to: id)
        try store.complete(saved, attempt: attempt, in: id)

        let reopened = ConversationStore(file: file)
        precondition(reopened.conversations.first?.messages.last?.citations == expected)
        let records = try store.pendingReplica()
        let peer = ConversationStore(file: scratch.url.appending(path: "peer/chats.json"))
        for record in records.reversed() {
            try peer.applyReplicaPayload(.inline(ReplicaPacket(record: record, files: [:])))
        }
        try peer.reloadReplica()
        precondition(peer.conversations.first?.messages.last?.citations == expected)
        precondition(peer.conversations.first?.messages.first?.citations == nil)

        let backup = try BackupFile.create(snapshot: store.backupSnapshot(), attachments: store.attachmentDirectory)
        let restored = ConversationStore(file: scratch.url.appending(path: "restored/chats.json"))
        try await restored.importBackup(PreparedBackup.read(backup.url))
        precondition(restored.conversations.first?.messages.last?.content == text)
        precondition(restored.conversations.first?.messages.last?.citations == expected)
        print("Response citations survived terminal decoding, SQLite reload, replica delivery and ZIP backup.")
    }
}
