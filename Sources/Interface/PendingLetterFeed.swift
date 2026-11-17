import SwiftUI

/// Presentation only. The workspace owns persistence, requests and navigation.
struct PendingLetterRowModel: Identifiable {
    enum State {
        case ready, writing, failed, interrupted, waiting

        var label: String {
            switch self {
            case .ready: ""
            case .writing: String(localized: "正在写来信…")
            case .failed: String(localized: "写信失败 · 可重试")
            case .interrupted: String(localized: "写信中断 · 可重试")
            case .waiting: String(localized: "等待生成")
            }
        }
    }

    let id: UUID
    let title: String
    let sender: String
    let senderID: UUID?
    let date: Date?
    let excerpt: String
    let state: State
    let canDelete: Bool
}

struct PendingLetterFeed: View {
    let rows: [PendingLetterRowModel]
    let selection: UUID?
    let canWrite: Bool
    let privacyCovered: Bool
    let onSelect: (UUID) -> Void
    let onWrite: () -> Void
    let onSearch: () -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PendingTabHeaderBar(title: String(localized: "来信")) {
                EmptyView()
            } trailing: {
                HStack(spacing: 12) {
                    Button(action: onSearch) { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索本地历史")
                    Button(action: onWrite) { Image(systemName: "square.and.pencil") }
                        .disabled(!canWrite)
                        .accessibilityLabel("请它写信")
                }
                .buttonStyle(.plain)
            }
            if rows.isEmpty {
                Spacer(minLength: 24)
                ContentUnavailableView {
                    Label("还没有来信", systemImage: "envelope.open")
                } description: {
                    Text("点击「请它写信」，机器人会结合你们最近的聊天直接生成内容。")
                } actions: {
                    Button("请它写信", action: onWrite).disabled(!canWrite)
                }
                Spacer(minLength: 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(rows) { row in
                            Button { onSelect(row.id) } label: {
                                PendingLetterFeedRow(row: row, selected: selection == row.id,
                                                     privacyCovered: privacyCovered)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除信件", role: .destructive) { onDelete(row.id) }
                                    .disabled(!row.canDelete)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

private struct PendingLetterFeedRow: View {
    let row: PendingLetterRowModel
    let selected: Bool
    let privacyCovered: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(row.state == .writing ? Theme.Palette.accent : .clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    PendingChatAvatar(emojiSeed: row.senderID?.uuidString ?? row.id.uuidString,
                                      colorSeed: row.id.uuidString, size: 18)
                    Text(row.sender)
                        .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = row.date {
                        Text(date, style: .relative)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted).lineLimit(1)
                    }
                }
                Rectangle().fill(Theme.Palette.hairline).frame(height: 0.5)
                Text(row.title)
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(3).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !row.excerpt.isEmpty {
                    Text(row.excerpt)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(3).lineSpacing(2)
                        .pendingChatPrivacyCover(privacyCovered)
                }
                if !row.state.label.isEmpty {
                    HStack(spacing: 6) {
                        Text(row.state.label).font(Theme.Fonts.caption)
                            .foregroundStyle(row.state == .failed ? Theme.Palette.danger : Theme.Palette.inkMuted)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .background(selected ? Theme.Palette.selectedConversation : Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(selected ? Theme.Palette.accent.opacity(0.3) : Theme.Palette.hairline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
    }
}

/// The host supplies its existing Markdown renderer and per-message actions.
/// Eager article layout gives search targets a real position, even for long letters.
struct PendingLetterArticle<Content: View, Actions: View>: View {
    let row: PendingLetterRowModel
    let showsBack: Bool
    let jump: PendingTimelineJump?
    let onBack: () -> Void
    let onJumpConsumed: (UUID) -> Void
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if showsBack {
                    Button(action: onBack) { Image(systemName: "chevron.left") }
                        .accessibilityLabel("返回来信")
                }
                Text("来信").font(Theme.Fonts.serif(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                actions()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 12).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(row.title)
                                .font(Theme.Fonts.serif(size: 28, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                            Rectangle().fill(Theme.Palette.hairline).frame(height: 0.5)
                            HStack(spacing: 10) {
                                PendingChatAvatar(emojiSeed: row.senderID?.uuidString ?? row.id.uuidString,
                                                  colorSeed: row.id.uuidString, size: 28)
                                Text(row.sender).font(Theme.Fonts.rounded(size: 13, weight: .medium))
                                if let date = row.date {
                                    Text(date, format: .dateTime.month().day().hour().minute())
                                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.inkMuted)
                                }
                                Spacer(minLength: 0)
                            }
                            if !row.state.label.isEmpty {
                                Text(row.state.label).font(Theme.Fonts.footnote)
                                    .foregroundStyle(row.state == .failed ? Theme.Palette.danger : Theme.Palette.inkMuted)
                            }
                        }
                        content()
                    }
                    .padding(.horizontal, Theme.Metrics.gutter + 4)
                    .padding(.top, 24).padding(.bottom, 48)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: jump?.id, initial: true) {
                    guard let jump else { return }
                    // Defer once until the eagerly built message IDs are laid out.
                    DispatchQueue.main.async {
                        if let messageID = jump.messageID { proxy.scrollTo(messageID, anchor: .top) }
                        onJumpConsumed(jump.id)
                    }
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}
