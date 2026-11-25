import Foundation
import Testing

@testable import PaperReaderKit

private func briefPaper(_ title: String) -> Paper {
    Paper(
        title: title, digest: UUID().uuidString, originalPath: "unused.pdf", pageCount: 2, blocks: [], warnings: [],
        canReflow: false)
}

@Test func researchBriefReconcilesLiveSourcesAndNeverSendsNoteTextForAnUnscopedOverview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let index = ResearchBriefIndex(store: store)
    let noteIndex = ReadingNoteMemoryIndex()
    let a = briefPaper("Quartz Distillation")
    let b = briefPaper("Quartz Calibration")
    let c = briefPaper("Chronology")
    var state = LibraryState()
    state.papers = [a, b, c]
    var first = ReadingNote(
        paperID: a.id, contentVersion: "v", anchors: [], markdown: "Budget controls must match across groups.")
    first.backgroundSources = .init()
    let second = ReadingNote(
        paperID: c.id, contentVersion: "v", anchors: [], markdown: "Budget figures need a denominator.")
    var report = ChatTurn(paperID: a.id, question: "Read", selection: "", answer: "", evidence: [])
    report.closeReadingVersion = "v"
    report.closeReadingNoteIDs = [first.id]
    state.chats = [report]
    state.readingNotes = [first, second]
    try await store.save(state)
    try await index.maintain()
    let hits = try await noteIndex.search(
        query: "budget", state: state, pending: [], excluding: nil, paperID: nil, limit: 8, includeArchived: false)
    let overview = try await index.brief(matching: nil, limit: 4, state: state, excluding: [], noteHits: hits)
    let quartz = try #require(overview.topics.first { $0.label == "quartz" })
    #expect(quartz.basis == "recurring_title_terms" && quartz.paperCount == 2 && quartz.notedPapers == 1)
    #expect(overview.topics.flatMap(\.sources).allSatisfy { $0.noteID == nil && $0.excerpt == nil })
    let topical = try await index.brief(matching: "budget", limit: 1, state: state, excluding: [], noteHits: hits)
    let matched = try #require(topical.topics.first)
    #expect(
        matched.basis == "matching_note_passages" && Set(matched.sources.compactMap(\.noteID)) == [first.id, second.id])
    #expect(Set(matched.sources.compactMap(\.noteOrigin)) == ["aiCloseReading", "localNote"])
    #expect(topical.isCurrent(in: state, excluding: []))
    let bytes = try #require(try await store.readResearchCheckpoint())
    #expect(!String(decoding: bytes, as: UTF8.self).contains("denominator"))
    let titleOnly = try await index.brief(matching: "quartz", limit: 4, state: state, excluding: [], noteHits: hits)
    #expect(titleOnly.topics.flatMap(\.sources).allSatisfy { $0.excerpt == nil })
    let absent = try await index.brief(matching: "zoology", limit: 3, state: state, excluding: [], noteHits: hits)
    #expect(absent.topics.isEmpty)
    state.readingNotes[0].markdown = "This value was corrected."
    #expect(!topical.isCurrent(in: state, excluding: []))  // Even a restored note with the original timestamp.
    state.readingNotes[0].modifiedAt = first.modifiedAt.addingTimeInterval(1)
    state.readingNotes[1].deletedAt = Date()
    #expect(!topical.isCurrent(in: state, excluding: []))
    let corrected = try await index.brief(matching: "budget", limit: 4, state: state, excluding: [], noteHits: hits)
    #expect(corrected.topics.isEmpty)
    let fewer = try await index.brief(matching: "*", limit: 4, state: state, excluding: [a.id], noteHits: [])
    #expect(fewer.topics.flatMap(\.sources).allSatisfy { $0.paperID != a.id })
    #expect(!fewer.topics.contains { $0.label == "quartz" })
}

