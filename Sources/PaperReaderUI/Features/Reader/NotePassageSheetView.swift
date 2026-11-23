import PaperReaderKit
import SwiftUI

struct NotePassageSheetView: View {
    let model: ReaderModel
    let sheet: NotePassageSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: "link").font(ReaderTheme.editorial(21))
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
        case .picker: "引用书库片段"
        case .preview: "原文片段"
        }
    }
}

private struct NotePassagePicker: View {
    let model: ReaderModel
    let draft: NotePassageDraft
    @State private var paperID: UUID
    @State private var query = ""
    @State private var page = ""
    @State private var choices: [LocalPassageChoice] = []
    @State private var loading = true
    @State private var error: String?
    @State private var insertion: Task<Void, Never>?

    init(model: ReaderModel, draft: NotePassageDraft) {
        self.model = model
        self.draft = draft
        _paperID = State(initialValue: draft.paperID)
    }

    private struct Search: Equatable {
        let paperID: UUID
        let query: String
        let page: String
    }

    var body: some View {
        let search = Search(paperID: paperID, query: query, page: page)
        VStack(alignment: .leading, spacing: 10) {
            Picker("论文", selection: $paperID) {
                ForEach(model.state.papers) { Text($0.title).tag($0.id) }
            }.pickerStyle(.menu).onChange(of: paperID) { _, _ in page = "" }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
                TextField("查找原文", text: $query).textFieldStyle(.plain)
                Divider().frame(height: 17)
                TextField("页码", text: $page).textFieldStyle(.plain).frame(width: 42).accessibilityLabel("限定原页")
            }
            .padding(9).background(ReaderTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            Group {
                if let error {
                    Text(error).foregroundStyle(ReaderTheme.muted)
                } else if loading {
                    ProgressView().accessibilityLabel("查找本地原文")
                } else if choices.isEmpty {
                    Text("没有找到对应的原文片段").foregroundStyle(ReaderTheme.muted)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(choices, id: \.id) { choice in
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
                                            Text(choice.location).font(.caption).foregroundStyle(ReaderTheme.muted)
                                            Text(choice.quote).font(.callout).lineLimit(3).multilineTextAlignment(
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
        .task(id: search) {
            loading = true
            error = nil
            choices = []
            do {
                let trimmed = search.page.trimmingCharacters(in: .whitespaces)
                let number = Int(trimmed)
                if !trimmed.isEmpty {
                    guard let number, let document = model.state.papers.first(where: { $0.id == search.paperID }),
                        number >= 1, number <= document.pageCount
                    else { throw ReaderError.message("请输入论文范围内的原页页码。") }
                }
                if !search.query.isEmpty { try await Task.sleep(for: .milliseconds(220)) }
                let results = try await model.localPassageChoices(
                    paperID: search.paperID, query: search.query, pageIndex: number.map { $0 - 1 })
                try Task.checkCancellation()
                choices = results
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
                    (Text(verbatim: preview.before).foregroundColor(ReaderTheme.muted)
                        + Text(verbatim: preview.quote).fontWeight(.semibold).foregroundColor(ReaderTheme.ink)
                        + Text(verbatim: preview.after).foregroundColor(ReaderTheme.muted))
                        .font(.body).lineSpacing(4).textSelection(.enabled).frame(
                            maxWidth: .infinity, alignment: .leading)
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
                        Label("打开原文", systemImage: "arrow.up.forward")
                    }
                    .buttonStyle(.borderedProminent).tint(ReaderTheme.accent)
                }
            } else {
                ProgressView().accessibilityLabel("核对引文")
            }
        }
        .task(id: citationID) {
            preview = nil
            error = nil
            do { preview = try await model.previewLocalPassage(noteID: noteID, citationID: citationID) } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
