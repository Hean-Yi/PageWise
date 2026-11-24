import SwiftUI

struct PDFReadingNoteCard: View {
    let model: ReaderModel
    let session: PDFNoteEditorSession
    @State private var citationRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let dimension = session.note.dimension {
                    Label {
                        Text(dimension.title)
                    } icon: {
                        Circle().fill(dimension.swatch).frame(width: 10, height: 10)
                    }
                    .font(.headline)
                } else {
                    Label("阅读笔记", readerIcon: .notebook).font(.headline)
                }
                if let page = session.note.anchors.first?.readingPageIndex {
                    Text("第 \(page + 1) 页").font(.caption).foregroundStyle(ReaderTheme.muted)
                }
                Spacer()
                Button {
                    citationRequest += 1
                } label: {
                    ReaderIcon(.citation).readerIconTarget()
                }
                .readerIconButtonStyle(.borderless).help("引用阅读笔记").accessibilityLabel("引用阅读笔记")
                if model.currentReadingNotes.contains(where: { $0.id == session.id }) {
                    Button {
                        model.deleteReadingNote(session.id)
                    } label: {
                        ReaderIcon(.delete).readerIconTarget()
                    }
                    .readerIconButtonStyle(.borderless).help("删除笔记").accessibilityLabel("删除笔记")
                }
            }.padding([.horizontal, .top], 14)
            Text(session.note.anchors.map(\.text).joined(separator: " "))
                .font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            StandaloneReadingNoteEditor(model: model, note: session.note, citationRequest: citationRequest).id(
                session.id)
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
