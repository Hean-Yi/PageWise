import PaperReaderKit
import SwiftUI

struct ReaderNotesView: View {
    @Bindable var model: ReaderModel
    let summarize: () -> Void
    let didNavigate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    readingNotes
                    bookmarks
                    highlights
                    if let paper = model.paper, !paper.summary.isEmpty || !paper.blocks.isEmpty {
                        summary
                    }
                }.padding(20)
            }
            Divider()
            if let paperID = model.selectedPaperID {
                ObsidianExportButton(model: model, paperID: paperID, offersDiscussion: true)
                    .font(.callout.weight(.medium)).padding(12)
            }
        }
    }

    private var readingNotes: some View {
        let notes = model.currentReadingNotes
        return Section {
            ForEach(notes) { note in
                Button {
                    model.openReadingNote(note)
                    didNavigate()
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        if note.isDocumentSummary {
                            Label("文末总结", readerIcon: .notebook, size: 14).font(.caption)
                        } else if let dimension = note.dimension {
                            Label {
                                Text(dimension.title)
                            } icon: {
                                Circle().fill(dimension.swatch).frame(width: 8, height: 8)
                            }.font(.caption)
                        }
                        if let quote = note.anchors.first?.text {
                            Text(ReadingNoteSummary.excerpt(quote)).font(.system(size: 11))
                                .foregroundStyle(
                                    ReaderTheme.muted
                                ).lineLimit(2)
                        }
                        Text(note.markdown.isEmpty ? "空白笔记" : ReadingNoteSummary.text(note.markdown)).font(
                            .system(size: 13)
                        ).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.readerIconButtonStyle(AssistantToolButtonStyle())
            }
            if model.lastDeletedNoteID != nil {
                Button("撤销删除笔记", action: model.undoReadingNoteDeletion).font(.system(size: 12))
            }
        } header: {
            heading("阅读笔记", icon: "note.text", count: notes.count)
        }
    }

    private var bookmarks: some View {
        let marks = model.currentBookmarks
        return Section {
            if marks.isEmpty {
                Button(action: model.toggleBookmark) {
                    Label("标记当前页", readerIcon: .add, size: 14).font(.system(size: 12))
                }.readerIconButtonStyle(.borderless).foregroundStyle(ReaderTheme.muted).disabled(
                    model.displayedPageKeys.isEmpty)
            } else {
                ForEach(marks) { mark in
                    HStack(spacing: 10) {
                        Button {
                            model.navigate(to: mark)
                            didNavigate()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bookmark.fill").readerSymbolInk().foregroundStyle(ReaderTheme.accent)
                                Text("\(readingModeTitle(mark.mode)) · 第 \(mark.pageIndex + 1) 页")
                                Spacer()
                                Image(systemName: "arrow.up.right").readerSymbolInk().foregroundStyle(ReaderTheme.muted)
                            }.contentShape(Rectangle())
                        }.readerIconButtonStyle(.plain)
                        Button {
                            model.removeBookmark(mark.id)
                        } label: {
                            ReaderIcon(.close, size: 13)
                        }
                        .readerIconButtonStyle(.plain).foregroundStyle(ReaderTheme.muted).help("移除书签")
                        .accessibilityLabel("移除书签")
                    }.font(.system(size: 12)).padding(12)
                        .background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } header: {
            heading("书签", icon: "bookmark", count: marks.count).padding(.top, 14)
        }
    }

    private var highlights: some View {
        let marks = model.currentHighlights
        return Section {
            ForEach(marks.reversed()) { mark in
                Button {
                    model.navigate(to: mark)
                    didNavigate()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1).fill(ReaderTheme.accent.opacity(0.5)).frame(width: 2)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(mark.text).font(.system(size: 12)).lineSpacing(4).lineLimit(7)
                                .multilineTextAlignment(.leading)
                            HStack {
                                Text("第 \(mark.pageIndex + 1) 页")
                                Spacer()
                                Image(systemName: "arrow.up.right").readerSymbolInk()
                            }.font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                        }
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 6).contentShape(Rectangle())
                }.readerIconButtonStyle(.plain)
            }
        } header: {
            heading("划线", icon: "highlighter", count: marks.count).padding(.top, 14)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("总结", icon: "text.alignleft", count: nil).padding(.top, 14)
            if let text = model.paper?.summary, !text.isEmpty {
                Text(text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
            }
            if model.paper?.blocks.isEmpty == false {
                Button(action: summarize) {
                    Label(model.paper?.summary.isEmpty == false ? "重新生成" : "生成论文总结", systemImage: "sparkles")
                        .labelStyle(ReaderSymbolLabelStyle())
                        .font(.system(size: 12))
                }.readerIconButtonStyle(.borderless).disabled(model.busyAI)
            }
        }
    }

    private func heading(_ title: String, icon: String, count: Int?) -> some View {
        HStack(spacing: 7) {
            Label(title, systemImage: icon)
            if let count { Text("\(count)").foregroundStyle(ReaderTheme.muted) }
            Spacer()
        }.font(.system(size: 12, weight: .medium))
    }
}
