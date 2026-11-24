import PaperReaderKit
import SwiftUI

struct NotePassageSheetView: View {
    let model: ReaderModel
    let sheet: NotePassageSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    ReaderIcon(.citation, size: 19)
                }.font(ReaderTheme.editorial(21))
                Spacer()
                Button {
                    model.notePassageSheet = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ReaderTheme.muted)
                }.buttonStyle(.plain).accessibilityLabel("关闭").keyboardShortcut(.cancelAction)
            }
            switch sheet {
            case .picker(let draft): NotePassagePicker(model: model, draft: draft)
            case .preview(let noteID, let citationID):
                NotePassagePreviewView(model: model, noteID: noteID, citationID: citationID)
            }
        }
        .padding(22).background(ReaderTheme.surface)
        #if os(macOS)
            .frame(width: 500)
        #endif
    }

    private var title: String {
        switch sheet {
        case .picker: "引用阅读笔记"
        case .preview: "引用预览"
        }
    }
}

private struct NotePassagePicker: View {
    let model: ReaderModel
    let draft: NotePassageDraft
    @State private var query = ""
    @State private var choices: [Evidence] = []
    @State private var loading = true
    @State private var error: String?
    @State private var insertion: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
                TextField("搜索笔记或论文标题", text: $query).textFieldStyle(.plain)
            }
            .padding(9).background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            Group {
                if let error {
                    Text(error).foregroundStyle(ReaderTheme.muted)
                } else if loading {
                    ProgressView().accessibilityLabel("搜索阅读笔记")
                } else if choices.isEmpty {
                    Text(query.isEmpty ? "暂无其他阅读笔记" : "没有找到匹配的笔记").foregroundStyle(ReaderTheme.muted)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(choices) { choice in
                                Button {
                                    insertion = Task {
                                        defer { insertion = nil }
                                        do {
                                            try await model.insertNotePassage(choice, into: draft)
                                        } catch is CancellationError {} catch {
                                            self.error = error.localizedDescription
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: choice.title).font(.caption).foregroundStyle(
                                                ReaderTheme.muted
                                            ).lineLimit(1)
                                            Text(verbatim: choice.text).font(.callout).lineLimit(3)
                                                .multilineTextAlignment(
                                                    .leading)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "plus").foregroundStyle(ReaderTheme.accent)
                                    }
                                    .padding(.vertical, 9).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(insertion != nil)
                                Divider()
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 210, maxHeight: 300)
        }
        .task(id: query) {
            loading = true
            error = nil
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                let results = try await model.readingNoteEvidence(query: query, limit: 31)
                try Task.checkCancellation()
                choices = Array(results.lazy.filter { $0.readingNoteID != draft.noteID }.prefix(30))
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }.onDisappear { insertion?.cancel() }
    }
}

private struct NotePassagePreviewView: View {
    let model: ReaderModel
    let noteID: UUID
    let citationID: UUID
    @State private var preview: LocalPassagePreview?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error {
                Text(error).font(.callout).foregroundStyle(ReaderTheme.muted)
            } else if let preview {
                Text(preview.title).font(.headline)
                Text(preview.location).font(.caption).foregroundStyle(ReaderTheme.muted)
                ScrollView {
                    if let markdown = preview.noteMarkdown {
                        AssistantMarkdownText(markdown: markdown)
                    } else {
                        (Text(verbatim: preview.before).foregroundColor(ReaderTheme.muted)
                            + Text(verbatim: preview.quote).fontWeight(.semibold).foregroundColor(ReaderTheme.ink)
                            + Text(verbatim: preview.after).foregroundColor(ReaderTheme.muted))
                            .font(.body).lineSpacing(4).textSelection(.enabled).frame(
                                maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxHeight: 230)
                HStack {
                    Spacer()
                    Button {
                        Task {
                            do {
                                try await model.openLocalPassage(preview)
                                model.notePassageSheet = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        if preview.readingNoteID == nil {
                            Label("打开原文", readerIcon: .source)
                        } else {
                            Label("打开笔记", readerIcon: .notebook)
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(ReaderTheme.accent)
                }
            } else {
                ProgressView().accessibilityLabel("核对引文")
            }
        }
        .task(id: model.noteRevision) {
            preview = nil
            error = nil
            do { preview = try await model.previewLocalPassage(noteID: noteID, citationID: citationID) } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
