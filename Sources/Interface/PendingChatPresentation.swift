import SwiftUI

/// Presentation-only port of PendingBot's ConversationView/BubbleView.
/// Message storage, model access, attachment loading, menus, and actions stay
/// with the caller. Slots contain unpadded content, not another bubble shell.
struct PendingChatHeader<ExtraActions: View>: View {
    let title: String
    let botName: String
    let modelName: String?
    let conversationID: String
    let botID: String?
    let isPending: Bool
    let showsBack: Bool
    let onBack: (() -> Void)?
    let onNewConversation: (() -> Void)?
    let onSearch: (() -> Void)?
    let onSettings: () -> Void
    private let extraActions: ExtraActions

    init(
        title: String,
        botName: String,
        modelName: String? = nil,
        conversationID: String,
        botID: String? = nil,
        isPending: Bool = false,
        showsBack: Bool = false,
        onBack: (() -> Void)? = nil,
        onNewConversation: (() -> Void)? = nil,
        onSearch: (() -> Void)? = nil,
        onSettings: @escaping () -> Void,
        @ViewBuilder extraActions: () -> ExtraActions
    ) {
        self.title = title
        self.botName = botName
        self.modelName = modelName
        self.conversationID = conversationID
        self.botID = botID
        self.isPending = isPending
        self.showsBack = showsBack
        self.onBack = onBack
        self.onNewConversation = onNewConversation
        self.onSearch = onSearch
        self.onSettings = onSettings
        self.extraActions = extraActions()
    }

    private var subtitle: String {
        PendingChatHeaderLabel.subtitle(botName: botName, modelName: modelName)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsBack, let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(Theme.Fonts.glyph(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.trailing, 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
            }

            PendingChatAvatar(
                emojiSeed: botID?.isEmpty == false ? botID! : conversationID,
                colorSeed: conversationID,
                size: 30
            )

            VStack(alignment: .leading, spacing: 1) {
                // Deliberately plain text: no title capsule or system toolbar
                // title treatment. This is the original in-body header.
                Text(title)
                    .font(Theme.Fonts.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)

                if !subtitle.isEmpty || isPending {
                    HStack(spacing: 6) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Palette.inkMuted)
                                .lineLimit(1)
                        }
                        if isPending {
                            Text("·")
                                .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Palette.inkMuted)
                            TypingDots()
                                .transition(.opacity)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            extraActions

            if let onNewConversation {
                PendingChatHeaderAction(systemImage: "square.and.pencil",
                                        label: "新建对话", action: onNewConversation)
            }
            if let onSearch {
                PendingChatHeaderAction(systemImage: "magnifyingglass",
                                        label: "搜索当前对话", action: onSearch)
            }
            PendingChatHeaderAction(systemImage: "gearshape", label: "会话设置", action: onSettings)
        }
        .animation(.easeInOut(duration: 0.2), value: isPending)
        .padding(.horizontal, Theme.Metrics.conversationGutter)
        #if os(macOS)
        .padding(.top, 20)
        #else
        .padding(.top, 6)
        #endif
        .padding(.bottom, 8)
    }
}

extension PendingChatHeader where ExtraActions == EmptyView {
    init(
        title: String,
        botName: String,
        modelName: String? = nil,
        conversationID: String,
        botID: String? = nil,
        isPending: Bool = false,
        showsBack: Bool = false,
        onBack: (() -> Void)? = nil,
        onNewConversation: (() -> Void)? = nil,
        onSearch: (() -> Void)? = nil,
        onSettings: @escaping () -> Void
    ) {
        self.init(title: title, botName: botName, modelName: modelName,
                  conversationID: conversationID, botID: botID, isPending: isPending,
                  showsBack: showsBack, onBack: onBack,
                  onNewConversation: onNewConversation, onSearch: onSearch,
                  onSettings: onSettings, extraActions: { EmptyView() })
    }
}

