import CSQLite
import Foundation
import Testing

@testable import PaperReaderKit

private func maintenancePaper(_ title: String) -> Paper {
    Paper(
        title: title, digest: UUID().uuidString, originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
}

private func withMaintenanceDatabase(_ root: URL, _ body: (OpaquePointer) throws -> Void) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &db, 2, nil) == SQLITE_OK, let db else {
        throw ReaderError.message("无法打开测试书库。")
    }
    defer { sqlite3_close(db) }
    try body(db)
}

@Test func researchIndexConsumesTheEventWatermarkAndRebuildsAfterDerivedDataLoss() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = maintenancePaper("Calibration")
    let shelf = try Shelf(name: "Measurement")
    var note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [],
        markdown: "The calibration baseline is stable.")
    note.backgroundSources = .init()
    state.papers = [paper]
    state.shelves = [shelf]
    state.paperShelfIDs[paper.id.uuidString] = shelf.id
    state.readingNotes = [note]
    try await store.save(state)
    let index = ResearchBriefIndex(store: store)
    try await index.maintain()
    #expect(try await store.researchEventCounts().pending == 0)
    let firstGeneration = try await store.researchGeneration()
    let firstState = try #require(try await store.readResearchCheckpoint(.index))
    let firstWatermark = try #require(try? JSONDecoder().decode(ResearchIndexState.self, from: firstState))
    #expect(firstWatermark.lastResearchRevision == firstGeneration)

    note.markdown = "The calibration baseline is verified."
    note.modifiedAt = note.modifiedAt.addingTimeInterval(1)
    state.readingNotes = [note]
    try await store.save(state)
    try await index.maintain()
    let secondPayload = try #require(try await store.readResearchCheckpoint())
    let secondState = try #require(try await store.readResearchCheckpoint(.index))
    let secondWatermark = try #require(try? JSONDecoder().decode(ResearchIndexState.self, from: secondState))
    #expect(secondWatermark.lastResearchRevision > firstWatermark.lastResearchRevision)
    #expect(secondWatermark.lastEventSequence > firstWatermark.lastEventSequence)
    #expect(try await store.researchEventCounts().pending == 0)

    // A no-op pass must not rewrite the checkpoint or consume a later generation.
    try await index.maintain()
    #expect(try await store.readResearchCheckpoint() == secondPayload)

    // Derived data is disposable. Removing it must force an audit and rebuild from the main library.
    try withMaintenanceDatabase(root) { db in
        try #require(
            sqlite3_exec(db, "DELETE FROM research_brief; DELETE FROM research_index_state", nil, nil, nil) == SQLITE_OK
        )
    }
    let reopened = try LibraryStore(directory: root)
    let restored = try await reopened.load()
    let rebuilt = ResearchBriefIndex(store: reopened)
    try await rebuilt.maintain()
    #expect(try await reopened.readResearchCheckpoint() != nil)
    let brief = try await rebuilt.brief(
        matching: nil, limit: 4, state: restored, excluding: [], noteHits: [])
    #expect(brief.topics.contains { $0.label == "Measurement" })
    let noteHits = try await ReadingNoteMemoryIndex().search(
        query: "verified", state: restored, pending: [], excluding: nil, paperID: nil, limit: 8,
        includeArchived: false)
    let edited = try await rebuilt.brief(
        matching: "verified", limit: 4, state: restored, excluding: [], noteHits: noteHits)
    #expect(
        edited.topics.flatMap(\.sources).contains {
            $0.noteID == note.id && $0.excerpt?.contains("verified") == true
        })
    #expect(try await reopened.researchEventCounts().pending == 0)
}

