import Foundation
import Testing

@testable import PaperReaderKit

@Test func librarySurvivesRestart() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try LibraryStore(directory: dir)
    var state = LibraryState()
    state.memories = [MemoryItem(text: "Research direction", sourceID: UUID())]
    try await store.save(state)
    let reopened = try LibraryStore(directory: dir)
    let loaded = try await reopened.load()
    #expect(loaded.memories.first?.text == "Research direction")
}
