import Foundation
import Testing

@testable import PaperReaderKit

@Test func shelfMembershipIsSingleAndValidated() throws {
    var state = LibraryState()
    let paper = Paper(
        title: "Fixture", digest: "fixture", originalPath: "original.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    state.papers = [paper]
    let first = try Shelf(name: "  Attention  ")
    let second = try Shelf(name: "Systems")
    try state.apply(.create(first))
    try state.apply(.create(second))
    #expect(first.name == "Attention")
    try state.apply(.move(paperID: paper.id, shelfID: first.id))
    try state.apply(.move(paperID: paper.id, shelfID: second.id))
    #expect(state.paperShelfIDs.count == 1)
    #expect(state.shelfID(for: paper.id) == second.id)
    #expect(throws: (any Error).self) { try state.apply(.move(paperID: UUID(), shelfID: first.id)) }
    #expect(throws: (any Error).self) { try state.apply(.move(paperID: paper.id, shelfID: UUID())) }
    #expect(throws: (any Error).self) { try Shelf(name: " \n ") }
    #expect(throws: (any Error).self) { try Shelf(name: String(repeating: "a", count: 61)) }
    try state.apply(.delete(second.id))
    #expect(state.paperShelfIDs.isEmpty)
    #expect(state.papers[0].originalPath == paper.originalPath)
}

@Test func versionTwoMigratesAllExistingFieldsAndShelvesRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var original = LibraryState()
    let paper = Paper(
        title: "Original fixture", digest: "original", originalPath: "source.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    original.papers = [paper]
    original.workspace[paper.id.uuidString] = PaperWorkspace(isFavorite: true)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json["version"] = 2
    json.removeValue(forKey: "shelves")
    json.removeValue(forKey: "paperShelfIDs")
    var migrated = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(migrated.version == LibraryState.currentVersion)
    #expect(migrated.workspace == original.workspace)
    #expect(migrated.shelves.isEmpty)
    #expect(migrated.paperShelfIDs.isEmpty)
    let shelf = try Shelf(name: "Research")
    try migrated.apply(.create(shelf))
    try migrated.apply(.move(paperID: paper.id, shelfID: shelf.id))
    try migrated.apply(.rename(shelf.id, "Renamed"))
    let store = try LibraryStore(directory: root)
    try await store.save(migrated)
    let reopened = try await LibraryStore(directory: root).load()
    #expect(reopened.shelves[0].name == "Renamed")
    #expect(reopened.shelfID(for: paper.id) == shelf.id)
    #expect(reopened.workspace == original.workspace)
}
