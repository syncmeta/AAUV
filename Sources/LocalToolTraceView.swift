import SwiftUI

/// Place below the triggering user bubble. The active ID must come from this
/// device's live reply Activity; a stored `running` value alone is not live work.
struct LocalToolTraceView: View {
    private let trace: LocalToolTrace?
    let activeRequestID: UUID?
    @State private var expanded = false

    init(trace: LocalToolTrace, activeRequestID: UUID? = nil) {
        self.trace = try? trace.validated()
        self.activeRequestID = activeRequestID
    }

    var body: some View {
        Group {
            if let trace, !trace.entries.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(trace.entries) { entry in row(entry, in: trace) }
                    }
                    .padding(.top, 5)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver").imageScale(.small)
                        Text("工具记录")
                        Text("\(trace.entries.count) 项")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: !expanded, vertical: true)
                .frame(maxWidth: expanded ? 520 : nil, alignment: .leading)
            }
        }
        // Observe even an empty reset envelope, so a tool-free/new run cannot
        // inherit the expanded state of the preceding run on this user bubble.
        .onChange(of: trace?.requestID) { expanded = false }
        .onChange(of: trace?.runRevision) { expanded = false }
    }

    private func row(_ entry: LocalToolTrace.Entry, in trace: LocalToolTrace) -> some View {
        let state = trace.displayState(for: entry, activeRequestID: activeRequestID)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if state == .running { ProgressView().controlSize(.mini) }
                Text(functionLabel(entry.function))
                Spacer(minLength: 4)
                Text(stateLabel(state))
            }
            if let query = entry.query {
                Text(query).lineLimit(3).textSelection(.enabled)
                if entry.queryTruncated == true { Text("检索词已截断").font(.caption2) }
            }
            if let name = entry.skillName { Text("技能：\(name)").textSelection(.enabled) }
            if let count = entry.quantity {
                switch entry.function {
                case .searchChatHistory: Text("找到 \(count) 条结果")
                case .sendImages: Text("已获取 \(count) 张图片")
                case .readAttachment, .delegateToSpecialist: Text("\(count) 字回答")
                case .createSkill: EmptyView()
                }
            }
            if let failure = entry.failure { Text(failureLabel(failure)).font(.caption2) }
        }
        .accessibilityElement(children: .combine)
    }

    private func functionLabel(_ function: LocalToolTrace.Function) -> LocalizedStringKey {
        switch function {
        case .searchChatHistory: "检索当前会话"
        case .createSkill: "保存技能"
        case .readAttachment: "读取附件"
        case .sendImages: "获取图片"
        case .delegateToSpecialist: "请教另一个模型"
        }
    }

    private func stateLabel(_ state: LocalToolTrace.DisplayState) -> LocalizedStringKey {
        switch state {
        case .running: "正在处理"
        case .succeeded: "完成"
        case .partial: "部分完成"
        case .failed: "未成功"
        case .unconfirmed: "未完成／状态未确认"
        }
    }

    private func failureLabel(_ failure: LocalToolTrace.Failure) -> LocalizedStringKey {
        switch failure {
        case .invalidInput: "工具输入无效"
        case .unavailable: "工具当前不可用"
        case .timeout: "工具等待超时"
        case .limit: "已达到工具限制"
        case .toolFailed: "工具未能完成"
        }
    }
}
