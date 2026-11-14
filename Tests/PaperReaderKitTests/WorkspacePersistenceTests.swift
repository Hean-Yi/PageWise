import CSQLite
import Foundation
import Testing

@testable import PaperReaderKit

@Test func versionOneSnapshotMigratesWithoutLosingExistingRecords() throws {
    let state = try JSONDecoder().decode(LibraryState.self, from: versionOneWorkspaceFixture)
    #expect(state.version == LibraryState.currentVersion)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    let original = try #require(JSONSerialization.jsonObject(with: versionOneWorkspaceFixture) as? [String: Any])
    for key in ["papers", "highlights", "chats", "memories", "reading"] {
        let previous = try JSONSerialization.data(withJSONObject: try #require(original[key]), options: .sortedKeys)
        let migrated = try JSONSerialization.data(withJSONObject: try #require(encoded[key]), options: .sortedKeys)
        #expect(migrated == previous)
    }
    #expect(state.memories[0].userEdited)
    #expect(state.memories[1].deleted)
    #expect(state.memories[1].text.isEmpty)
    #expect(state.papers[0].noteBaseline == "user-note-baseline")
}

@Test func unknownSnapshotVersionIsRejected() throws {
    var json = try #require(JSONSerialization.jsonObject(with: versionOneWorkspaceFixture) as? [String: Any])
    json["version"] = 42
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(LibraryState.self, from: data) }
}

@Test func versionTwoWorkspacePersistsAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try JSONDecoder().decode(LibraryState.self, from: versionOneWorkspaceFixture)
    let paper = try #require(state.papers.first)
    let position = ReaderPosition(mode: "reflow", pageKey: paper.previewPages[0].id.uuidString, pageIndex: 0)
    state.workspace[paper.id.uuidString] = PaperWorkspace(
        isFavorite: true, status: .finished, lastOpenedAt: Date(timeIntervalSince1970: 9000), position: position)
    state.bookmarks = [
        PageBookmark(paperID: paper.id, pageKey: position.pageKey, pageIndex: 0, mode: position.mode)
    ]
    try await store.save(state)
    let reopened = try LibraryStore(directory: root)
    let loaded = try await reopened.load()
    #expect(loaded.version == LibraryState.currentVersion)
    #expect(loaded.workspace == state.workspace)
    #expect(loaded.bookmarks == state.bookmarks)
}

@Test func storedVersionOneUpgradesAtomicallyAndUnknownVersionKeepsItsPayload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    try writeWorkspaceFixture(versionOneWorkspaceFixture, root: root)
    let upgraded = try await store.load()
    #expect(upgraded.version == LibraryState.currentVersion)
    let stored = try readWorkspaceFixture(root: root)
    let json = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(json["version"] as? Int == LibraryState.currentVersion)
    #expect(upgraded.memories[1].deleted)

    var future = json
    future["version"] = 99
    let futureData = try JSONSerialization.data(withJSONObject: future)
    try writeWorkspaceFixture(futureData, root: root)
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try readWorkspaceFixture(root: root) == futureData)
}

private func writeWorkspaceFixture(_ data: Data, root: URL) throws {
    try withWorkspaceDatabase(root: root) { database in
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO library(id,payload) VALUES(1,?)", -1, &statement, nil)
                == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        #expect(result == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_DONE)
    }
}

private func readWorkspaceFixture(root: URL) throws -> Data {
    try withWorkspaceDatabase(root: root) { database in
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(database, "SELECT payload FROM library WHERE id=1", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let bytes = try #require(sqlite3_column_blob(statement, 0))
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}

private func withWorkspaceDatabase<T>(root: URL, body: (OpaquePointer) throws -> T) throws -> T {
    var pointer: OpaquePointer?
    #expect(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &pointer) == SQLITE_OK)
    let database = try #require(pointer)
    defer { sqlite3_close(database) }
    return try body(database)
}

private let versionOneWorkspaceFixture = Data(
    #"""
    {
      "version": 1,
      "papers": [{
        "id": "00000000-0000-0000-0000-000000000001",
        "title": "Original local fixture", "sourceURL": "https://example.invalid/paper", "digest": "fixture-hash",
        "originalPath": "Papers/fixture/original.pdf", "pageCount": 3,
        "blocks": [{"id": "00000000-0000-0000-0000-000000000002", "sourcePage": 1, "text": "Original text"}],
        "warnings": ["Fixture warning"], "canReflow": true,
        "previewPages": [{"id": "00000000-0000-0000-0000-000000000003", "blockIDs": ["00000000-0000-0000-0000-000000000002"], "sourcePage": 1, "relativePath": "preview/page.pdf"}],
        "translatedPages": [{"id": "00000000-0000-0000-0000-000000000004", "blockIDs": ["00000000-0000-0000-0000-000000000002"], "sourcePage": 1, "relativePath": "translated/page.pdf"}],
        "translations": {"00000000-0000-0000-0000-000000000002": "已完成的测试译文"}, "translatedBlockCount": 1,
        "addedAt": 1234, "summary": "Saved summary", "notePath": "Notes/paper.md", "noteBaseline": "user-note-baseline",
        "savedDiscussion": "Previously saved discussion"
      }],
      "highlights": [{"id": "00000000-0000-0000-0000-000000000005", "paperID": "00000000-0000-0000-0000-000000000001", "pageKey": "00000000-0000-0000-0000-000000000003", "pageIndex": 0, "text": "Original", "rects": [[10,20,30,40]], "createdAt": 1235}],
      "chats": [{"id": "00000000-0000-0000-0000-000000000006", "paperID": "00000000-0000-0000-0000-000000000001", "question": "Why?", "selection": "Original", "answer": "Source answer", "evidence": [{"id": "evidence-1", "title": "Source", "text": "Original text", "paperID": "00000000-0000-0000-0000-000000000001", "blockID": "00000000-0000-0000-0000-000000000002", "sourcePage": 1}], "createdAt": 1236}],
      "memories": [
        {"id": "00000000-0000-0000-0000-000000000007", "text": "User correction", "sourceID": "00000000-0000-0000-0000-000000000006", "userEdited": true, "deleted": false, "createdAt": 1237},
        {"id": "00000000-0000-0000-0000-000000000008", "text": "", "sourceID": "00000000-0000-0000-0000-000000000006", "userEdited": false, "deleted": true, "createdAt": 1238}
      ],
      "reading": [{"id": "00000000-0000-0000-0000-000000000009", "paperID": "00000000-0000-0000-0000-000000000001", "start": 1234, "end": 1294, "manual": true}]
    }
    """#.utf8)
