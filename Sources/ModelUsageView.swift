import SwiftUI

struct ModelUsageView: View {
    let store: ConversationStore
    @State private var usage: [ModelUsage] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("累计记录服务商返回的输入和输出 Token。").font(.footnote)
                if let error { Text(error).foregroundStyle(.secondary) }
                if usage.isEmpty && error == nil { Text("暂无用量记录。").foregroundStyle(.secondary) }
            }
            ForEach(usage) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.model)
                    Text("\(provider(item.provider)) · \(purpose(item.purpose)) · \(item.requests.formatted()) 次")
                    Text("输入 \(item.input.formatted()) · 输出 \(item.output.formatted())")
                }
                .font(.body)
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("模型用量")
        .onAppear {
            do { usage = try store.readUsage() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func purpose(_ value: ModelUsage.Purpose) -> String {
        switch value {
        case .reply: "聊天"
        case .compression: "上下文压缩"
        case .title: "会话标题"
        }
    }

    private func provider(_ method: LoginMethod) -> String {
        switch method {
        case .byok: return "BYOK"
        case .chatgpt: return "ChatGPT"
        case .copilot: return "GitHub Copilot"
        }
    }
}
