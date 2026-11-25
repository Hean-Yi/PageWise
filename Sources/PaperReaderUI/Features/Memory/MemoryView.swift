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
        if memories.isEmpty {
            ContentUnavailableView("暂无研究记忆", systemImage: "brain.head.profile")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(memories) { memory in memoryCard(memory) }
            }
        }
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
                Label(memory.userEdited ? "已编辑" : "自动整理", systemImage: memory.userEdited ? "pencil" : "sparkle")
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
