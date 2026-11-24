import PaperReaderKit
import SwiftUI

/// A separate notebook page. Opening it keeps the source canvas and its reading position alive.
struct DocumentSummaryPage: View {
    let model: ReaderModel
    let note: ReadingNote
    @State private var citationRequest = 0
    @State private var finishRequest = 0
    @AppStorage("PDFBilingualFontSize") private var pdfFontSize = 16

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: model.closeDocumentSummary) {
                    Label("返回正文", systemImage: "chevron.backward")
                }
                Text("文末总结").font(ReaderTheme.editorial(16, weight: .semibold)).foregroundStyle(ReaderTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                ObsidianExportButton(model: model, paperID: note.paperID)
                if model.editingDocumentSummary {
                    Button {
                        citationRequest += 1
                    } label: {
                        Label("引用阅读笔记", systemImage: "link").labelStyle(.iconOnly)
                    }.help("引用阅读笔记")
                    Button("完成") { finishRequest += 1 }
                } else {
                    Menu {
                        Button("删除总结", role: .destructive) { model.deleteReadingNote(note.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }.menuIndicator(.hidden).accessibilityLabel("更多总结选项")
                }
            }.buttonStyle(.borderless).tint(ReaderTheme.accent)
                .padding(.horizontal, 20).frame(minHeight: 44).background(ReaderTheme.canvas)
            Divider()
            StandaloneReadingNoteEditor(
                model: model, note: note, finishRequest: finishRequest, citationRequest: citationRequest,
                summaryPDFFontSize: model.usesHTMLReading ? nil : pdfFontSize
            )
            if model.noteSaveFailed {
                Button("保存失败，重试") { Task { await model.flushReadingNotes() } }.padding(8)
            }
        }.background(ReaderTheme.surface)
    }
}
