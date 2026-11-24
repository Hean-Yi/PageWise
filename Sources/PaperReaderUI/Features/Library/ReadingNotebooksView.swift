import PaperReaderKit
import SwiftUI

struct ReadingNotebooksView: View {
    let model: ReaderModel
    @Binding var expandedHistory: Set<UUID>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notebooks = PaperReadingNotebook.notebooks(in: model.state)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                Text("阅读笔记").font(ReaderTheme.editorial(32, weight: .medium)).accessibilityAddTraits(.isHeader)
                if notebooks.isEmpty {
                    ContentUnavailableView(
                        "还没有阅读笔记", systemImage: "book.pages",
                        description: Text("在论文助读中完成 AI 精读后，可在这里重读文末笔记。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(notebooks) { notebook in
                    notebookSection(notebook)
                }
            }
            .padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
    }

    private func notebookSection(_ notebook: PaperReadingNotebook) -> some View {
        let expanded = expandedHistory.contains(notebook.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(notebook.title).font(ReaderTheme.editorial(21, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button {
                    model.select(notebook.id)
                    model.showOriginalReading()
                } label: {
                    Label("原文", systemImage: "doc.text.magnifyingglass").fixedSize()
                }
                .buttonStyle(.borderless).font(.callout)
                .accessibilityLabel("打开论文原文：\(notebook.title)")
            }
            VStack(alignment: .leading, spacing: 0) {
                if let latest = notebook.entries.first { noteRow(latest) }
                if notebook.entries.count > 1 {
                    Divider()
                    Button {
                        if expanded { expandedHistory.remove(notebook.id) } else { expandedHistory.insert(notebook.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.forward").font(.caption2)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Text("历史笔记 · \(notebook.entries.count - 1)")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(ReaderTheme.muted)
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                    if expanded {
                        ForEach(notebook.entries.dropFirst()) { entry in
                            Divider()
                            noteRow(entry)
                        }
                    }
                }
            }
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line).allowsHitTesting(false) }
        }
        .animation(ReaderMotion.disclosure(reduceMotion), value: expanded)
    }

    private func noteRow(_ entry: PaperReadingNotebook.Entry) -> some View {
        let excerpt = ReadingNoteSummary.text(entry.note.markdown)
        let general = entry.focus.isEmpty || entry.focus == "AI 精读"
        return Button {
            model.select(entry.note.paperID)
            model.openReadingNote(entry.note)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(general ? (excerpt.isEmpty ? "文末笔记" : excerpt) : entry.focus)
                        .font(.body.weight(.medium)).lineLimit(2)
                    if !general && !excerpt.isEmpty {
                        Text(excerpt).font(.callout).foregroundStyle(ReaderTheme.muted).lineLimit(2)
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(ReaderTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
