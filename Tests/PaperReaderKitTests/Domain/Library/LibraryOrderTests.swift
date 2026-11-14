import Foundation
import Testing

@testable import PaperReaderKit

@Test func customOrderingSeedsSelectedSortAndPreservesHiddenPapersAndMembership() throws {
    var state = orderFixture()
    let ids = state.papers.map(\.id)
    let shelf = try Shelf(name: "Hidden shelf")
    try state.apply(.create(shelf))
    try state.apply(.move(paperID: ids[1], shelfID: shelf.id))
    try state.apply(.select(.title))
    try state.apply(.arrange(original: [ids[0], ids[2]], reordered: [ids[2], ids[0]], unfinishedFirst: true))
    #expect(state.preferredSort == .manual)
    #expect(state.manualPaperIDs == [ids[2], ids[1], ids[0], ids[3]])
    #expect(state.shelfID(for: ids[1]) == shelf.id)
    #expect(state.papers.map(\.id) == ids)
    #expect(LibraryQuery.papers(in: state, query: "A", sort: .manual).map(\.id) == [ids[0]])
    // A later import is not lost when it has no saved custom rank yet.
    let added = orderPaper("E")
    state.papers.append(added)
    #expect(LibraryQuery.papers(in: state, sort: .manual).last?.id == added.id)
}

@Test func customOrderingRejectsInvalidReferencesDuplicatesAndCompletionCrossing() throws {
    var state = orderFixture()
    let ids = state.papers.map(\.id)
    state.workspace[ids[3].uuidString] = PaperWorkspace(status: .finished)
    try state.apply(.select(.title))
    #expect(throws: (any Error).self) {
        try state.apply(.arrange(original: ids, reordered: [ids[3], ids[0], ids[1], ids[2]], unfinishedFirst: true))
    }
    #expect(throws: (any Error).self) {
        try state.apply(.arrange(original: ids, reordered: [ids[0], ids[0], ids[1], ids[2]], unfinishedFirst: false))
    }
    #expect(throws: (any Error).self) {
        try state.apply(.arrange(original: [UUID()], reordered: [UUID()], unfinishedFirst: false))
    }
    #expect(state.manualPaperIDs.isEmpty)
    #expect(state.preferredSort == .title)
    try state.apply(.arrange(original: ids, reordered: [ids[2], ids[0], ids[1], ids[3]], unfinishedFirst: true))
    state.workspace[ids[0].uuidString] = PaperWorkspace(status: .finished)
    #expect(LibraryQuery.papers(in: state, sort: .manual).map(\.id) == [ids[2], ids[1], ids[0], ids[3]])
}

@Test(arguments: [1, 2, 3]) func customOrderingExplicitlyMigratesOlderSnapshots(version: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = orderFixture()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json["version"] = version
    json.removeValue(forKey: "manualPaperIDs")
    json.removeValue(forKey: "preferredSort")
    if version < 3 {
        json.removeValue(forKey: "shelves")
        json.removeValue(forKey: "paperShelfIDs")
    }
    if version < 2 {
        json.removeValue(forKey: "workspace")
        json.removeValue(forKey: "bookmarks")
    }
    var migrated = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(migrated.version == LibraryState.currentVersion)
    #expect(migrated.manualPaperIDs.isEmpty)
    #expect(migrated.preferredSort == .recent)
    #expect(migrated.papers.map(\.id) == original.papers.map(\.id))
    let ids = LibraryQuery.papers(in: migrated).map(\.id)
    try migrated.apply(.arrange(original: ids, reordered: ids.reversed(), unfinishedFirst: true))
    let store = try LibraryStore(directory: root)
    try await store.save(migrated)
    let restored = try await LibraryStore(directory: root).load()
    #expect(restored.manualPaperIDs == migrated.manualPaperIDs)
    #expect(restored.preferredSort == .manual)
}

@Test func corruptOrderingIsRejectedOnReadAndWriteWithoutReplacingLastSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = orderFixture()
    try await store.save(state)
    state.manualPaperIDs = [state.papers[0].id, state.papers[0].id]
    await #expect(throws: (any Error).self) { try await store.save(state) }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)) }
    state.manualPaperIDs = [UUID()]
    await #expect(throws: (any Error).self) { try await store.save(state) }
    let restored = try await store.load()
    #expect(restored.manualPaperIDs.isEmpty)
    #expect(restored.papers.map(\.id) == state.papers.map(\.id))
}

private func orderFixture() -> LibraryState {
    var state = LibraryState()
    state.papers = ["A", "B", "C", "D"].map(orderPaper)
    return state
}

private func orderPaper(_ title: String) -> Paper {
    Paper(
        title: title, digest: title, originalPath: "fixture.pdf", pageCount: 2, blocks: [], warnings: [],
        canReflow: false)
}
