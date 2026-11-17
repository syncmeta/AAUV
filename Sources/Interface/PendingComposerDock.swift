import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// The host supplies its local draft projection and actions. On iOS the
    /// composer physically rides the native keyboard during interactive drags.
    func pendingComposerDock(content: PendingComposer) -> some View {
        modifier(PendingComposerDockModifier(composer: content))
    }
}

private struct PendingComposerDockModifier: ViewModifier {
    let composer: PendingComposer
    @Environment(\.isEnabled) private var isEnabled
    #if os(iOS)
    @State private var composerHeight: CGFloat = 58
    @State private var keyboardVisible = false
    @State private var panelVisible = false
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: keyboardVisible ? 0 : composerHeight)
                    .allowsHitTesting(false)
            }
            .background {
                PendingComposerAccessory(
                    content: composer.configuredForDock(enabled: isEnabled) { panelVisible = $0 },
                    composerHeight: $composerHeight,
                    keyboardVisible: keyboardVisible,
                    panelVisible: panelVisible
                )
                .frame(width: 0, height: 0)
            }
            // Use discrete show/hide notifications so the message viewport
            // does not jump mid-drag. Native keyboard avoidance follows every
            // frame while the accessory moves with the keyboard itself.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                guard let info = note.userInfo,
                      let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                let visibleHeight = max(0, UIScreen.main.bounds.height - endFrame.minY)
                guard visibleHeight > 180, !keyboardVisible else { return }
                let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                withAnimation(.easeOut(duration: duration)) { keyboardVisible = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                guard keyboardVisible else { return }
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                withAnimation(.easeOut(duration: duration)) { keyboardVisible = false }
            }
        #else
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            composer.configuredForDock(enabled: isEnabled).background(Theme.Palette.canvas)
        }
        #endif
    }
}
