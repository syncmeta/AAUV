#if os(macOS)
import SwiftUI

struct PendingWorkspaceActions {
    var newConversation: (() -> Void)?
    var newBot: (() -> Void)?
    var search: () -> Void
    var settings: () -> Void
}

private struct PendingWorkspaceActionsKey: FocusedValueKey {
    typealias Value = PendingWorkspaceActions
}

extension FocusedValues {
    var pendingWorkspaceActions: PendingWorkspaceActions? {
        get { self[PendingWorkspaceActionsKey.self] }
        set { self[PendingWorkspaceActionsKey.self] = newValue }
    }
}

/// Original menu actions resolve through the focused local workspace.
struct PendingAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.pendingWorkspaceActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建机器人") { actions?.newBot?() }
                .disabled(actions?.newBot == nil)
            Button("新建会话") { actions?.newConversation?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.newConversation == nil)
            Button("新建窗口") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("搜索") {
            Button("搜索") { actions?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { actions?.settings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
#endif
