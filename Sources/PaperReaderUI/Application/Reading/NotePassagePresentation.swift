import Foundation
import PaperReaderKit

/// Keep the cursor and draft captured when the reader opens the library picker.
@MainActor struct NotePassageDraft {
    let id = UUID()
    let noteID: UUID
    let paperID: UUID
    let version: String
    let anchors: [NoteAnchor]
    let markdown: String
    let range: NSRange
    let didInsert: @MainActor (String) -> Void
}

enum NotePassageSheet: Identifiable {
    case picker(NotePassageDraft)
    case preview(noteID: UUID, citationID: UUID)

    var id: UUID {
        switch self {
        case .picker(let draft): draft.id
        case .preview(_, let citationID): citationID
        }
    }
}

extension ReaderModel {
    func pickNotePassage(
        noteID: UUID, anchors: [NoteAnchor], source: String, from: Int, to: Int,
        didInsert: @escaping @MainActor (String) -> Void
    ) {
        guard let paper, from >= 0, from <= to, to <= source.utf16.count, !anchors.isEmpty
        else { return }
        let version = htmlAnnotationVersion ?? (paper.digest + ":original-0")
        notePassageSheet = .picker(
            NotePassageDraft(
                noteID: noteID, paperID: paper.id, version: version, anchors: anchors, markdown: source,
                range: NSRange(location: from, length: to - from), didInsert: didInsert))
    }

    func insertNotePassage(_ choice: LocalPassageChoice, into draft: NotePassageDraft) async throws {
        let citation = try await makeLocalPassageCitation(choice: choice)
        try Task.checkCancellation()
        guard case .picker(let active) = notePassageSheet, active.id == draft.id,
            let paper, paper.id == draft.paperID,
            (htmlAnnotationVersion ?? (paper.digest + ":original-0")) == draft.version,
            currentReadingNotes.first(where: { $0.id == draft.noteID })?.markdown ?? "" == draft.markdown,
            let range = Range(draft.range, in: draft.markdown)
        else { throw ReaderError.message("笔记内容或阅读位置已变化，请重新插入引用。") }
        let selection = String(draft.markdown[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = choice.evidence.title
        let shortTitle = title.count > 48 ? String(title.prefix(47)) + "…" : title
        // Replacing a selected Markdown link should never expose its old destination as the new label.
        let replacesLink = selection.localizedCaseInsensitiveContains("paperreader://passage/")
        let label = selection.isEmpty || replacesLink ? shortTitle + " · " + choice.location : selection
        let link = citation.markdown(label: label)
        let updated = draft.markdown.replacingCharacters(in: range, with: link)
        try insertLocalPassageCitation(citation, noteID: draft.noteID, anchors: draft.anchors, markdown: updated)
        draft.didInsert(link)
        notePassageSheet = nil
    }

    func presentNotePassage(noteID: UUID, citationID: UUID) {
        guard let note = currentReadingNotes.first(where: { $0.id == noteID }),
            note.citations?.contains(where: { $0.id == citationID }) == true
        else { return }
        notePassageSheet = .preview(noteID: noteID, citationID: citationID)
    }
}
