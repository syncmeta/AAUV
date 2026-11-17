import SwiftUI

struct PendingTimelineJump: Equatable {
    let id: UUID
    let messageID: UUID?
}

private struct PendingTimelineBottom: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

/// PendingBot's lazy history, measured bottom marker, deferred scrolling and
/// unread jump. The host still owns messages, retries, and search selection.
struct PendingConversationTimeline<Content: View>: View {
    let messageCount: Int
    let lastMessageIsUser: Bool
    let streamingText: String
    let activityRevision: String
    var jump: PendingTimelineJump?
    let onJumpConsumed: (UUID) -> Void
    @ViewBuilder let content: () -> Content
    @State private var isAtBottom = true
    @State private var unreadCount = 0
    @State private var initialScroll = false
    @State private var scrollRequest: UInt = 0
    @State private var initialAnchor: UnitPoint

    init(messageCount: Int, lastMessageIsUser: Bool, streamingText: String,
         activityRevision: String, jump: PendingTimelineJump? = nil,
         onJumpConsumed: @escaping (UUID) -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.messageCount = messageCount
        self.lastMessageIsUser = lastMessageIsUser
        self.streamingText = streamingText
        self.activityRevision = activityRevision
        self.jump = jump
        self.onJumpConsumed = onJumpConsumed
        self.content = content
        // Keep the opening anchor stable after the search request is consumed.
        _initialAnchor = State(initialValue: jump == nil ? .bottom : .top)
    }

    private func deferScroll() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Color.clear.frame(height: 8).id("top")
                        content()
                        Color.clear.frame(height: 1)
                            .background {
                                GeometryReader { marker in
                                    Color.clear.preference(key: PendingTimelineBottom.self,
                                        value: marker.frame(in: .named("pendingTimeline")).maxY)
                                }
                            }
                            .id("bottom")
                    }
                    .padding(.top, 4)
                    // A short chat fills one viewport and remains top-aligned
                    // even though long histories initially anchor at the end.
                    .frame(minHeight: max(0, viewport.size.height), alignment: .top)
                    .readableColumnWidth()
                }
                .coordinateSpace(name: "pendingTimeline")
                .defaultScrollAnchor(initialAnchor)
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(PendingTimelineBottom.self) { bottom in
                    guard let bottom, viewport.size.height > 0, jump == nil else { return }
                    let next = bottom - viewport.size.height <= 80
                    if isAtBottom != next { isAtBottom = next }
                    if next { unreadCount = 0 }
                }
                .onAppear {
                    guard jump == nil else { return }
                    initialScroll = true
                    scrollRequest &+= 1
                }
                .onChange(of: messageCount) { previous, current in
                    guard jump == nil else { return }
                    if !initialScroll || isAtBottom || lastMessageIsUser {
                        initialScroll = true
                        isAtBottom = true
                        unreadCount = 0
                        scrollRequest &+= 1
                    } else if current > previous {
                        unreadCount += current - previous
                    }
                }
                .onChange(of: streamingText) {
                    if isAtBottom && jump == nil { scrollRequest &+= 1 }
                }
                .onChange(of: activityRevision) {
                    if isAtBottom && jump == nil { scrollRequest &+= 1 }
                }
                .task(id: scrollRequest) {
                    guard scrollRequest > 0 else { return }
                    // Defer on the main queue as the original client does;
                    // yielding an executor is not a layout/run-loop boundary.
                    await deferScroll()
                    guard !Task.isCancelled, isAtBottom, jump == nil else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .task(id: jump?.id) {
                    guard let target = jump else { return }
                    isAtBottom = false
                    await deferScroll()
                    guard !Task.isCancelled else { return }
                    if let id = target.messageID { proxy.scrollTo(id, anchor: .center) }
                    else { proxy.scrollTo("top", anchor: .top) }
                    // A search jump is also an initial position. A later reply
                    // must not treat this timeline as awaiting its first scroll.
                    initialScroll = true
                    await deferScroll()
                    guard !Task.isCancelled else { return }
                    isAtBottom = false
                    onJumpConsumed(target.id)
                }
                .overlay(alignment: .bottomTrailing) {
                    if unreadCount > 0 && !isAtBottom {
                        PendingChatUnreadJumpButton(count: unreadCount) {
                            unreadCount = 0
                            isAtBottom = true
                            scrollRequest &+= 1
                        }
                        .padding(16)
                    }
                }
            }
        }
    }
}
