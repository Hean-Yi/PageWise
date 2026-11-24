import PaperReaderKit
import SwiftUI

/// Kept by the window while the notebook scroll view is unmounted. Updating this plain
/// reference while scrolling doesn't invalidate the library or its paper rows.
@MainActor final class NotebookScrollBookmark {
    fileprivate enum Place: Equatable {
        case offset(CGFloat)
        case bottom
    }

    fileprivate var place = Place.offset(0)
}

struct ReadingNotebooksView: View {
    let model: ReaderModel
    @Binding var expandedHistory: Set<UUID>
    let bookmark: NotebookScrollBookmark
    @Binding var expandedAnnotations: Set<UUID>
    @State private var scrollPosition = ScrollPosition()
    @State private var restoredViewport = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var headingSize = 30.0

    var body: some View {
        let notebooks = PaperReadingNotebook.notebooks(in: model.state)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("阅读笔记").font(ReaderTheme.editorial(headingSize, weight: .medium))
                        .accessibilityAddTraits(.isHeader)
                    if !notebooks.isEmpty {
                        Text("\(notebooks.count) 篇").font(.subheadline).foregroundStyle(ReaderTheme.muted)
                    }
                }
                .padding(.bottom, 14)
                paperRule

                if notebooks.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("还没有阅读笔记")
                        } icon: {
                            ReaderIcon(.notebook, size: 36)
                        }
                    } description: {
                        Text("在论文助读中完成 AI 精读后，可在这里重读文末笔记。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(notebooks) { notebook in
                        VStack(alignment: .leading, spacing: 0) {
                            if notebook.id != notebooks.first?.id { paperRule }
                            notebookSection(notebook).padding(.vertical, 24)
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: NotebookScrollBookmark.Place?.self) { geometry in
            guard geometry.containerSize.height > 0, geometry.contentSize.height > 0 else { return nil }
            let bottom = geometry.contentSize.height - geometry.visibleRect.height
            let y = min(max(0, geometry.visibleRect.minY), max(0, bottom))
            return bottom > 1 && bottom - y < 1 ? .bottom : .offset(y)
        } action: { _, current in
            guard model.selectedSection == "notebooks", let current else { return }
            if !restoredViewport {
                restoredViewport = true
                let saved = bookmark.place
                if current != saved {
                    switch saved {
                    case .bottom: scrollPosition.scrollTo(edge: .bottom)
                    case .offset(let y): scrollPosition.scrollTo(y: y)
                    }
                    return
                }
            }
            bookmark.place = current
        }
        .background(ReaderTheme.canvas).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
    }

    private var paperRule: some View {
        Rectangle().fill(contrast == .increased ? ReaderTheme.muted : ReaderTheme.line)
            .frame(height: 1 / displayScale).accessibilityHidden(true)
    }

    @ViewBuilder private func notebookSection(_ notebook: PaperReadingNotebook) -> some View {
        if let latest = notebook.entries.first {
            VStack(alignment: .leading, spacing: 12) {
                NotebookOpenButton(entry: latest, paperTitle: notebook.title) { open(latest.note) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        entryMetadata(latest)
                        Spacer(minLength: 10)
                        paperActions(notebook)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        entryMetadata(latest)
                        paperActions(notebook)
                    }
                }
                annotationList(latest)
                if notebook.entries.count > 1 {
                    let expanded = expandedHistory.contains(notebook.id)
                    disclosure("历史笔记 · \(notebook.entries.count - 1)", expanded: expanded) {
                        toggle(notebook.id, in: $expandedHistory)
                    }
                    if expanded {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(notebook.entries.dropFirst()) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    NotebookOpenButton(entry: entry, paperTitle: nil) { open(entry.note) }
                                    entryMetadata(entry)
                                    annotationList(entry)
                                }
                            }
                        }
                        .padding(.leading, 16).transition(.opacity)
                    }
                }
            }
        }
    }

    private func entryMetadata(_ entry: PaperReadingNotebook.Entry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { metadataItems(entry) }.fixedSize()
            VStack(alignment: .leading, spacing: 4) { metadataItems(entry) }
        }
        .font(.caption).foregroundStyle(ReaderTheme.muted)
    }

    @ViewBuilder private func metadataItems(_ entry: PaperReadingNotebook.Entry) -> some View {
        Text(entry.date, format: .dateTime.year().month(.twoDigits).day().hour().minute())
        if !entry.annotations.isEmpty {
            disclosure("\(entry.annotations.count) 条批注", expanded: expandedAnnotations.contains(entry.id)) {
                toggle(entry.id, in: $expandedAnnotations)
            }
        }
    }

    @ViewBuilder private func annotationList(_ entry: PaperReadingNotebook.Entry) -> some View {
        if expandedAnnotations.contains(entry.id) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.annotations) { note in
                    Button {
                        open(note)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle().fill(note.dimension?.swatch ?? ReaderTheme.muted)
                                .frame(width: 7, height: 7).accessibilityHidden(true)
                            let text = ReadingNoteSummary.bodyExcerpt(note.markdown)
                            Text(text.isEmpty ? note.anchors.first?.text ?? "打开批注" : text)
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            ReaderIcon(.openNote, size: 14)
                        }
                        .padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).multilineTextAlignment(.leading)
                    .accessibilityValue(note.dimension?.title ?? "批注")
                    .accessibilityHint("在原文位置打开批注")
                }
            }
            .font(.callout).padding(.leading, 14).transition(.opacity)
        }
    }

    private func disclosure(_ title: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ReaderIcon(.chevron, size: 12).rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title)
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .font(.caption).buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
        .accessibilityValue(expanded ? "已展开" : "已收起")
    }

    private func paperActions(_ notebook: PaperReadingNotebook) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { actionButtons(notebook) }.fixedSize()
            VStack(alignment: .leading, spacing: 6) { actionButtons(notebook) }
        }
        .font(.callout)
    }

    @ViewBuilder private func actionButtons(_ notebook: PaperReadingNotebook) -> some View {
        Button {
            model.select(notebook.id)
            model.showOriginalReading()
        } label: {
            Label {
                Text("原文")
            } icon: {
                ReaderIcon(.source, size: 15)
            }
        }
        .buttonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
        .accessibilityLabel("打开论文原文：\(notebook.title)")
        ObsidianExportButton(model: model, paperID: notebook.id)
    }

    private func toggle(_ id: UUID, in expanded: Binding<Set<UUID>>) {
        withAnimation(ReaderMotion.disclosure(reduceMotion)) {
            if expanded.wrappedValue.contains(id) {
                expanded.wrappedValue.remove(id)
            } else {
                expanded.wrappedValue.insert(id)
            }
        }
    }

    private func open(_ note: ReadingNote) {
        model.select(note.paperID)
        model.openReadingNote(note)
    }
}

