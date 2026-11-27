import PaperReaderKit
import SwiftUI

struct ReaderNotesView: View {
    private enum NoteLayerFilter: String, CaseIterable {
        case all = "全部"
        case mine = "我的笔记"
        case ai = "AI 精读"
    }

    @Bindable var model: ReaderModel
    let summarize: () -> Void
    let didNavigate: () -> Void
    @State private var noteFilter: NoteLayerFilter = .all
    @State private var inspectingRevisionNoteID: UUID?

    var body: some View {
        let notes = model.currentReadingNotes
        let marks = model.currentBookmarks
        let highlightsList = model.currentHighlights
        let isEmptyAll = notes.isEmpty && marks.isEmpty && highlightsList.isEmpty && model.lastDeletedNoteID == nil
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if isEmptyAll {
                        emptyState
                    } else {
                        if !notes.isEmpty || model.lastDeletedNoteID != nil { readingNotes }
                        bookmarks
                        if !highlightsList.isEmpty { highlights }
                    }
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("这篇论文还没有笔记", systemImage: "note.text")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ReaderTheme.ink)
            Text("拖选原文可高亮或写页边笔记，按 ⌘D 可添加书签，也可以在「论文助读」中运行 AI 精读。")
                .font(.caption).foregroundStyle(ReaderTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: model.toggleBookmark) {
                Label("标记当前页", readerIcon: .add, size: 14).font(.caption.weight(.medium))
            }
            .readerIconButtonStyle(.borderless).foregroundStyle(ReaderTheme.accent)
            .disabled(model.displayedPageKeys.isEmpty)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line))
    }

    private func isAINote(_ note: ReadingNote) -> Bool {
        note.isDocumentSummary || note.dimension != nil || note.backgroundSources != nil
    }

    private var readingNotes: some View {
        let allNotes = model.currentReadingNotes
        let hasUserNotes = allNotes.contains { !isAINote($0) }
        let hasAINotes = allNotes.contains { isAINote($0) }
        let notes: [ReadingNote] =
            switch noteFilter {
            case .all: allNotes
            case .mine: allNotes.filter { !isAINote($0) }
            case .ai: allNotes.filter { isAINote($0) }
            }
        return Section {
            if hasUserNotes && hasAINotes {
                HStack(spacing: 6) {
                    ForEach(NoteLayerFilter.allCases, id: \.self) { option in
                        let selected = noteFilter == option
                        Button(option.rawValue) { noteFilter = option }
                            .buttonStyle(.plain)
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.muted)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(
                                selected ? ReaderTheme.accent.opacity(0.12) : ReaderTheme.surface,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(selected ? ReaderTheme.accent.opacity(0.45) : ReaderTheme.line))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 4)
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.openReadingNote(note)
                        didNavigate()
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                if note.isDocumentSummary {
                                    Label("文末总结", readerIcon: .notebook, size: 14).font(.caption)
                                } else if let dimension = note.dimension {
                                    Label {
                                        Text(dimension.title)
                                    } icon: {
                                        Circle().fill(dimension.swatch).frame(width: 8, height: 8)
                                    }.font(.caption)
                                }
                                Spacer(minLength: 0)
                                if let count = note.revisions?.count, count > 0 {
                                    Text("含 \(count) 条历史修订")
                                        .font(.caption2).foregroundStyle(ReaderTheme.accent)
                                }
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
                    if let revisions = note.revisions, !revisions.isEmpty {
                        Button {
                            inspectingRevisionNoteID = inspectingRevisionNoteID == note.id ? nil : note.id
                        } label: {
                            Label("查看修订与回退", systemImage: "clock.arrow.circlepath")
                                .font(.caption2.weight(.medium)).foregroundStyle(ReaderTheme.accent)
                        }
                        .buttonStyle(.plain).padding(.leading, 4)
                        .popover(
                            isPresented: Binding(
                                get: { inspectingRevisionNoteID == note.id },
                                set: {
                                    if !$0 && inspectingRevisionNoteID == note.id { inspectingRevisionNoteID = nil }
                                }
                            )
                        ) {
                            NoteRevisionHistoryPopover(model: model, note: note) {
                                inspectingRevisionNoteID = nil
                            }
                        }
                    }
                }
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
                                ReaderActionSymbol("bookmark.fill").foregroundStyle(ReaderTheme.accent)
                                Text("\(readingModeTitle(mark.mode)) · 第 \(mark.pageIndex + 1) 页")
                                Spacer()
                                ReaderActionSymbol("arrow.up.right").foregroundStyle(ReaderTheme.muted)
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
            HStack(spacing: 7) {
                Label("书签", systemImage: "bookmark")
                Text("\(marks.count)").foregroundStyle(ReaderTheme.muted)
                Spacer()
                if !marks.isEmpty {
                    Button(action: model.toggleBookmark) {
                        Text(model.isCurrentPageBookmarked ? "取消当前页" : "+ 当前页")
                            .font(.system(size: 11)).foregroundStyle(ReaderTheme.accent)
                    }
                    .readerIconButtonStyle(.borderless).disabled(model.displayedPageKeys.isEmpty)
                }
            }
            .font(.system(size: 12, weight: .medium)).padding(.top, model.currentReadingNotes.isEmpty ? 0 : 14)
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
                                ReaderActionSymbol("arrow.up.right")
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

private struct NoteRevisionHistoryPopover: View {
    let model: ReaderModel
    let note: ReadingNote
    let dismiss: () -> Void
    @State private var restoringID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("笔记修订历史").font(ReaderTheme.editorial(16, weight: .semibold))
                Spacer()
                Button("关闭", action: dismiss).buttonStyle(.borderless).font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前版本").font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.accent)
                        Text(note.markdown).font(.caption).lineSpacing(2).textSelection(.enabled)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                    ForEach((note.revisions ?? []).reversed()) { rev in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(rev.author == .reader ? "读者原版" : "AI 修订版")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(rev.author == .reader ? ReaderTheme.ink : ReaderTheme.muted)
                                Text(rev.modifiedAt, format: .dateTime.month(.twoDigits).day().hour().minute())
                                    .font(.caption2).foregroundStyle(ReaderTheme.muted)
                                Spacer()
                                Button {
                                    restoringID = rev.id
                                    Task {
                                        _ = await model.restoreReadingNoteRevision(noteID: note.id, revisionID: rev.id)
                                        restoringID = nil
                                        dismiss()
                                    }
                                } label: {
                                    Text(restoringID == rev.id ? "恢复中…" : "恢复此版本")
                                        .font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.accent)
                                }
                                .buttonStyle(.borderless).disabled(restoringID != nil)
                            }
                            Text(rev.markdown).font(.caption).lineSpacing(2).foregroundStyle(ReaderTheme.muted)
                                .textSelection(.enabled)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderTheme.line))
                    }
                }
            }
        }
        .padding(14).frame(width: 340).frame(maxHeight: 380)
        .readerPopupSurface()
    }
}
