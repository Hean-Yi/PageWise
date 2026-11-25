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

@Test func staleLibraryInstanceCannotOverwriteAnInterveningCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try LibraryStore(directory: root)
    let second = try LibraryStore(directory: root)
    var a = try await first.load()
    var b = try await second.load()
    a.memories = [MemoryItem(text: "First window", sourceID: UUID())]
    b.memories = [MemoryItem(text: "Second window", sourceID: UUID())]
    try await first.save(a)
    await #expect(throws: (any Error).self) { try await second.save(b) }
    var current = try await second.load()
    #expect(current.memories == a.memories)
    current.memories += b.memories
    try await second.save(current)
    #expect(try await first.load().memories == a.memories + b.memories)
}
