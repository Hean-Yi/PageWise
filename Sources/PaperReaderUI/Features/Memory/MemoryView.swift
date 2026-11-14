import PaperReaderKit
import SwiftUI

struct MemoryView: View {
    @Bindable var model: ReaderModel
    private var memories: [MemoryItem] { model.state.memories.filter { !$0.deleted } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("研究记忆").font(.system(size: 32, weight: .regular, design: .serif))
                    Text("\(memories.count)").font(.system(.title3, design: .monospaced))
                        .foregroundStyle(ReaderTheme.muted)
                    Spacer()
                }
                if memories.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "brain.head.profile").font(.system(size: 42, weight: .ultraLight))
                        Text("从一次讨论开始").font(.headline)
                        Button {
                            model.select(model.selectedPaperID ?? model.state.papers.first?.id)
                        } label: {
                            Label("去阅读", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.borderless).foregroundStyle(ReaderTheme.accent).font(.caption)
                    }
                    .foregroundStyle(ReaderTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(memories) { memory in
                            memoryCard(memory)
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
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
                if let source = model.state.chats.first(where: { $0.id == memory.sourceID }) {
                    Button {
                        model.select(source.paperID)
                    } label: {
                        Label("来源", systemImage: "arrow.up.right")
                    }.help("打开来源论文")
                }
                Button(role: .destructive) {
                    model.deleteMemory(memory.id)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除此条记忆").help("删除记忆")
            }
            .font(.caption).foregroundStyle(ReaderTheme.muted).buttonStyle(.borderless)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line))
    }
}