@Test func eventDrivenNoteRetrievalDropsOldWordingAndRevokedNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = maintenancePaper("Measurement")
    var note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [],
        markdown: "The denominator is matched across groups.")
    var other = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [],
        markdown: "The calibration curve is separate.")
    other.modifiedAt = other.modifiedAt.addingTimeInterval(1)
    state.papers = [paper]
    state.readingNotes = [note, other]
    try await store.save(state)
    let notes = ReadingNoteMemoryIndex()
    let initial = try await notes.search(
        query: "denominator", state: state, pending: [], excluding: nil, paperID: nil, limit: 4,
        includeArchived: false)
    #expect(initial.map(\.readingNoteID) == [note.id])

    note.markdown = "The calibration curve is matched across groups."
    note.modifiedAt = note.modifiedAt.addingTimeInterval(2)
    state.readingNotes = [note, other]
    try await store.save(state)
    let oldWording = try await notes.search(
        query: "denominator", state: state, pending: [], excluding: nil, paperID: nil, limit: 4,
        includeArchived: false)
    #expect(oldWording.isEmpty)
    let newWording = try await notes.search(
        query: "calibration", state: state, pending: [], excluding: nil, paperID: nil, limit: 4,
        includeArchived: false)
    #expect(Set(newWording.compactMap(\.readingNoteID)) == [note.id, other.id])

    note.deletedAt = Date()
    state.readingNotes = [note, other]
    try await store.save(state)
    let revoked = try await notes.search(
        query: "calibration", state: state, pending: [], excluding: nil, paperID: nil, limit: 4,
        includeArchived: false)
    #expect(revoked.compactMap(\.readingNoteID) == [other.id])
}

@Test func researchLeaseIsExclusiveAndExpires() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    _ = try await store.load()
    let now = Date()
    let first = UUID()
    let second = UUID()
    #expect(try await store.acquireResearchLease(owner: first, now: now, duration: 60))
    #expect(!(try await store.acquireResearchLease(owner: second, now: now.addingTimeInterval(1), duration: 60)))
    try await store.releaseResearchLease(owner: first)
    #expect(try await store.acquireResearchLease(owner: second, now: now.addingTimeInterval(2), duration: 60))
    #expect(try await store.acquireResearchLease(owner: first, now: now.addingTimeInterval(100), duration: 60))
}

@Test func researchIndexPublishesInBoundedBatchesAndRejectsStaleGenerations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = maintenancePaper("Batch source")
    state.papers = [paper]
    try await store.save(state)
    let notes = (0..<3).map { index in
        ReadingNote(
            paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [],
            markdown: "Observation number \(index).")
    }
    state.readingNotes = notes
    try await store.save(state)
    let initial = try #require(try await store.researchMaintenanceSnapshot(pendingLimit: 2))
    #expect(initial.pendingEvents.count == 2)
    let firstPayload = Data("first batch".utf8)
    #expect(
        try await store.publishResearchIndex(
            firstPayload, previousPayload: nil, libraryRevision: initial.libraryRevision,
            researchRevision: initial.researchRevision, lastEventSequence: initial.pendingEvents[1].sequence,
            auditedAt: Date()))
    #expect(try await store.researchEventCounts().pending > 0)

    var changed = state
    changed.readingNotes[0].markdown = "A newer observation."
    changed.readingNotes[0].modifiedAt = changed.readingNotes[0].modifiedAt.addingTimeInterval(1)
    try await store.save(changed)
    #expect(
        !(try await store.publishResearchIndex(
            Data("stale".utf8), previousPayload: firstPayload, libraryRevision: initial.libraryRevision,
            researchRevision: initial.researchRevision, lastEventSequence: initial.pendingEvents[1].sequence,
            auditedAt: Date())))
    #expect(try await store.researchEventCounts().pending == 3)
    let current = try #require(try await store.researchMaintenanceSnapshot(pendingLimit: 16))
    #expect(
        try await store.publishResearchIndex(
            Data("current".utf8), previousPayload: firstPayload, libraryRevision: current.libraryRevision,
            researchRevision: current.researchRevision, lastEventSequence: current.pendingEvents.last?.sequence ?? 0,
            auditedAt: Date()))
    #expect(try await store.researchEventCounts().pending == 0)
}