/// Matches the original 32pt header action target; also usable by the caller
/// for its local voice, bot-switch, or privacy actions in the header slot.
struct PendingChatHeaderAction: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.Fonts.glyph(size: 17, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Only resolved display strings belong here. Internal identifiers are never
/// used as a fallback for a missing name or model label.
enum PendingChatHeaderLabel {
    static func subtitle(botName: String, modelName: String?) -> String {
        let name = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return model }
        if model.isEmpty { return name }
        return "\(name) · \(model)"
    }

    static func emptyStateTitle(title: String, botName: String, modelName: String?) -> String {
        let subtitle = subtitle(botName: botName, modelName: modelName)
        return subtitle.isEmpty ? title : subtitle
    }
}

enum PendingChatDeliveryState: Equatable {
    case sent
    case sending
    case failed
}

/// Original asymmetric bubble layout: incoming avatar + bordered text shell,
/// outgoing tinted text shell. Attachments keep their existing local views.
/// Context menus attach only to the actual avatar/bubble, never its spacer.
struct PendingChatBubble<Content: View, Attachments: View, Menu: View>: View {
    let id: String
    let isUser: Bool
    let botName: String
    let conversationID: String
    let botID: String?
    let hasContent: Bool
    let isStreaming: Bool
    let streamPaused: Bool
    let deliveryState: PendingChatDeliveryState
    let onRetry: (() -> Void)?
    private let content: Content
    private let attachments: Attachments
    private let menu: Menu

    init(
        id: String,
        isUser: Bool,
        botName: String,
        conversationID: String,
        botID: String? = nil,
        hasContent: Bool,
        isStreaming: Bool = false,
        streamPaused: Bool = false,
        deliveryState: PendingChatDeliveryState = .sent,
        onRetry: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder attachments: () -> Attachments,
        @ViewBuilder menu: () -> Menu
    ) {
        self.id = id
        self.isUser = isUser
        self.botName = botName
        self.conversationID = conversationID
        self.botID = botID
        self.hasContent = hasContent
        self.isStreaming = isStreaming
        self.streamPaused = streamPaused
        self.deliveryState = deliveryState
        self.onRetry = onRetry
        self.content = content()
        self.attachments = attachments()
        self.menu = menu()
    }

    private var userBubbleFill: Color {
        switch deliveryState {
        case .sent: return Theme.Palette.userBubble
        case .sending: return Theme.Palette.userBubbleSending
        case .failed: return Color.red.opacity(0.12)
        }
    }

    var body: some View {
        Group {
            if isUser { userLayout } else { botLayout }
        }
        .pendingChatTextSelection(id: id)
    }

    private var botLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                PendingChatAvatar(
                    emojiSeed: botID?.isEmpty == false ? botID! : conversationID,
                    colorSeed: conversationID,
                    size: 30
                )
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    attachments
                    if hasContent || isStreaming {
                        content
                            .pendingChatSelectableText()
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                                 style: .continuous)
                                    .fill(Theme.Palette.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                                 style: .continuous)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if isStreaming {
                                    PendingChatStreamingCursor(paused: streamPaused)
                                        .padding(.trailing, 12)
                                        .padding(.bottom, 12)
                                        .transition(.opacity)
                                }
                            }
                            .animation(.easeOut(duration: 0.28), value: isStreaming)
                    }
                }
            }
            .contextMenu { menu }

            Spacer(minLength: 32)
        }
        .padding(.horizontal, Theme.Metrics.conversationGutter)
        .padding(.vertical, 4)
    }

    private var userLayout: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 6) {
                attachments
                if hasContent {
                    HStack(alignment: .center, spacing: 6) {
                        if deliveryState == .failed {
                            Button { onRetry?() } label: {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(Theme.Fonts.glyph(size: 18))
                                    .foregroundStyle(Color.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .disabled(onRetry == nil)
                            .accessibilityLabel("重新发送")
                        }
                        content
                            .pendingChatSelectableText()
                            .font(Theme.Fonts.body)
                            .foregroundStyle(deliveryState == .failed
                                             ? Color.red.opacity(0.95)
                                             : Theme.Palette.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                                 style: .continuous)
                                    .fill(userBubbleFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius,
                                                 style: .continuous)
                                    .strokeBorder(deliveryState == .failed
                                                   ? Color.red.opacity(0.55) : .clear,
                                                  lineWidth: 1)
                            )
                            .animation(.easeInOut(duration: 0.22), value: deliveryState)
                    }
                }
            }
            .contextMenu { menu }
        }
        .padding(.horizontal, Theme.Metrics.conversationGutter)
        .padding(.vertical, 4)
    }
}

