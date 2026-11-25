import CSQLite
import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@MainActor @Test func researchBriefFollowsAnImportedPaperAndEditedSummaryAndRepairsOnForeground() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let maintenance = reader.researchBriefMaintenance
    await maintenance.worker?.value
    let shelf = try #require(await reader.createShelf(name: "Measurement"))
    let pdf = root.appendingPathComponent("source.pdf")
    try DemoPaper.write(to: pdf)
    let id = try #require(await reader.importURLs([pdf], selectAfterImport: true, shelfID: shelf).first)
    let paper = try #require(reader.paper)
    #expect(paper.id == id)
    var note = ReadingNote(
        paperID: id, contentVersion: paper.digest + ":original-0", anchors: [],
        markdown: "One instrument measured noise.")
    note.placement = .documentEnd
    note.backgroundSources = .init()
    reader.state.readingNotes.append(note)
    #expect(await reader.save())
    await maintenance.worker?.value
    let before = try await reader.researchBrief(matching: "instrument")
    #expect(
        before.topics.contains {
            $0.label == "Measurement" && $0.sources.contains { $0.noteID == note.id && $0.noteOrigin == "aiDiscussion" }
        })
    #expect(reader.isResearchBriefCurrent(before))
    let revision = try #require(await reader.store.committedResearchState()?.1)
    let corrupt = Data("damaged".utf8)
    #expect(try await reader.store.publishResearchCheckpoint(corrupt, revision: revision))
    reader.setActive(false)
    let future = Date().addingTimeInterval(7 * 3600)
    maintenance.tick(now: future)
    #expect(maintenance.worker == nil)
    #expect(reader.updateDocumentSummary(id: note.id, markdown: "Spectrum calibration corrected the baseline."))
    #expect(!reader.isResearchBriefCurrent(before))  // Check revocation before the edit reaches disk.
    await reader.flushReadingNotes()
    #expect(maintenance.worker == nil)
    #expect(try await reader.store.readResearchCheckpoint() == corrupt)
    maintenance.setActive(true, now: future)
    await maintenance.worker?.value
    #expect(try await reader.store.readResearchCheckpoint() != corrupt)
    #expect(!before.isCurrent(in: reader.state, excluding: []))
    let changed = try await reader.researchBrief(matching: "calibration")
    #expect(
        changed.topics.flatMap(\.sources).contains { $0.noteID == note.id && $0.excerpt?.contains("corrected") == true }
    )
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    await reopened.researchBriefMaintenance.worker?.value
    let kept = try await reopened.researchBrief(matching: "spectrum")
    #expect(kept.topics.flatMap(\.sources).contains { $0.noteID == note.id })
}

@MainActor @Test func researchBriefDrainsMoreThanOneBoundedEventBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = Paper(
        title: "Batch source", digest: "batch", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    state.papers = [paper]
    state.readingNotes = (0..<300).map { index in
        ReadingNote(
            paperID: paper.id, contentVersion: "v", anchors: [], markdown: "Observation \(index) about calibration.")
    }
    #expect(try await store.save(state).researchSourcesChanged)
    let maintenance = ResearchBriefMaintenance(store: store, notes: ReadingNoteMemoryIndex())
    maintenance.sourcesChanged()
    await maintenance.worker?.value
    #expect(try await store.researchEventCounts().pending == 0)
    #expect(try await store.readResearchCheckpoint() != nil)
}

@MainActor @Test func researchBriefMaintenanceSkipsHotPositionAndTranslationSavesInALargeLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let prose = String(repeating: "Synthetic block. ", count: 64)
    state.papers = (0..<48).map { index in
        let blocks = (0..<80).map { TextBlock(sourcePage: $0, text: prose) }
        return Paper(
            title: "Laboratory series \(index)", digest: "d-\(index)", originalPath: "unused.pdf",
            pageCount: 80, blocks: blocks, warnings: [], canReflow: false)
    }
    #expect(try await store.save(state).researchSourcesChanged)
    let eventCounts = try await store.researchEventCounts()
    let researchGeneration = try await store.researchGeneration()
    let maintenance = ResearchBriefMaintenance(store: store, notes: ReadingNoteMemoryIndex())
    let start = Date()
    maintenance.sourcesChanged(now: start)
    await maintenance.worker?.value
    let original = try #require(try await store.readResearchCheckpoint())
    let measured = ContinuousClock.now
    for i in 0..<24 {
        let key = state.papers[i].id.uuidString
        state.workspace[key] = PaperWorkspace()
        state.workspace[key]?.isFavorite = i.isMultiple(of: 2)
        state.papers[i].translations["fixture"] = "\(i)"
        let change = try await store.save(state)
        #expect(!change.researchSourcesChanged)
        maintenance.tick(now: start.addingTimeInterval(Double(i * 60)))
        #expect(maintenance.worker == nil)
    }
    print(
        "research brief: 48 papers / 3840 blocks / 24 mixed workspace-translation commits and minute ticks: \(measured.duration(to: .now)), zero scheduled workers"
    )
    #expect(try await store.readResearchCheckpoint() == original)
    #expect(try await store.researchEventCounts().total == eventCounts.total)
    #expect(try await store.researchGeneration() == researchGeneration)
    state.papers[0].title = "Updated title"
    #expect(try await store.save(state).researchSourcesChanged)
}

@MainActor @Test func researchBriefFailureBacksOffBeforeRetrying() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = Paper(
        title: "Backoff source", digest: "backoff", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    state.papers = [paper]
    try await store.save(state)
    try withResearchDatabase(root) { db in
        let sql = """
            CREATE TABLE IF NOT EXISTS research_brief(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
            CREATE TRIGGER fail_brief BEFORE INSERT ON research_brief
            BEGIN SELECT RAISE(ABORT,'injected index failure'); END;
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    let maintenance = ResearchBriefMaintenance(store: store, notes: ReadingNoteMemoryIndex())
    maintenance.sourcesChanged()
    await maintenance.worker?.value
    #expect(maintenance.worker == nil)
    // A failed pass must wait for its short backoff instead of spinning on every minute tick.
    maintenance.tick(now: Date().addingTimeInterval(1))
    #expect(maintenance.worker == nil)
    try withResearchDatabase(root) { db in
        try #require(sqlite3_exec(db, "DROP TRIGGER fail_brief", nil, nil, nil) == SQLITE_OK)
    }
    maintenance.tick(now: Date().addingTimeInterval(20))
    await maintenance.worker?.value
    #expect(try await store.readResearchCheckpoint() != nil)
}

private func withResearchDatabase(_ root: URL, _ body: (OpaquePointer) throws -> Void) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &db, 2, nil) == SQLITE_OK, let db else {
        throw ReaderError.message("无法打开测试书库。")
    }
    defer { sqlite3_close(db) }
    try body(db)
}
