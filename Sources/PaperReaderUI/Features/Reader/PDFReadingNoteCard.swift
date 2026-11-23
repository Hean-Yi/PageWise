import SwiftUI

struct PDFReadingNoteCard: View {
    let model: ReaderModel
    let session: PDFNoteEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("阅读笔记", systemImage: "note.text").font(.headline)
                if let page = session.note.anchors.first?.pdfPageIndex {
                    Text("第 \(page + 1) 页").font(.caption).foregroundStyle(ReaderTheme.muted)
                }
                Spacer()
                if model.currentReadingNotes.contains(where: { $0.id == session.id }) {
                    Button {
                        model.deleteReadingNote(session.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless).help("删除笔记").accessibilityLabel("删除笔记")
                }
            }.padding([.horizontal, .top], 14)
            Text(session.note.anchors.map(\.text).joined(separator: " "))
                .font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            PDFReadingNoteEditor(model: model, session: session).id(session.id)
            Divider()
            HStack {
                if model.noteSaveFailed {
                    Button("保存失败，重试") { Task { await model.flushReadingNotes() } }
                } else if model.currentReadingNotes.contains(where: { $0.id == session.id }) {
                    Text(model.savedNoteRevision < model.noteRevision ? "保存中…" : "已保存")
                        .foregroundStyle(ReaderTheme.muted)
                }
                Spacer()
                Button("完成", action: model.closePDFReadingNote).buttonStyle(.borderedProminent).tint(ReaderTheme.accent)
            }.font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line) }
    }
}
