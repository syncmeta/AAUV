import SwiftUI

/// The retained local surfaces from PendingBot's top-level navigation.
/// Selection and all application state remain owned by the host.
enum PendingAppSection: String, CaseIterable, Identifiable {
    case messages, letters, bots, me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: return String(localized: "消息")
        case .letters: return String(localized: "来信")
        case .bots: return String(localized: "机器人")
        case .me: return String(localized: "我")
        }
    }

    var systemImage: String {
        switch self {
        case .messages: return "bubble.left"
        case .letters: return "envelope"
        case .bots: return "person.2"
        case .me: return "person.crop.circle"
        }
    }
}

private struct PendingShellSidebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the combined 56pt rail + list column.
    var pendingShellUsesSidebar: Bool {
        get { self[PendingShellSidebarKey.self] }
        set { self[PendingShellSidebarKey.self] = newValue }
    }
}

/// PendingBot's native compact tabs and combined wide sidebar. Builders
/// supply local feature views; this shell never reads an account or store.
struct PendingAppShell<Messages: View, Letters: View, Bots: View, Me: View, Detail: View>: View {
    @Binding var section: PendingAppSection
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    var avatarSeed = "?"
    private let messages: () -> Messages
    private let letters: () -> Letters
    private let bots: () -> Bots
    private let me: () -> Me
    private let detail: (PendingAppSection) -> Detail
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(
        section: Binding<PendingAppSection>,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        avatarSeed: String = "?",
        @ViewBuilder messages: @escaping () -> Messages,
        @ViewBuilder letters: @escaping () -> Letters,
        @ViewBuilder bots: @escaping () -> Bots,
        @ViewBuilder me: @escaping () -> Me,
        @ViewBuilder detail: @escaping (PendingAppSection) -> Detail
    ) {
        _section = section
        _preferredCompactColumn = preferredCompactColumn
        self.avatarSeed = avatarSeed
        self.messages = messages
        self.letters = letters
        self.bots = bots
        self.me = me
        self.detail = detail
    }

    var body: some View {
        Group {
            #if os(iOS)
            if horizontalSizeClass == .compact, !Platform.isMac {
                compactBody
            } else {
                wideBody
            }
            #else
            wideBody
            #endif
        }
        .tint(Theme.Palette.accent)
    }

