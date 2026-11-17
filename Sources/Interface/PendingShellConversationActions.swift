import SwiftUI

/// Interaction around the unchanged conversation-card visual. The view owns
/// gesture/hover presentation only; every operation is delegated to its host.
struct PendingConversationInteractiveRow: View {
    let row: PendingConversationRowModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onNew: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var settled: CGFloat = 0
    @State private var dragDX: CGFloat = 0
    @State private var horizontalDrag = false

    private let buttonSize: CGFloat = 48
    private let buttonGap: CGFloat = 12
    private let edgePadding: CGFloat = 14
    private let leadingTriggerWidth: CGFloat = 96
    private let swipeMinimumDistance: CGFloat = 32
    private let horizontalDominanceRatio: CGFloat = 1.35

    private var actionsWidth: CGFloat { buttonSize * 2 + buttonGap + edgePadding * 2 }
    private var rawOffset: CGFloat { settled + dragDX }
    private var isOpen: Bool { settled <= -actionsWidth + 0.5 }

    private var offset: CGFloat {
        if rawOffset <= 0 { return max(-actionsWidth, rawOffset) }
        guard onNew != nil, settled == 0 else { return 0 }
        if rawOffset <= leadingTriggerWidth { return rawOffset }
        return leadingTriggerWidth + (sqrt(rawOffset - leadingTriggerWidth + 1) - 1) * 6
    }

    private var revealProgress: CGFloat { min(1, max(0, -offset / actionsWidth)) }
    private var leadingProgress: CGFloat { min(1, max(0, offset / leadingTriggerWidth)) }

    var body: some View {
        Group {
            #if os(iOS)
            swipeBody
            #else
            hoverBody
            #endif
        }
        .contextMenu {
            if let onNew { Button("新建会话", systemImage: "square.and.pencil", action: onNew) }
            Button("重命名…", systemImage: "pencil", action: onRename)
            Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(!row.canDelete)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: Text("重命名"), onRename)
        .accessibilityAction(named: Text("删除")) {
            if row.canDelete { onDelete() }
        }
    }

    private var hoverBody: some View {
        PendingConversationRow(row: row, isSelected: isSelected, hidesDate: hovering)
            .onTapGesture(perform: onSelect)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 8) {
                        hoverAction("重命名", systemImage: "pencil", color: Theme.ConversationCard.inkMuted, action: onRename)
                        hoverAction("删除", systemImage: "trash", color: Theme.ConversationCard.danger, action: onDelete)
                            .disabled(!row.canDelete)
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 14)
                }
            }
            .onHover { hovering = $0 }
    }

    private func hoverAction(_ title: String, systemImage: String, color: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.Fonts.glyph(size: 12))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var swipeBody: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: buttonGap) {
                swipeAction("重命名", systemImage: "pencil", tint: Theme.Palette.accent,
                            index: 0, action: onRename)
                swipeAction("删除", systemImage: "trash", tint: Theme.Palette.danger,
                            index: 1, action: onDelete)
                    .disabled(!row.canDelete)
            }
            .padding(.horizontal, edgePadding)
            .frame(width: actionsWidth)
            .allowsHitTesting(isOpen)

            if onNew != nil {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(Theme.Fonts.glyph(size: leadingProgress >= 0.999 ? 18 : 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.onAccent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.Palette.accent))
                        .scaleEffect(0.6 + leadingProgress * 0.5)
                    Text(leadingProgress >= 0.999 ? "松手新建" : "继续聊")
                        .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .opacity(min(1, leadingProgress * 2))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }

            PendingConversationRow(row: row, isSelected: isSelected)
                .offset(x: offset)
                .onTapGesture {
                    if isOpen { close() } else { onSelect() }
                }
        }
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: swipeMinimumDistance)
                .onChanged { value in
                    let dx = value.translation.width
                    if !horizontalDrag {
                        guard abs(dx) >= swipeMinimumDistance,
                              abs(dx) > abs(value.translation.height) * horizontalDominanceRatio
                        else { return }
                        horizontalDrag = true
                    }
                    dragDX = dx
                }
                .onEnded { value in
                    defer { horizontalDrag = false }
                    guard horizontalDrag else { dragDX = 0; return }
                    let dx = value.translation.width
                    let velocity = value.predictedEndTranslation.width - dx
                    if let onNew, settled == 0, rawOffset > 0,
                       (rawOffset >= leadingTriggerWidth || velocity > 600) {
                        close()
                        onNew()
                        return
                    }
                    let shouldOpen = isOpen
                        ? !(dx > buttonSize * 0.5 || velocity > 200)
                        : (-dx > buttonSize * 0.5 || velocity < -200)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                        dragDX = 0
                        settled = shouldOpen ? -actionsWidth : 0
                    }
                }
        )
    }

    private func swipeAction(_ title: String, systemImage: String, tint: Color, index: Int,
                             action: @escaping () -> Void) -> some View {
        let start = CGFloat(1 - index) / 2 * 0.55
        let appearance = min(1, max(0, (revealProgress - start) / 0.6))
        return Button {
            close()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(Theme.Fonts.glyph(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: buttonSize, height: buttonSize)
                .modifier(PendingSwipeGlassDisc())
                .shadow(color: .black.opacity(0.07 * appearance), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(appearance)
        .opacity(appearance)
        .accessibilityLabel(title)
    }

    private func close() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            settled = 0
            dragDX = 0
        }
    }
}

private struct PendingSwipeGlassDisc: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(Circle().fill(.thinMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}
