import Foundation
import Testing

@testable import PaperReaderKit

@Test func agentNoteRevisionKeepsTheReadersOriginalTextInHistory() {
    var note = ReadingNote(
        paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Reader original wording.")
    let originalDate = note.modifiedAt
    let applied = note.applyAIRevision(
        "Updated wording with a new source.", at: originalDate.addingTimeInterval(60))
    #expect(applied)
    #expect(note.markdown == "Updated wording with a new source.")
    #expect(note.revisions?.count == 1)
    #expect(note.revisions?.first?.markdown == "Reader original wording.")
    #expect(note.revisions?.first?.author == .reader)
    let repeated = note.applyAIRevision(note.markdown)
    #expect(!repeated)
    #expect(note.revisions?.count == 1)
}

@Test func agentNoteRevisionDoesNotReviveADeletedNote() {
    var note = ReadingNote(paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Deleted note.")
    note.deletedAt = Date()
    let applied = note.applyAIRevision("Should not appear.")
    #expect(!applied)
    #expect(note.markdown == "Deleted note.")
}
