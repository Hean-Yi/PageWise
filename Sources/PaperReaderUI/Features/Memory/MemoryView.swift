import PaperReaderKit
import SwiftUI

struct MemoryView: View {
    @Bindable var model: ReaderModel
    var onlyID: UUID?
    let openPaper: (UUID) -> Void
    private var memories: [MemoryItem] {
        model.state.memories.filter { !$0.deleted && (onlyID == nil || $0.id == onlyID) }
    }

    var body: some View {
        if onlyID == nil {
            sleepPanel
        }
        if memories.isEmpty {
            ContentUnavailableView("暂无研究记忆", systemImage: "brain.head.profile")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(spacing: 12) {
                let organized = onlyID == nil ? Set(currentGroups.flatMap(\.members)) : []
                ForEach(memories.filter { !organized.contains($0.id) }) { memory in memoryCard(memory) }
            }
        }
    }

    private var currentGroups: [MemorySleepEdition.Connection] {
        let origins = ResearchMemoryOrigins(state: model.state, excluding: model.pendingImportIDs)
        let live = memories.filter { origins.resolve($0) != nil }
        return model.memorySleep.edition.recallConnections(for: live)
    }

    private var sleepPanel: some View {
        @Bindable var sleep = model.memorySleep
        let groups = currentGroups
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("记忆整理", systemImage: "moon.stars").font(.headline)
                Spacer()
                if sleep.running {
                    ProgressView().controlSize(.small)
                    Button("停止") { sleep.interrupt() }
                } else {
                    Button("用 AI 整理") { sleep.run(reader: model, automatic: false, withModel: true) }
                        .disabled(memories.isEmpty)
                }
            }
            Toggle("空闲时自动维护记忆", isOn: $sleep.enabled)
            Text("使用当前模型服务，发送本批记忆并计入 API 用量。")
                .font(.caption).foregroundStyle(ReaderTheme.muted)
            @Bindable var noteReview = model.noteReview
            HStack {
                Toggle("空闲时整理笔记", isOn: $noteReview.enabled)
                Spacer()
                if noteReview.running {
                    ProgressView().controlSize(.small)
                    Button("停止") { noteReview.interrupt() }
                } else {
                    Button("整理笔记") { noteReview.run(reader: model, automatic: false, withModel: true) }
                        .disabled(model.state.readingNotes.allSatisfy { $0.deletedAt != nil })
                }
            }
            Picker("整理间隔", selection: $noteReview.interval) {
                Text("30 分钟").tag(TimeInterval(1_800))
                Text("1 小时").tag(TimeInterval(3_600))
                Text("3 小时").tag(TimeInterval(10_800))
                Text("6 小时").tag(TimeInterval(21_600))
                Text("12 小时").tag(TimeInterval(43_200))
                Text("一天").tag(TimeInterval(86_400))
            }
            .pickerStyle(.menu)
            Text("只有新增笔记或阅读状态变化时才调用模型；更新会追加为新修订，保留原笔记。")
                .font(.caption).foregroundStyle(ReaderTheme.muted)
            if let reviewMessage = noteReview.message {
                Text(verbatim: reviewMessage).font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            if let message = sleep.message {
                Text(verbatim: message).font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                DisclosureGroup {
                    ForEach(group.members, id: \.self) { id in
                        if let memory = memories.first(where: { $0.id == id }) {
                            memoryCard(memory)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            (group.kind == .superseded || group.kind == .refine)
                                ? "已更新" : group.kind == .compare ? "保留分歧" : group.kind == .duplicate ? "已归并" : "研究主题"
                        )
                        .font(.caption).foregroundStyle(ReaderTheme.accent)
                        if let summary = group.summary { Text(verbatim: summary) }
                    }
                }
            }
        }.padding(.bottom, 12)
    }

    private func memoryCard(_ memory: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField(
                "研究关注点",
                text: Binding(
                    get: { model.state.memories.first { $0.id == memory.id }?.text ?? "" },
                    set: { model.updateMemory(id: memory.id, text: $0) }), axis: .vertical
            )
            .textFieldStyle(.plain).font(.system(size: 16)).lineSpacing(5)
            .accessibilityLabel("编辑研究记忆")
            HStack(spacing: 14) {
                Label(
                    memory.userEdited ? "已编辑" : memory.isResponsePreference ? "读者自述" : "自动整理",
                    systemImage: memory.userEdited ? "pencil" : "sparkle"
                )
                .font(.caption)
                Spacer()
                if case .note(let paperID, let revision) = memory.librarySource,
                    let note = model.referencedReadingNote(id: memory.sourceID, paperID: paperID),
                    note.modifiedAt == revision
                {
                    Button {
                        openPaper(paperID)
                        model.openReadingNote(note)
                    } label: {
                        Label("来源笔记", readerIcon: .source, size: 15)
                    }
                } else if case .note = memory.librarySource {
                    Text("来源笔记已变更")
                } else if case .paper(let paperID) = memory.librarySource {
                    Button {
                        openPaper(paperID)
                    } label: {
                        Label("来源论文", readerIcon: .source, size: 15)
                    }.help("打开来源论文")
                } else if memory.librarySource == nil,
                    let source = model.state.chats.first(where: { $0.id == memory.sourceID }),
                    model.state.papers.contains(where: { $0.id == source.paperID })
                {
                    Button {
                        openPaper(source.paperID)
                    } label: {
                        Label("来源", readerIcon: .source, size: 15)
                    }.help("打开来源论文")
                }
                Button(role: .destructive) {
                    model.deleteMemory(memory.id)
                } label: {
                    ReaderIcon(.delete, size: 15).readerIconTarget(macOS: 24)
                }
                .accessibilityLabel("删除此条记忆").help("删除记忆")
            }
            .font(.caption).foregroundStyle(ReaderTheme.muted).readerIconButtonStyle(.borderless)
            if case .reader(let quote) = memory.librarySource {
                DisclosureGroup("读者原话") { Text(verbatim: quote).textSelection(.enabled) }
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line))
    }
}
