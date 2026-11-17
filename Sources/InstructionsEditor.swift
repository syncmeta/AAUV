import SwiftUI
import UniformTypeIdentifiers

struct InstructionsEditor: View {
    @Binding var instructions: BotInstructions
    @State private var kind = InstructionFile.Kind.prompt
    @State private var picker = false
    @State private var loading = false
    @State private var failure: String?
    @State private var importedLangfuse = false

    private var entries: Binding<[BotSkill]> {
        Binding(get: { instructions.skillEntries ?? [] }, set: { instructions.skillEntries = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Text("提示词")
        TextEditor(text: $instructions.prompt)
            .frame(minHeight: 75)
            .accessibilityLabel("提示词")
        Button("从文件导入提示词…") { kind = .prompt; picker = true }
            .disabled(loading)
        Button("从 Langfuse JSON 导入…") { kind = .langfuse; picker = true }
            .disabled(loading)
        if importedLangfuse {
            Text("已载入正文。请核对模板变量和旧版工具说明后保存。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if instructions.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("填入大绿豆对话风格") {
                instructions.prompt = BotInstructions.aauvConversationStyle
            }
            .disabled(loading)
        }
        if !instructions.skills.isEmpty {
            Text("原有技能文本")
            TextEditor(text: $instructions.skills)
                .frame(minHeight: 75)
                .accessibilityLabel("原有技能文本")
        }
        ForEach(entries) { $entry in
            DisclosureGroup {
                Toggle("在模型请求中启用", isOn: $entry.enabled)
                TextField("技能名称", text: $entry.name)
                TextEditor(text: $entry.markdown)
                    .frame(minHeight: 95)
                    .accessibilityLabel("技能 Markdown 正文")
                Button("移除技能", role: .destructive) {
                    let id = entry.id
                    entries.wrappedValue.removeAll { $0.id == id }
                }
            } label: {
                Label(entry.name.isEmpty ? "未命名技能" : entry.name,
                      systemImage: entry.enabled ? "checkmark.circle.fill" : "circle")
            }
        }
        Button("新建技能", systemImage: "plus") { entries.wrappedValue.append(BotSkill()) }
            .disabled(loading || entries.wrappedValue.count >= BotInstructions.skillLimit)
        Button("导入 Markdown 技能…", systemImage: "doc.badge.plus") { kind = .skills; picker = true }
            .disabled(loading || entries.wrappedValue.count >= BotInstructions.skillLimit)
        if loading { ProgressView("正在读取文件…") }
        if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
        Text("启用的技能随提示词发送给模型。导入的技能默认关闭，保存后生效。")
            .font(.footnote)
            .fileImporter(isPresented: $picker, allowedContentTypes: kind == .langfuse
                          ? [.json] : [.plainText, UTType(filenameExtension: "md") ?? .text],
                          allowsMultipleSelection: kind == .skills, onCompletion: importFiles)
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        let kind = kind
        let original = instructions
        failure = nil
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do {
                let files = try result.get()
                guard !files.isEmpty else { return }
                if kind == .skills, files.count + entries.wrappedValue.count > BotInstructions.skillLimit {
                    throw ChatClient.ClientError.message("每份提示词最多保存 100 个技能。")
                }
                let draft = try await Task.detached {
                    try InstructionFile.importing(files, kind: kind, into: original)
                }.value
                guard instructions == original else {
                    throw ChatClient.ClientError.message("读取文件时编辑内容已变化，请重新导入。")
                }
                instructions = draft
                if kind != .skills { importedLangfuse = kind == .langfuse }
            } catch { failure = error.localizedDescription }
        }
    }
}

enum InstructionFile {
    enum Kind { case prompt, skills, langfuse }

    static func importing(_ files: [URL], kind: Kind, into original: BotInstructions) throws -> BotInstructions {
        var draft = original
        switch kind {
        case .prompt:
            if let file = files.first { draft.prompt = try read(file) }
        case .langfuse:
            if let file = files.first { draft.prompt = try langfusePrompt(from: read(file, limit: 8 * 1024 * 1024)) }
        case .skills:
            for file in files {
                let text = try read(file)
                let name = file.deletingPathExtension().lastPathComponent
                draft.skillEntries = (draft.skillEntries ?? []) + [BotSkill(name: name, markdown: text)]
                _ = try draft.validated()
            }
        }
        return try draft.validated()
    }

    private struct LangfusePrompt: Decodable {
        let name: String
        let labels: [String]?
        let text: String?

        enum CodingKeys: String, CodingKey { case name, type, labels, prompt }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            name = try fields.decode(String.self, forKey: .name)
            let type = try fields.decode(String.self, forKey: .type)
            labels = try fields.decodeIfPresent([String].self, forKey: .labels)
            text = type == "text" ? try fields.decode(String.self, forKey: .prompt) : nil
        }
    }

    private static func langfusePrompt(from source: String) throws -> String {
        let decoder = JSONDecoder()
        let data = Data(source.utf8)
        let entry: LangfusePrompt
        if let list = try? decoder.decode([LangfusePrompt].self, from: data) {
            let production = list.filter { $0.name == "system/zh" && $0.labels?.contains("production") == true }
            guard production.count == 1, let selected = production.first else {
                throw ChatClient.ClientError.message("请在 Langfuse 导出时包含所有版本，并确认有唯一的 system/zh 生产版本。也可以导入单条文本提示词的 API 响应。")
            }
            entry = selected
        } else if let single = try? decoder.decode(LangfusePrompt.self, from: data) {
            entry = single
        } else {
            throw ChatClient.ClientError.message("请选择 Langfuse 的提示词导出文件或单条提示词 API 响应。")
        }
        guard let text = entry.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatClient.ClientError.message("请选择有正文的 Langfuse 文本提示词。")
        }
        return text
    }

    private static func read(_ file: URL, limit: Int = BotInstructions.byteLimit) throws -> String {
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            result = Result {
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard properties.isRegularFile == true else { throw CocoaError(.fileReadCorruptFile) }
                guard let size = properties.fileSize, size <= limit else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                var data = Data()
                while let chunk = try input.read(upToCount: min(65_536, limit + 1 - data.count)),
                      !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ChatClient.ClientError.message("请选择 UTF-8 编码的文件。")
                }
                return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