    private var wideBody: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            HStack(spacing: 0) {
                tabRail.frame(width: 56)
                listColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .environment(\.pendingShellUsesSidebar, true)
            .navigationTitle("")
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 560)
        } detail: {
            detail(section)
        }
    }

    #if os(iOS)
    private var compactBody: some View {
        TabView(selection: $section) {
            NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
                messages()
                    .navigationTitle("")
                    .toolbar(.hidden, for: .navigationBar)
            } detail: {
                detail(.messages)
                    .toolbar(preferredCompactColumn == .detail ? .hidden : .visible, for: .tabBar)
            }
            .tabItem { Label(PendingAppSection.messages.title, systemImage: PendingAppSection.messages.systemImage) }
            .tag(PendingAppSection.messages)

            NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
                letters()
                    .navigationTitle("")
                    .toolbar(.hidden, for: .navigationBar)
            } detail: {
                detail(.letters)
                    .toolbar(preferredCompactColumn == .detail ? .hidden : .visible, for: .tabBar)
            }
            .tabItem { Label(PendingAppSection.letters.title, systemImage: PendingAppSection.letters.systemImage) }
            .tag(PendingAppSection.letters)

            NavigationStack { bots() }
                .tabItem { Label(PendingAppSection.bots.title, systemImage: PendingAppSection.bots.systemImage) }
                .tag(PendingAppSection.bots)

            NavigationStack { me() }
                .tabItem { Label(PendingAppSection.me.title, systemImage: PendingAppSection.me.systemImage) }
                .tag(PendingAppSection.me)
        }
        .environment(\.pendingShellUsesSidebar, false)
    }
    #endif

    @ViewBuilder private var listColumn: some View {
        switch section {
        case .messages: messages()
        case .letters: letters()
        case .bots: bots()
        case .me: me()
        }
    }

    private var tabRail: some View {
        VStack(spacing: 2) {
            ForEach(PendingAppSection.allCases.filter { $0 != .me }) { tab in
                Button {
                    if section != tab { section = tab }
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(Theme.Fonts.glyph(size: 16, weight: .regular))
                        .symbolVariant(section == tab ? .fill : .none)
                        .foregroundStyle(section == tab ? Theme.Palette.accent : Theme.Palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(section == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Button {
                if section != .me { section = .me }
            } label: {
                PendingChatAvatar(seed: avatarSeed, size: 26)
                    .overlay {
                        Circle()
                            .strokeBorder(section == .me ? Theme.Palette.accent : .clear, lineWidth: 2)
                            .padding(-2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("我")
            .accessibilityLabel("我")
            .accessibilityAddTraits(section == .me ? .isSelected : [])
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }
}

/// Frozen TabHeaderBar geometry, shared by the local top-level surfaces.
struct PendingTabHeaderBar<Leading: View, Trailing: View>: View {
    let title: String
    private let leading: () -> Leading
    private let trailing: () -> Trailing

    init(
        title: String,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            leading().foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            trailing().foregroundStyle(Theme.Palette.ink)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

extension PendingTabHeaderBar where Leading == EmptyView {
    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, leading: { EmptyView() }, trailing: trailing)
    }
}

struct PendingHeaderActionIcon: View {
    let systemImage: String
    var size: CGFloat = 36
    var glyphPointSize: CGFloat = 17
    var glyphWeight: Font.Weight = .regular

    var body: some View {
        Image(systemName: systemImage)
            .font(Theme.Fonts.glyph(size: glyphPointSize, weight: glyphWeight))
            .foregroundStyle(Theme.Palette.accent)
            .frame(width: size, height: size)
            .contentShape(Capsule())
    }
}

/// PendingBot's quiet list-empty state, without a generic unavailable glyph.
struct PendingEmptyHint: View {
    let text: String

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .lineSpacing(4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// PendingBot's wide detail placeholder: a light, muted symbol on canvas.
struct PendingEmptyDetail: View {
    var text: String? = nil
    var systemImage = "bubble.left.and.bubble.right"

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(Theme.Fonts.glyph(size: 36, weight: .light))
                .foregroundStyle(Theme.Palette.inkMuted.opacity(0.55))
            if let text, !text.isEmpty {
                Text(text)
                    .font(Theme.Fonts.serif(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

/// A display projection supplied by the host, never a second conversation store.
struct PendingConversationRowModel: Identifiable {
    let id: UUID
    var title: String
    var botID: UUID? = nil
    var botName: String = ""
    var model: String = ""
    var preview: String = ""
    var date: Date? = nil
    var busy = false
    var canDelete = true
}

/// Optional compose menu entries. The host supplies the already-authorized
/// action, including its choice of local bot/configuration.
struct PendingNewConversationItem: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

struct PendingConversationList: View {
    let rows: [PendingConversationRowModel]
    @Binding var selection: UUID?
    var isBusy = false
    var canCreate = true
    var canSearch = true
    var canOpenFiles = true
    var newConversationItems: [PendingNewConversationItem] = []
    var onNewForConversation: ((UUID) -> Void)? = nil
    var onSelect: (UUID) -> Void = { _ in }
    var onNew: () -> Void
    var onSearch: () -> Void
    var onFiles: () -> Void
    var onRename: (UUID) -> Void
    var onDelete: (UUID) -> Void
    @Environment(\.pendingShellUsesSidebar) private var sidebar

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The original wide Mac surface places controls in the native
            // sidebar toolbar, leaving its translucent list area uninterrupted.
            #else
            if !sidebar {
                PendingTabHeaderBar(title: "消息") { headerActions }
            }
            #endif
            Group {
                if isBusy && rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    PendingEmptyHint(text: "和 AI 聊天")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(rows) { row in
                                PendingConversationInteractiveRow(
                                    row: row,
                                    isSelected: sidebar && selection == row.id,
                                    onSelect: {
                                        selection = row.id
                                        onSelect(row.id)
                                    },
                                    onNew: newAction(for: row),
                                    onRename: { onRename(row.id) },
                                    onDelete: { onDelete(row.id) }
                                )
                            }
                        }
                        .padding(.leading, sidebar ? 0 : Theme.Metrics.gutter)
                        .padding(.trailing, Theme.Metrics.gutter)
                        .padding(.vertical, 12)
                        .readableColumnWidth(sidebar ? .infinity : Theme.Metrics.readableColumn)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(sidebar ? Color.clear : Theme.Palette.canvas)
        .modifier(PendingConversationToolbar(
            enabled: sidebar, canCreate: canCreate, canSearch: canSearch, canOpenFiles: canOpenFiles,
            items: newConversationItems, onNew: onNew, onSearch: onSearch, onFiles: onFiles
        ))
    }

    private func newAction(for row: PendingConversationRowModel) -> (() -> Void)? {
        guard canCreate else { return nil }
        return {
            if let onNewForConversation { onNewForConversation(row.id) }
            else { onNew() }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.Fonts.glyph(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: 32, height: 32)
            }
            .disabled(!canSearch)
            .accessibilityLabel("搜索全部消息")
            HStack(spacing: 6) {
                PendingComposeControl(items: newConversationItems, onNew: onNew)
                    .disabled(!canCreate)
                Button(action: onFiles) {
                    PendingHeaderActionIcon(systemImage: "doc.badge.plus")
                }
                .disabled(!canOpenFiles)
                .accessibilityLabel("从文件打开")
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PendingComposeControl: View {
    let items: [PendingNewConversationItem]
    let onNew: () -> Void

    var body: some View {
        Group {
            if items.isEmpty {
                Button(action: onNew) { PendingHeaderActionIcon(systemImage: "square.and.pencil") }
            } else {
                Menu {
                    Button("新对话", action: onNew)
                    ForEach(items) { item in
                        Button(action: item.action) { Label(item.title, systemImage: "bubble.left") }
                    }
                } label: {
                    PendingHeaderActionIcon(systemImage: "square.and.pencil")
                }
            }
        }
        .accessibilityLabel("新建会话")
    }
}

private struct PendingConversationToolbar: ViewModifier {
    let enabled: Bool
    let canCreate: Bool
    let canSearch: Bool
    let canOpenFiles: Bool
    let items: [PendingNewConversationItem]
    let onNew: () -> Void
    let onSearch: () -> Void
    let onFiles: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            if enabled {
                ToolbarItemGroup {
                    Button(action: onSearch) { Image(systemName: "magnifyingglass") }
                        .help("搜索全部消息")
                        .accessibilityLabel("搜索全部消息")
                        .keyboardShortcut("f", modifiers: .command)
                        .disabled(!canSearch)
                    if items.isEmpty {
                        Button(action: onNew) { Image(systemName: "square.and.pencil") }
                            .help("新建会话")
                            .accessibilityLabel("新建会话")
                            .disabled(!canCreate)
                    } else {
                        Menu {
                            Button("新对话", action: onNew)
                            ForEach(items) { item in
                                Button(action: item.action) { Label(item.title, systemImage: "bubble.left") }
                            }
                        } label: { Image(systemName: "square.and.pencil") }
                        .help("新建会话")
                        .accessibilityLabel("新建会话")
                        .disabled(!canCreate)
                    }
                    Button(action: onFiles) { Image(systemName: "doc.badge.plus") }
                        .help("从文件打开")
                        .accessibilityLabel("从文件打开")
                        .disabled(!canOpenFiles)
                }
            }
        }
    }
}

/// Original avatar/title/time/preview geometry, with the bot name shown as
/// plain text as requested for AAUV's message list.
struct PendingConversationRow: View {
    let row: PendingConversationRowModel
    var isSelected = false
    var hidesDate = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PendingChatAvatar(emojiSeed: row.botID?.uuidString ?? row.id.uuidString,
                              colorSeed: row.id.uuidString, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title.isEmpty ? "新对话" : row.title)
                        .font(Theme.Fonts.scriptTitle(row.title.isEmpty ? "新对话" : row.title, size: 16))
                        .foregroundStyle(row.title.isEmpty ? Theme.ConversationCard.inkMuted : Theme.ConversationCard.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if row.busy {
                        ProgressView().controlSize(.mini).accessibilityLabel("生成中")
                    }
                    if hidesDate {
                        Color.clear.frame(width: 48, height: 14)
                    } else if let date = row.date {
                        Text(date, format: .relative(presentation: .numeric))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.ConversationCard.inkMuted)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.preview.isEmpty ? "还没有消息" : row.preview)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.ConversationCard.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(row.botName.isEmpty ? "机器人" : row.botName)
                        .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ConversationCard.accent)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(isSelected ? Theme.ConversationCard.selected : Theme.ConversationCard.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.ConversationCard.hairline, lineWidth: 0.5)
        }
        .tint(Theme.ConversationCard.accent)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.model)
    }
}

/// The retained bot-only FriendRow. Model names are host supplied; no catalog,
/// public/private badge, prices, contacts, or network lookup are involved.
struct PendingBotRow: View {
    let id: UUID
    let name: String
    var model = ""

    var body: some View {
        HStack(spacing: 10) {
            PendingChatAvatar(seed: id.uuidString, size: 36)
            HStack(spacing: 6) {
                Text(name)
                    .font(Theme.Fonts.scriptTitle(name, size: 16))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !model.isEmpty {
                    Text(model)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(Theme.Fonts.rounded(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.Palette.surfaceMuted))
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