struct PendingChatEmptyConversation<Actions: View>: View {
    let title: String
    let botName: String
    let modelName: String?
    let conversationID: String
    let botID: String?
    let showsActions: Bool
    private let actions: Actions

    init(title: String, botName: String, modelName: String? = nil,
         conversationID: String, botID: String? = nil,
         showsActions: Bool = true,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.botName = botName
        self.modelName = modelName
        self.conversationID = conversationID
        self.botID = botID
        self.showsActions = showsActions
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            PendingChatAvatar(
                emojiSeed: botID?.isEmpty == false ? botID! : conversationID,
                colorSeed: conversationID,
                size: 64
            )
            Text(PendingChatHeaderLabel.emptyStateTitle(title: title, botName: botName,
                                                       modelName: modelName))
                .font(Theme.Fonts.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            if showsActions { actions.padding(.top, 28) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.bottom, 24)
    }
}

extension PendingChatEmptyConversation where Actions == EmptyView {
    init(title: String, botName: String, modelName: String? = nil,
         conversationID: String, botID: String? = nil) {
        self.init(title: title, botName: botName, modelName: modelName,
                  conversationID: conversationID, botID: botID, showsActions: false,
                  actions: { EmptyView() })
    }
}

/// Local actions such as settings and voice can reuse the original pre-chat
/// tile; active letters and other server-owned features are not reproduced.
struct PendingChatPreChatAction: View {
    let title: String
    let systemImage: String
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Image(systemName: systemImage)
                        .font(Theme.Fonts.glyph(size: 22, weight: .light))
                        .opacity(busy ? 0 : 1)
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(height: 28)
                Text(title)
                    .font(Theme.Fonts.rounded(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.ink)
            .frame(width: 92, height: 92)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1.5)
        }
        .buttonStyle(.plain)
    }
}

/// The separator remains outside bubble ids and menus, as in the source.
struct PendingChatTimeSeparator: View {
    let date: Date

    var body: some View {
        TimeSeparatorPill(date: date)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
    }
}

struct PendingChatUnreadJumpButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "arrow.down")
                    .font(Theme.Fonts.glyph(size: 11, weight: .bold))
            }
            .foregroundStyle(Theme.Palette.surface)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.Palette.accent))
            .overlay(Capsule().stroke(Theme.Palette.surface.opacity(0.5), lineWidth: 0.5))
            .shadow(color: Theme.Palette.ink.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .padding(.bottom, 14)
        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
        .accessibilityLabel("\(count) 条新消息，跳到最新")
    }
}

private struct PendingChatStreamingCursor: View {
    let paused: Bool
    private static let blinkPeriod: TimeInterval = 1.06

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.blinkPeriod)
            let visible = !paused || phase < Self.blinkPeriod / 2
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.Palette.ink)
                .frame(width: 8, height: 16)
                .opacity(visible ? 0.85 : 0)
                .animation(.easeOut(duration: 0.14), value: visible)
        }
        .frame(width: 8, height: 16)
        .accessibilityHidden(true)
    }
}

private struct PendingChatPrivacyCover: ViewModifier {
    let covered: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: covered ? 24 : 0)
            .clipped()
            .disabled(covered)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
            .overlay {
                if covered {
                    Theme.Palette.canvas.opacity(0.92)
                        .overlay {
                            Label("对话已遮盖", systemImage: "eye.slash.fill")
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                }
            }
    }
}

extension View {
    /// The caller owns the local setting and scene-phase policy; this modifier
    /// preserves the original visual and input/accessibility cover.
    func pendingChatPrivacyCover(_ covered: Bool) -> some View {
        modifier(PendingChatPrivacyCover(covered: covered))
    }
}
