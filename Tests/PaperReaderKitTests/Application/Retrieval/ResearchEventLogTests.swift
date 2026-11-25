import CSQLite
import Foundation
import Testing

@testable import PaperReaderKit

private func eventPaper(_ title: String) -> Paper {
    Paper(
        title: title, digest: UUID().uuidString, originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
}

@Test func researchEventsCaptureSourceChangesAndIgnoreWorkspaceOrTranslationSaves() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()

    let paper = eventPaper("Quartz Measurement")
    let shelf = try Shelf(name: "Measurement")
    state.papers = [paper]
    state.shelves = [shelf]
    state.paperShelfIDs[paper.id.uuidString] = shelf.id
    #expect(try await store.save(state).researchSourcesChanged)
    #expect(try await store.researchGeneration() == 1)
    var events = try await store.pendingResearchEvents()
    #expect(events.contains { $0.event.kind == .paperImported && $0.event.recordID == paper.id })
    #expect(events.contains { $0.event.kind == .shelfChanged && $0.event.recordID == shelf.id })
    #expect(events.contains { $0.event.kind == .paperShelfChanged && $0.event.recordID == paper.id })

    let counts = try await store.researchEventCounts()
    state.workspace[paper.id.uuidString] = PaperWorkspace()
    state.papers[0].translations["fixture"] = "译文"
    #expect(!(try await store.save(state).researchSourcesChanged))
    #expect(try await store.researchEventCounts() == counts)
    #expect(try await store.researchGeneration() == 1)

    var note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [],
        markdown: "The denominator is the same in both groups.")
    state.readingNotes = [note]
    #expect(try await store.save(state).researchSourcesChanged)
    events = try await store.pendingResearchEvents()
    #expect(events.contains { $0.event.kind == .noteChanged && $0.event.recordID == note.id })

    let firstNoteRevision = try #require(
        events.first { $0.event.kind == .noteChanged && $0.event.recordID == note.id }?.event.recordRevision)
    note.markdown = "The denominator is verified in both groups."
    note.modifiedAt = note.modifiedAt.addingTimeInterval(1)
    state.readingNotes = [note]
    #expect(try await store.save(state).researchSourcesChanged)
    events = try await store.pendingResearchEvents()
    #expect(
        events.contains {
            $0.event.kind == .noteChanged && $0.event.recordID == note.id
                && $0.event.recordRevision != firstNoteRevision
        })

    let chat = ChatTurn(
        paperID: paper.id, question: "Which denominator should I check?", selection: "",
        answer: "The held-out set.", evidence: [])
    state.chats = [chat]
    #expect(try await store.save(state).researchSourcesChanged)
    events = try await store.pendingResearchEvents()
    #expect(events.contains { $0.event.kind == .discussionChanged && $0.event.recordID == chat.id })

    var memory = MemoryItem(text: "Compare equal compute budgets.", sourceID: chat.id)
    state.memories = [memory]
    #expect(try await store.save(state).researchSourcesChanged)
    events = try await store.pendingResearchEvents()
    #expect(events.contains { $0.event.kind == .memoryChanged && $0.event.recordID == memory.id })

    memory.forget()
    state.memories = [memory]
    #expect(try await store.save(state).researchSourcesChanged)
    events = try await store.pendingResearchEvents()
    #expect(events.contains { $0.event.kind == .memoryRemoved && $0.event.recordID == memory.id })

    note.deletedAt = Date()
    state.readingNotes = [note]
    #expect(try await store.save(state).researchSourcesChanged)
    events = try await store.pendingResearchEvents()
    #expect(events.contains { $0.event.kind == .noteRemoved && $0.event.recordID == note.id })

    let reopened = try LibraryStore(directory: root)
    _ = try await reopened.load()
    #expect(try await reopened.pendingResearchEvents() == events)
}

@Test func removingAPaperEmitsRemovalEventsForItsDependentSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = eventPaper("Removed source")
    let chat = ChatTurn(
        paperID: paper.id, question: "What changed?", selection: "", answer: "A result.", evidence: [])
    let note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [],
        markdown: "A dependent observation.")
    let memory = MemoryItem(text: "Remember the comparison.", sourceID: chat.id)
    state.papers = [paper]
    state.chats = [chat]
    state.readingNotes = [note]
    state.memories = [memory]
    try await store.save(state)

    var removed = state
    let deleted = try removed.removePaper(paper.id)
    try await store.save(removed, deleting: deleted)
    let events = try await store.pendingResearchEvents()
    #expect(events.contains { $0.event.kind == .paperRemoved && $0.event.recordID == paper.id })
    #expect(events.contains { $0.event.kind == .noteRemoved && $0.event.recordID == note.id })
    #expect(events.contains { $0.event.kind == .discussionRemoved && $0.event.recordID == chat.id })
    #expect(events.contains { $0.event.kind == .memoryRemoved && $0.event.recordID == memory.id })
    #expect(try await store.researchEventCounts().pending == events.count)
}

