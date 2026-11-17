import SwiftUI

struct HistorySearchPage: Decodable, Sendable {
    let hits: [HistorySearchHit]
    let nextCursor: String?
}

struct HistorySearchHit: Decodable, Sendable, Identifiable {
    let conversationID: UUID
    let messageID: UUID?
    let title: String
    let botName: String?
    let role: String?
    let date: Date?
    let preview: String?
    let attachment: String?
    var id: String { messageID.map { "m-\($0)" } ?? "c-\(conversationID)" }
}

struct HistorySearchView: View {
    let store: ConversationStore
    let conversationID: UUID?
    let onSelect: (HistorySearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [HistorySearchHit] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var failed = false
    @State private var generation = UUID()
    private var keyword: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Group {
                if keyword.isEmpty {
                    ContentUnavailableView("搜索本地记录", systemImage: "magnifyingglass",
                                           description: Text("查找会话标题、机器人名、消息正文或附件文件名。"))
                } else if keyword.unicodeScalars.count > 256 {
                    ContentUnavailableView("关键词过长", systemImage: "text.magnifyingglass",
                                           description: Text("请将关键词缩短到 256 字符以内。"))
                } else if loading {
                    ProgressView()
                } else if failed && hits.isEmpty {
                    ContentUnavailableView("无法搜索本地记录", systemImage: "exclamationmark.magnifyingglass")
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: keyword)
                } else {
                    List {
                        ForEach(hits) { hit in
                            Button {
                                onSelect(hit)
                                dismiss()
                            } label: {
                                row(hit)
                            }
                            .buttonStyle(.plain)
                        }
                        if let cursor = nextCursor {
                            Button(loadingMore ? "正在加载…" : "加载更多") {
                                Task { await loadMore(cursor) }
                            }
                            .disabled(loadingMore)
                        }
                        if failed { Text("无法加载更多结果。").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(conversationID == nil ? "搜索全部会话" : "搜索当前会话")
            .searchable(text: $query, prompt: "输入关键词")
            .task(id: keyword) { await search() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    private func row(_ hit: HistorySearchHit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(hit.title.isEmpty ? "未命名会话" : hit.title).font(.headline).lineLimit(1)
                Spacer()
                if let date = hit.date { Text(date, format: .dateTime.year().month().day().hour().minute()) }
            }
            if hit.messageID != nil {
                Text(hit.role == "user" ? "你" : hit.botName ?? "机器人")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let name = hit.botName {
                Text(name).font(.footnote).foregroundStyle(.secondary)
            }
            if let preview = hit.preview {
                Text(preview).lineLimit(3).multilineTextAlignment(.leading)
            }
            if let attachment = hit.attachment {
                Label(attachment, systemImage: "paperclip").font(.footnote).lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func search() async {
        let text = keyword
        let current = UUID()
        generation = current
        hits = []
        nextCursor = nil
        failed = false
        loadingMore = false
        loading = !text.isEmpty && text.unicodeScalars.count <= 256
        guard loading else { return }
        defer { if generation == current { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(225))
            let page = try await store.searchHistory(text, in: conversationID)
            guard generation == current, keyword == text else { return }
            hits = page.hits
            nextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            if generation == current { failed = true }
        }
    }

    private func loadMore(_ cursor: String) async {
        let text = keyword
        let current = generation
        guard !loading, !loadingMore, nextCursor == cursor else { return }
        loadingMore = true
        failed = false
        defer { if generation == current { loadingMore = false } }
        do {
            let page = try await store.searchHistory(text, in: conversationID, cursor: cursor)
            guard generation == current, keyword == text else { return }
            hits.append(contentsOf: page.hits)
            nextCursor = page.nextCursor
        } catch {
            if generation == current { failed = true }
        }
    }
}
