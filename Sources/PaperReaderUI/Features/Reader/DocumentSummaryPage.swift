import PaperReaderKit
import SwiftUI

/// A separate notebook page. Opening it keeps the source canvas and its reading position alive.
struct DocumentSummaryPage: View {
    let model: ReaderModel
    let note: ReadingNote
    @State private var citationRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: model.closeDocumentSummary) {
                    Label("返回正文", systemImage: "chevron.backward")
                }
                Divider().frame(height: 14)
                Text("文末总结").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if model.editingDocumentSummary {
                    Button {
                        citationRequest += 1
                    } label: {
                        Label("引用阅读笔记", systemImage: "link").labelStyle(.iconOnly)
                    }.help("引用阅读笔记")
                    Button("完成", action: finishEditing)
                } else {
                    Button {
                        model.editingDocumentSummary = true
                    } label: {
                        Label("编辑", systemImage: "square.and.pencil")
                    }
                    Menu {
                        Button("删除总结", role: .destructive) { model.deleteReadingNote(note.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }.menuIndicator(.hidden).accessibilityLabel("更多总结选项")
                }
            }.buttonStyle(.borderless).padding(.horizontal, 20).frame(minHeight: 46)
            Divider()
            StandaloneReadingNoteEditor(
                model: model, note: note, readOnly: !model.editingDocumentSummary,
                onDone: finishEditing, citationRequest: citationRequest
            ).id(model.editingDocumentSummary)
            if model.noteSaveFailed {
                Button("保存失败，重试") { Task { await model.flushReadingNotes() } }.padding(8)
            }
        }.background(ReaderTheme.surface)
    }

    private func finishEditing() {
        model.editingDocumentSummary = false
        Task { await model.flushReadingNotes() }
    }
}
