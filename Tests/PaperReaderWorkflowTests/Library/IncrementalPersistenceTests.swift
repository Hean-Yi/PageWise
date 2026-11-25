import CSQLite
import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test @MainActor func pagingFavoriteAndNoteEditingWriteOnlyTheirChangedRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = try LibraryStore(directory: root)
    let text = String(repeating: "fixture ", count: 16_384)
    var state = LibraryState()
    state.papers = (0..<12).map {
        Paper(
            title: "Fixture \($0)", digest: "digest-\($0)", originalPath: "unused.pdf", pageCount: 3,
            blocks: [TextBlock(sourcePage: 0, text: text)], warnings: [], canReflow: false)
    }
    let paper = state.papers[0]
    var note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [], markdown: "Initial")
    note.placement = .documentEnd
    state.readingNotes = [note]
    try await seed.save(state)
    let reader = try ReaderModel(root: root)
    await reader.load()
    reader.select(paper.id)
    await reader.workspaceSaveTask?.value

    var handle: OpaquePointer?
    #expect(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &handle) == SQLITE_OK)
    let db = try #require(handle)
    defer { sqlite3_close(db) }
    let audit = """
        CREATE TABLE audit(kind TEXT,n INTEGER);
        CREATE TRIGGER records_changed AFTER INSERT ON library_records BEGIN
            INSERT INTO audit VALUES(NEW.kind,length(NEW.payload));
        END;
        CREATE TRIGGER catalog_changed AFTER INSERT ON library BEGIN
            INSERT INTO audit VALUES('catalog',length(NEW.payload));
        END;
        """
    try #require(sqlite3_exec(db, audit, nil, nil, nil) == SQLITE_OK)
    reader.recordVisiblePage(1)
    await reader.workspaceSaveTask?.value
    reader.toggleFavorite(paper.id)
    await reader.workspaceSaveTask?.value
    reader.openReadingNote(note)
    #expect(reader.updateDocumentSummary(id: note.id, markdown: "Edited at the source"))
    await reader.flushReadingNotes()
    #expect(reader.savedNoteRevision == reader.noteRevision)

    let persisted = try await LibraryStore(directory: root).load()
    #expect(persisted.workspace[paper.id.uuidString]?.position?.pageIndex == 1)
    #expect(persisted.workspace[paper.id.uuidString]?.isFavorite == true)
    #expect(persisted.readingNotes.first?.markdown == "Edited at the source")
    var statement: OpaquePointer?
    try #require(sqlite3_prepare_v2(db, "SELECT kind,n FROM audit ORDER BY rowid", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    var kinds = [String]()
    var bytes: Int64 = 0
    while sqlite3_step(statement) == SQLITE_ROW {
        kinds.append(String(cString: sqlite3_column_text(statement, 0)))
        bytes += sqlite3_column_int64(statement, 1)
    }
    #expect(kinds == ["workspace", "workspace", "notes"])
    #expect(bytes < 2048)
    print(
        "Persistence fixture: snapshot \(try JSONEncoder().encode(state).count) bytes; three record writes \(bytes) bytes."
    )
}
