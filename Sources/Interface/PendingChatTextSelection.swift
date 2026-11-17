import Combine
import SwiftUI

/// Hover ownership deliberately does not invalidate the conversation view.
/// Only the old/new owning rows update their local selection environment.
final class PendingChatSelectionOwner {
    static let shared = PendingChatSelectionOwner()
    private let subject = CurrentValueSubject<String?, Never>(nil)

    var publisher: AnyPublisher<String?, Never> { subject.eraseToAnyPublisher() }
    var current: String? { subject.value }

    func arm(_ id: String) {
        guard subject.value != id else { return }
        subject.send(id)
    }
}

private struct PendingChatTextSelection: ViewModifier {
    let id: String
    var owner: PendingChatSelectionOwner = .shared
    @State private var armed = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { inside in if inside { owner.arm(id) } }
            .onReceive(owner.publisher) { holder in
                let next = holder == id
                if armed != next { armed = next }
            }
            .onAppear { armed = owner.current == id }
            .environment(\.pendingChatSelectable, armed)
        #else
        content.environment(\.pendingChatSelectable, true)
        #endif
    }
}

private struct PendingChatSelectableKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var pendingChatSelectable: Bool {
        get { self[PendingChatSelectableKey.self] }
        set { self[PendingChatSelectableKey.self] = newValue }
    }
}

private struct PendingChatSelectableText: ViewModifier {
    @Environment(\.pendingChatSelectable) private var selectable

    @ViewBuilder
    func body(content: Content) -> some View {
        if selectable {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

extension View {
    /// Markdown/text children must use this instead of a nested always-enabled
    /// selection modifier so macOS materializes native selection only on hover.
    func pendingChatSelectableText() -> some View {
        modifier(PendingChatSelectableText())
    }

    /// The last hovered bubble retains selection after exit, allowing a drag
    /// to continue beyond its bounds. iOS keeps native selection enabled.
    func pendingChatTextSelection(id: String) -> some View {
        modifier(PendingChatTextSelection(id: id))
    }
}