@Test func researchCheckpointRejectsStaleWriterRestoresDamagedCacheAndDropsDeletedTitleTerms() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let one = try LibraryStore(directory: root)
    var state = try await one.load()
    let a = briefPaper("Privatequartz")
    let b = briefPaper("Mistral")
    state.papers = [a, b]
    try await one.save(state)
    let oldGeneration = try #require(await one.committedResearchState()?.1)
    let maintainer = ResearchBriefIndex(store: one)
    try await maintainer.maintain()
    let before = try #require(try await one.readResearchCheckpoint())
    let writer = try LibraryStore(directory: root)
    var edited = try await writer.load()
    try edited.removePaper(a.id)
    try await writer.save(edited, deleting: a)
    let stale = try await one.publishResearchCheckpoint(before, revision: oldGeneration)
    let cleared = try await writer.readResearchCheckpoint()
    #expect(!stale && cleared == nil)
    let revision = try #require(await writer.committedResearchState()?.1)
    let poisoned = try await writer.publishResearchCheckpoint(Data("broken test cache".utf8), revision: revision)
    #expect(poisoned)
    let fresh = ResearchBriefIndex(store: writer)
    try await fresh.maintain(audit: true)
    let repaired = try #require(try await writer.readResearchCheckpoint())
    #expect(repaired != before && !String(decoding: repaired, as: UTF8.self).contains("privatequartz"))
    let reopen = try LibraryStore(directory: root)
    let restored = try await reopen.load()
    let reopened = ResearchBriefIndex(store: reopen)
    let brief = try await reopened.brief(matching: nil, limit: 3, state: restored, excluding: [], noteHits: [])
    #expect(brief.topics.flatMap(\.sources).map(\.paperID) == [b.id])
    var empty = restored
    try empty.removePaper(b.id)
    let nothing = try await reopened.brief(matching: "*", limit: 3, state: empty, excluding: [], noteHits: [])
    #expect(nothing.topics.isEmpty)
}

@Test func researchBriefWithdrawsVerifiedLegacyExcerptsWhenTheirAncestorChangesDespiteOtherLiveNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let index = ResearchBriefIndex(store: try LibraryStore(directory: root))
    let a = briefPaper("Methods")
    let b = briefPaper("Results")
    var original = ReadingNote(
        paperID: a.id, contentVersion: "v", anchors: [], markdown: "A verified original observation.")
    original.modifiedAt = .distantPast
    var legacy = ReadingNote(paperID: b.id, contentVersion: "v", anchors: [], markdown: "Cobalt was elevated.")
    legacy.citations = [LocalPassageCitation(note: original, digest: a.digest, quote: "verified original observation")]
    let survivor = ReadingNote(paperID: b.id, contentVersion: "v", anchors: [], markdown: "Separate notebook.")
    var chat = ChatTurn(paperID: b.id, question: "Read", selection: "", answer: "", evidence: [])
    chat.closeReadingVersion = "v"
    chat.closeReadingNoteIDs = [legacy.id]
    var state = LibraryState()
    state.papers = [a, b]
    state.chats = [chat]
    state.readingNotes = [original, legacy, survivor]
    let hits = try await ReadingNoteMemoryIndex().search(
        query: "cobalt", state: state, pending: [], excluding: nil, paperID: nil, limit: 8, includeArchived: false)
    let old = try await index.brief(matching: "cobalt", limit: 4, state: state, excluding: [], noteHits: hits)
    #expect(old.topics.flatMap(\.sources).contains { $0.noteID == legacy.id })
    #expect(old.isCurrent(in: state, excluding: []))
    state.readingNotes[0].markdown = "Corrected observation."
    state.readingNotes[0].modifiedAt = legacy.createdAt.addingTimeInterval(1)
    #expect(!old.isCurrent(in: state, excluding: []))
    let revised = try await index.brief(matching: "cobalt", limit: 4, state: state, excluding: [], noteHits: hits)
    #expect(revised.topics.isEmpty)
}