@Test func researchEventSchemaMigratesFromVersionTwoWithoutLosingTheLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = eventPaper("Migrated source")
    state.papers = [paper]
    state.memories = [MemoryItem(text: "Preserve this source.", sourceID: UUID())]
    try await store.save(state)
    let revision = try #require(await store.committedResearchState()?.1)
    try withEventDatabase(root) { db in
        try #require(
            sqlite3_exec(
                db,
                """
                DROP TABLE research_events;
                DROP TABLE research_index_state;
                DROP TABLE research_maintenance_lease;
                DROP TABLE research_generation;
                PRAGMA user_version=2;
                """, nil, nil, nil) == SQLITE_OK)
    }
    let reopened = try LibraryStore(directory: root)
    let restored = try await reopened.load()
    #expect(restored.papers == state.papers && restored.memories == state.memories)
    #expect(await reopened.committedResearchState()?.1 == revision)
    #expect(try await reopened.researchGeneration() == 0)
    #expect(try await reopened.researchEventCounts() == (0, 0))
    var changed = restored
    changed.memories.append(MemoryItem(text: "A later source.", sourceID: UUID()))
    try await reopened.save(changed)
    #expect(try await reopened.researchGeneration() == 1)
    #expect(try await reopened.researchEventCounts().pending == 1)
}

@Test func returningToAnEarlierRevisionAdvancesTheSourceGenerationWithoutDuplicatingTheEventKey() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = eventPaper("Stable source")
    state.papers = [paper]
    try await store.save(state)
    var note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [], markdown: "Original wording.")
    let original = note
    state.readingNotes = [note]
    try await store.save(state)
    let firstGeneration = try await store.researchGeneration()
    let firstCount = try await store.researchEventCounts()

    note.markdown = "Intermediate wording."
    note.modifiedAt = note.modifiedAt.addingTimeInterval(1)
    state.readingNotes = [note]
    try await store.save(state)
    let secondGeneration = try await store.researchGeneration()
    #expect(secondGeneration > firstGeneration)

    state.readingNotes = [original]
    try await store.save(state)
    #expect(try await store.researchGeneration() > secondGeneration)
    // The repeated revision is deduplicated, but the generation still forces the derived index
    // to reconcile instead of remaining stuck on the intermediate wording.
    #expect(try await store.researchEventCounts().total == firstCount.total + 1)
}

@Test func researchEventInsertFailureRollsBackTheWholeLibraryCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = eventPaper("Atomic source")
    state.papers = [paper]
    try await store.save(state)
    let revision = try #require(await store.committedResearchState()?.1)
    let count = try await store.researchEventCounts()

    try withEventDatabase(root) { db in
        try #require(
            sqlite3_exec(
                db,
                """
                CREATE TRIGGER fail_research_event BEFORE INSERT ON research_events
                BEGIN SELECT RAISE(ABORT,'injected event failure'); END
                """, nil, nil, nil) == SQLITE_OK)
    }
    var note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: [], markdown: "Must roll back.")
    state.readingNotes = [note]
    await #expect(throws: (any Error).self) { try await store.save(state) }
    #expect(await store.committedResearchState()?.1 == revision)
    #expect(try await store.researchEventCounts() == count)
    let reopened = try LibraryStore(directory: root)
    let restored = try await reopened.load()
    #expect(restored.readingNotes.isEmpty)

    note.markdown = "Retry succeeds."
    state.readingNotes = [note]
    try withEventDatabase(root) { db in
        try #require(sqlite3_exec(db, "DROP TRIGGER fail_research_event", nil, nil, nil) == SQLITE_OK)
    }
    #expect(try await store.save(state).researchSourcesChanged)
    #expect(try await reopened.load().readingNotes == [note])
}

private func withEventDatabase(_ root: URL, _ body: (OpaquePointer) throws -> Void) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &db, 2, nil) == SQLITE_OK, let db else {
        throw ReaderError.message("无法打开测试书库。")
    }
    defer { sqlite3_close(db) }
    try body(db)
}
