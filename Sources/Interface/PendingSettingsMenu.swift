import SwiftUI

enum PendingSettingsSubpage: Hashable {
    case modelServices
}

enum PendingSettingsDestination: String, CaseIterable, Identifiable {
    case all, providers, data, cloud, conversation, instructions, context, proxy, appearance, usage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "设置")
        case .providers: return String(localized: "模型服务")
        case .data: return String(localized: "配置与备份")
        case .cloud: return "iCloud"
        case .conversation: return String(localized: "会话")
        case .instructions: return String(localized: "提示词与技能")
        case .context: return String(localized: "上下文与压缩")
        case .proxy: return String(localized: "网络与代理")
        case .appearance: return String(localized: "外观")
        case .usage: return String(localized: "模型用量")
        }
    }
}

/// PendingBot MeTabView's header, spacing, option rows and grouped cards.
/// The display identity is local; provider account details are not shown here.
struct PendingMeMenu<Destination: View>: View {
    var selection: Binding<PendingSettingsDestination?>? = nil
    var wide = false
    var showsNavigationBar = false
    var onEditingVisibilityChange: ((UUID, Bool) -> Void)? = nil
    @ViewBuilder var destination: (PendingSettingsDestination) -> Destination
    @AppStorage(LocalDisplayProfile.storageKey) private var profileData = Data()
    @State private var editingProfile = false
    @State private var profileEditorID = UUID()

    private var profile: LocalDisplayProfile { LocalDisplayProfile.decode(profileData) ?? .placeholder }

    private let groups: [[PendingSettingsDestination]] = [
        [.providers, .data, .cloud],
        [.instructions, .context, .conversation, .usage],
        [.proxy, .appearance]
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Button { editingProfile = true } label: {
                    VStack(spacing: 16) {
                        PendingChatAvatar(seed: profile.avatarSeed, size: 88)
                            .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 7)
                        Text(profile.name)
                            .font(Theme.Fonts.scriptTitle(profile.name, size: 24))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更换地名和头像")

                ForEach(groups.indices, id: \.self) { index in
                    VStack(spacing: 0) {
                        ForEach(Array(groups[index].enumerated()), id: \.element.id) { row, item in
                            if row > 0 {
                                Rectangle().fill(Theme.Palette.hairline.opacity(0.7))
                                    .frame(height: 0.5).padding(.horizontal, 20)
                            }
                            menuRow(item)
                        }
                    }
                    .pendingMeGroup()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 72)
            .padding(.bottom, 32)
        }
        .background {
            if !wide { Theme.Palette.canvas.ignoresSafeArea() }
        }
        .navigationTitle("")
        .sheet(isPresented: $editingProfile) {
            PendingLocalProfileEditor(profile: profile) { profileData = $0 }
                .onAppear { onEditingVisibilityChange?(profileEditorID, true) }
                .onDisappear { onEditingVisibilityChange?(profileEditorID, false) }
        }
        #if os(iOS)
        .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder private func menuRow(_ item: PendingSettingsDestination) -> some View {
        if let selection {
            Button { selection.wrappedValue = item } label: {
                PendingOptionRow(title: item.title)
                    .background(selection.wrappedValue == item ? Theme.Palette.accentBg : .clear)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink { destination(item) } label: { PendingOptionRow(title: item.title) }
                .buttonStyle(.plain)
        }
    }
}

private struct PendingLocalProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: LocalDisplayProfile
    @State private var problem: String?
    let save: (Data) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                PendingChatAvatar(seed: profile.avatarSeed, size: 88)
                TextField("地名", text: $profile.name)
                    .font(Theme.Fonts.scriptTitle(profile.name, size: 24))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("地名")
                HStack(spacing: 20) {
                    Button("换一个") { profile = .random(); problem = nil }
                    Button("更换头像") { profile.avatarSeed = UUID().uuidString; problem = nil }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("地名和头像")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            save(try JSONEncoder().encode(profile.validated()))
                            dismiss()
                        } catch { problem = error.localizedDescription }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 420)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}

private struct PendingOptionRow: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Fonts.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(Theme.Fonts.glyph(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.inkMuted.opacity(0.55))
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 50)
        .contentShape(Rectangle())
    }
}

private extension View {
    func pendingMeGroup() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return background(shape.fill(Theme.Palette.surface))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 1.5)
    }
}