private struct NotebookOpenButton: View {
    let entry: PaperReadingNotebook.Entry
    let paperTitle: String?
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var titleSize = 25.0

    var body: some View {
        let excerpt = ReadingNoteSummary.bodyExcerpt(entry.note.markdown)
        let focus = entry.focus == "AI 精读" ? "" : entry.focus
        Button(action: open) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    if let paperTitle {
                        Text(paperTitle).font(ReaderTheme.editorial(titleSize, weight: .medium))
                            .accessibilityAddTraits(.isHeader)
                    }
                    if !focus.isEmpty {
                        Text(focus).font(.subheadline.weight(.semibold))
                    }
                    if !excerpt.isEmpty {
                        Text(excerpt).font(.body).lineSpacing(3).lineLimit(3)
                            .foregroundStyle(ReaderTheme.ink.opacity(0.86))
                    } else if paperTitle == nil && focus.isEmpty {
                        Text("打开笔记").font(.body)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ReaderIcon(.openNote, size: paperTitle == nil ? 15 : 20)
                    .foregroundStyle(hovered ? ReaderTheme.accent : ReaderTheme.muted)
                    .offset(x: hovered && !reduceMotion ? 2 : 0)
                    .padding(.top, paperTitle == nil ? 1 : 5)
            }
            .foregroundStyle(hovered ? ReaderTheme.accent : ReaderTheme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).multilineTextAlignment(.leading)
        .onHover { hovered = $0 }
        .animation(ReaderMotion.feedback(reduceMotion), value: hovered)
        .accessibilityHint(entry.note.isDocumentSummary ? "打开文末笔记" : "在原文位置打开批注")
    }
}
