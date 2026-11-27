import PaperReaderKit
import SwiftUI

struct MemoryView: View {
    private enum OriginFilter: String, CaseIterable {
        case all = "全部"
        case edited = "已编辑"
        case preference = "回答偏好"
        case auto = "自动整理"
    }

    @Bindable var model: ReaderModel
    var onlyID: UUID?
    let openPaper: (UUID) -> Void
    @State private var maintenanceExpanded = false
    @State private var searchQuery = ""
    @State private var semanticMatchIDs: Set<UUID> = []
    @State private var originFilter: OriginFilter = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var allMemories: [MemoryItem] {
        model.state.memories.filter { $0.isActive && (onlyID == nil || $0.id == onlyID) }
    }
    private var memories: [MemoryItem] {
        guard onlyID == nil else { return allMemories }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return allMemories.filter { item in
            let matchesOrigin: Bool =
                switch originFilter {
                case .all: true
                case .edited: item.userEdited
                case .preference: item.isResponsePreference
                case .auto: !item.userEdited && !item.isResponsePreference
                }
            guard matchesOrigin else { return false }
            guard !trimmed.isEmpty else { return true }
            return item.text.localizedCaseInsensitiveContains(trimmed) || semanticMatchIDs.contains(item.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if onlyID == nil {
                maintenanceDisclosure
                if !allMemories.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
                            TextField("搜索研究记忆与偏好…", text: $searchQuery)
                                .textFieldStyle(.plain).font(.callout)
                            if !searchQuery.isEmpty {
                                Button {
                                    searchQuery = ""
                                } label: {
                                    ReaderIcon(.close, size: 12)
                                }
                                .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                            }
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderTheme.line))
                        HStack(spacing: 6) {
                            ForEach(OriginFilter.allCases, id: \.self) { option in
                                let selected = originFilter == option
                                Button(option.rawValue) { originFilter = option }
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.muted)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(
                                        selected ? ReaderTheme.accent.opacity(0.12) : ReaderTheme.surface,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(
                                            selected ? ReaderTheme.accent.opacity(0.45) : ReaderTheme.line))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            if memories.isEmpty {
                ContentUnavailableView(
                    allMemories.isEmpty ? "暂无研究记忆" : "没有匹配的研究记忆", systemImage: "brain.head.profile"
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                let groups = onlyID == nil ? currentGroups : []
                let organized = Set(groups.flatMap(\.members))
                if onlyID == nil {
                    Text("共 \(memories.count) 条")
                        .font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.muted)
                        .help("点击文字即可编辑，手动编辑后 AI 不会覆盖")
                }
                if !groups.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            DisclosureGroup {
                                VStack(spacing: 10) {
                                    ForEach(group.members, id: \.self) { id in
                                        if let memory = memories.first(where: { $0.id == id }) {
                                            memoryCard(memory)
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        (group.kind == .superseded || group.kind == .refine)
                                            ? "已更新"
                                            : group.kind == .compare
                                                ? "保留分歧" : group.kind == .duplicate ? "已归并" : "研究主题"
                                    )
                                    .font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.accent)
                                    if let summary = group.summary {
                                        Text(verbatim: summary).font(.callout).foregroundStyle(ReaderTheme.ink)
                                    }
                                }
                            }
                            .padding(14)
                            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
                        }
                    }
                }
                LazyVStack(spacing: 12) {
                    ForEach(memories.filter { !organized.contains($0.id) }) { memory in memoryCard(memory) }
                }
            }
        }
        .task(id: searchQuery) {
            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard onlyID == nil, !trimmed.isEmpty else {
                semanticMatchIDs = []
                return
            }
            let hits =
                (try? await model.researchMemory.relevant(
                    to: trimmed, state: model.state, excluding: model.pendingImportIDs)) ?? []
            guard !Task.isCancelled else { return }
            semanticMatchIDs = Set(hits.map(\.id))
        }
    }

    private var currentGroups: [MemorySleepEdition.Connection] {
        let origins = ResearchMemoryOrigins(state: model.state, excluding: model.pendingImportIDs)
        let live = memories.filter { origins.resolve($0) != nil }
        return model.memorySleep.edition.recallConnections(for: live)
    }

    private var maintenanceDisclosure: some View {
        @Bindable var sleep = model.memorySleep
        let semantic = SemanticModelSettings.shared
        let summaryText =
            (sleep.enabled ? "自动整理开" : "自动整理关")
            + " · "
            + (semantic.isBundled || semantic.installed ? "语义检索就绪" : "语义未安装")
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ReaderMotion.disclosure(reduceMotion)) { maintenanceExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ReaderActionSymbol("moon.stars").foregroundStyle(ReaderTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("维护与检索").font(.subheadline.weight(.semibold)).foregroundStyle(ReaderTheme.ink)
                        Text(summaryText).font(.caption).foregroundStyle(ReaderTheme.muted)
                    }
                    Spacer(minLength: 6)
                    if sleep.running {
                        ProgressView().controlSize(.small)
                    }
                    ReaderActionSymbol("chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ReaderTheme.muted)
                        .rotationEffect(.degrees(maintenanceExpanded ? 90 : 0))
                }
                .padding(14).contentShape(Rectangle())
            }
            .readerIconButtonStyle(.plain)
            .accessibilityValue(maintenanceExpanded ? "已展开" : "已收起")
            if !maintenanceExpanded, let message = sleep.message {
                Text(verbatim: message).font(.caption).foregroundStyle(ReaderTheme.accent)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
            if maintenanceExpanded {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("空闲时自动维护记忆", isOn: $sleep.enabled).font(.callout)
                            Spacer(minLength: 6)
                            if sleep.running {
                                ProgressView().controlSize(.small)
                                Button("停止") { sleep.interrupt() }.buttonStyle(.borderless).font(.caption)
                            } else {
                                Button("用 AI 整理") { sleep.run(reader: model, automatic: false, withModel: true) }
                                    .buttonStyle(.borderless).font(.caption).disabled(memories.isEmpty)
                            }
                        }
                        if let message = sleep.message {
                            Text(verbatim: message).font(.caption).foregroundStyle(ReaderTheme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .help("按批调用当前模型整理记忆并计入 API 用量，不覆盖手动编辑")
                    Divider()
                    SemanticModelSettingsRow(model: model)
                }
                .padding(14)
            }
        }
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
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
        VStack(alignment: .leading, spacing: 12) {
            TextField("研究关注点", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 15)).lineSpacing(4)
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
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
    }
}
