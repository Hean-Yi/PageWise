import PaperReaderKit
import SwiftUI

/// A separate notebook page. Opening it keeps the source canvas and its reading position alive.
struct DocumentSummaryPage: View {
    let model: ReaderModel
    let note: ReadingNote
    @State private var citationRequest = 0
    @AppStorage("PDFBilingualFontSize") private var pdfFontSize = 16

    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    navigation
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 4) {
                    navigation
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            .buttonStyle(.borderless).tint(ReaderTheme.accent)
            .padding(.horizontal, 20).frame(minHeight: 44).background(ReaderTheme.canvas)
            Divider()
            StandaloneReadingNoteEditor(
                model: model, note: note, citationRequest: citationRequest,
                summaryPDFFontSize: model.usesHTMLReading ? nil : pdfFontSize
            )
            if model.noteSaveFailed {
                Button("保存失败，重试") { Task { await model.flushReadingNotes() } }.padding(8)
            }
        }.background(ReaderTheme.surface)
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            Button(action: model.closeDocumentSummary) {
                Label("返回正文", systemImage: "chevron.backward")
            }
            Text("文末总结").font(ReaderTheme.editorial(titleSize, weight: .semibold))
                .foregroundStyle(ReaderTheme.ink).accessibilityAddTraits(.isHeader)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ObsidianExportButton(model: model, paperID: note.paperID)
            Button {
                citationRequest += 1
            } label: {
                Label("引用阅读笔记", readerIcon: .citation).labelStyle(.iconOnly).readerIconTarget()
            }
            .help("引用阅读笔记")
            Button(role: .destructive) {
                model.deleteReadingNote(note.id)
            } label: {
                Label("删除总结", readerIcon: .delete).labelStyle(.iconOnly).readerIconTarget()
            }
            .tint(ReaderTheme.muted).help("删除总结")
        }
        .padding(.horizontal, 8)
        .readerGlassSurface(in: Capsule(), fallback: ReaderTheme.elevated)
    }
}
