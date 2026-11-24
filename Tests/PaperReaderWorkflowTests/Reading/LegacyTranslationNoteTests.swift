import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test @MainActor func legacyTranslationInkOpensOnlyTheUniqueNoteThatContainsItsExactPassage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let paperID = try #require(await reader.importURLs([try DemoPaper.fileURL()]).first)
    let version = try #require(reader.paper).digest + ":original-0"
    func anchor(_ sentenceID: String, _ translation: String) -> NoteAnchor {
        NoteAnchor(
            key: "original-0",
            target: NoteAnchor.pdfTranslationTarget(sentenceID: sentenceID, translation: translation),
            text: translation, start: 0, end: translation.utf16.count)
    }
    let first = anchor("s1", "容易组。")
    let second = anchor("s2", "📚困难组，题目不同。")
    let note = ReadingNote(paperID: paperID, contentVersion: version, anchors: [first, second], markdown: "核对分组权重")
    var mark = Highlight(paperID: paperID, pageKey: second.key, pageIndex: 0, text: "困难组", rects: [])
    mark.contentVersion = version
    mark.pdfTranslationTarget = second.target
    mark.textRange = [2, 5]
    reader.state.highlights = [mark]
    reader.state.readingNotes = [note]
    reader.state.version = 12
    reader.state = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(reader.state))

    await reader.openPDFHighlightNote(mark)?.value
    #expect(reader.pdfNoteEditor?.note == note)
    #expect(reader.currentReadingNotes == [note])

    var otherNote = note
    otherNote.id = UUID()
    #expect(mark.legacyPDFTranslationNote(in: [note, otherNote], contentVersion: version) == nil)
    otherNote.anchors = [first]
    #expect(mark.legacyPDFTranslationNote(in: [otherNote], contentVersion: version) == nil)
    otherNote.anchors = [second]
    otherNote.anchors[0].target = "pdf"
    #expect(mark.legacyPDFTranslationNote(in: [otherNote], contentVersion: version) == nil)
    otherNote.anchors = [second]
    otherNote.anchors[0].target = anchor("s2", "📚困难组，题目已修改。").target
    #expect(mark.legacyPDFTranslationNote(in: [otherNote], contentVersion: version) == nil)
    mark.textRange = [6, 9]
    #expect(mark.legacyPDFTranslationNote(in: [note], contentVersion: version) == nil)
}
