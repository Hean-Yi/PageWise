import PaperReaderKit
import SwiftUI

struct MemoryView: View {
    @Bindable var model: ReaderModel
    var onlyID: UUID?
    let openPaper: (UUID) -> Void
    private var memories: [MemoryItem] {
        model.state.memories.filter { $0.isActive && (onlyID == nil || $0.id == onlyID) }
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

    private static let reviewIntervals: [(label: String, seconds: TimeInterval)] = [
        ("30 分钟", 1_800), ("1 小时", 3_600), ("3 小时", 10_800),
        ("6 小时", 21_600), ("12 小时", 43_200), ("一天", 86_400),
    ]

    private var sleepPanel: some View {
        @Bindable var sleep = model.memorySleep
        @Bindable var noteReview = model.noteReview
        let groups = currentGroups
        let currentIntervalLabel =
            Self.reviewIntervals.first { abs($0.seconds - noteReview.interval) < 1 }?.label ?? "6 小时"
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("记忆空闲整理", systemImage: "moon.stars").font(.subheadline.weight(.semibold))
                    Spacer()
                    if sleep.running {
                        ProgressView().controlSize(.small)
                        Button("停止") { sleep.interrupt() }.buttonStyle(.borderless).font(.caption)
                    } else {
                        Button("用 AI 整理") { sleep.run(reader: model, automatic: false, withModel: true) }
                            .buttonStyle(.borderless).font(.caption).disabled(memories.isEmpty)
                    }
                }
                Toggle("空闲时自动维护记忆", isOn: $sleep.enabled).font(.callout)
                Text("使用当前模型服务，发送本批记忆并计入 API 用量。")
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
                if let message = sleep.message {
                    Text(verbatim: message).font(.caption).foregroundStyle(ReaderTheme.accent)
                }
            }
            .padding(16)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("空闲时整理笔记", isOn: $noteReview.enabled).font(.callout)
                    Spacer()
                    if noteReview.running {
                        ProgressView().controlSize(.small)
                        Button("停止") { noteReview.interrupt() }.buttonStyle(.borderless).font(.caption)
                    } else {
                        Button("整理笔记") { noteReview.run(reader: model, automatic: false, withModel: true) }
                            .buttonStyle(.borderless).font(.caption)
                            .disabled(model.state.readingNotes.allSatisfy { $0.deletedAt != nil })
                    }
                }
                HStack {
                    Text("整理间隔").font(.callout).foregroundStyle(ReaderTheme.muted)
                    Spacer()
                    ReaderPopupMenu(
                        "整理间隔",
                        items: Self.reviewIntervals.map { option in
                            .action(option.label, selected: abs(option.seconds - noteReview.interval) < 1) {
                                noteReview.interval = option.seconds
                            }
                        }, width: 150
                    ) {
                        ReaderMenuValueLabel(currentIntervalLabel).font(.callout)
                    }
                    .accessibilityValue(currentIntervalLabel)
                }
                Text("只有新增笔记或阅读状态变化时才调用模型；更新会追加为新修订，保留原笔记。")
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
                if let reviewMessage = noteReview.message {
                    Text(verbatim: reviewMessage).font(.caption).foregroundStyle(ReaderTheme.accent)
                }
            }
            .padding(16)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))

            SemanticModelSettingsRow(model: model)
                .padding(16)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))

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
        MemoryCardEditor(model: model, memory: memory, openPaper: openPaper)
    }
}

/// Debounces edits so typing into a memory card does not trigger a SQLite save transaction and
/// research-event emission on every keystroke.
private struct MemoryCardEditor: View {
    let model: ReaderModel
    let memory: MemoryItem
    let openPaper: (UUID) -> Void
    @State private var draft: String
    @State private var saveTask: Task<Void, Never>?
    @State private var justSaved = false
    @FocusState private var focused: Bool

    init(model: ReaderModel, memory: MemoryItem, openPaper: @escaping (UUID) -> Void) {
        self.model = model
        self.memory = memory
        self.openPaper = openPaper
        _draft = State(initialValue: memory.text)
    }

    private func commitIfNeeded() {
        saveTask?.cancel()
        saveTask = nil
        let latest = model.state.memories.first { $0.id == memory.id }?.text ?? memory.text
        guard draft != latest else { return }
        model.updateMemory(id: memory.id, text: draft)
        justSaved = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField("研究关注点", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 16)).lineSpacing(5)
                .focused($focused)
                .accessibilityLabel("编辑研究记忆")
                .onChange(of: draft) { _, newValue in
                    let latest = model.state.memories.first { $0.id == memory.id }?.text ?? memory.text
                    guard newValue != latest else { return }
                    justSaved = false
                    saveTask?.cancel()
                    saveTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        commitIfNeeded()
                    }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commitIfNeeded() }
                }
                .onChange(of: memory.text) { _, external in
                    if !focused && draft != external { draft = external }
                }
                .onDisappear { commitIfNeeded() }
            HStack(spacing: 14) {
                Label(
                    memory.userEdited ? "已编辑" : memory.isResponsePreference ? "读者自述" : "自动整理",
                    systemImage: memory.userEdited ? "pencil" : "sparkle"
                )
                .font(.caption)
                if justSaved {
                    Text("已保存").font(.caption2).foregroundStyle(ReaderTheme.accent)
                }
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
                    saveTask?.cancel()
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
