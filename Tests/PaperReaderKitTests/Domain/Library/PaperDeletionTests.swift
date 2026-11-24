import Foundation
import Testing

@testable import PaperReaderKit

@Test func permanentDeletionMigrationRecoversVersionElevenArchivesAndWritesNoArchiveField() throws {
    let paper = Paper(
        title: "A", digest: "digest", originalPath: "paper.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    let turn = ChatTurn(paperID: paper.id, question: "Question", selection: "", answer: "Answer", evidence: [])
    let note = ReadingNote(paperID: paper.id, contentVersion: "v", anchors: [], markdown: "protected text")
    let encode = JSONEncoder()
    var legacy = try #require(JSONSerialization.jsonObject(with: encode.encode(LibraryState())) as? [String: Any])
    legacy["version"] = 11
    legacy["trashedPapers"] = [
        [
            "paper": try JSONSerialization.jsonObject(with: encode.encode(paper)), "position": ["index": 0],
            "manualPosition": ["index": 0],
            "readingNotes": try JSONSerialization.jsonObject(with: encode.encode([note])),
            "chats": try JSONSerialization.jsonObject(with: encode.encode([turn])),
            "memories": [], "reading": [], "bookmarks": [], "highlights": [],
        ]
    ]
    let migrated = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(migrated.papers.map(\.id) == [paper.id] && migrated.manualPaperIDs == [paper.id])
    #expect(migrated.chats.map(\.id) == [turn.id] && migrated.readingNotes == [note])
    let current = try #require(JSONSerialization.jsonObject(with: encode.encode(migrated)) as? [String: Any])
    #expect(current["trashedPapers"] == nil && migrated.version == 12)
    legacy["version"] = 10
    legacy["trashedPapers"] = nil
    let v10 = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(v10.papers.isEmpty && v10.version == 12)
}

@Test func permanentDeletionRecoveryUnlinksOnlyCommittedManagedFilesAndProtectsExternalSymlinks() async throws {
    let fs = FileManager.default
    let root = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fs.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let paper = Paper(
        title: "Keep until committed", digest: "hash", originalPath: "/etc/irrelevant", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    let folder = root.appending(path: "Papers/" + paper.id.uuidString)
    try fs.createDirectory(at: folder, withIntermediateDirectories: true)
    let external = root.appending(path: "outside")
    try fs.createDirectory(at: external, withIntermediateDirectories: true)
    let canary = external.appending(path: "kept")
    try Data("keep".utf8).write(to: canary)
    var state = LibraryState()
    state.papers = [paper]
    try await store.save(state)
    try await store.stageFileRemoval(paper)
    try await store.recoverFileRemovals(keeping: state.papers)
    #expect(fs.fileExists(atPath: folder.path))
    try fs.createSymbolicLink(at: folder.appending(path: "out"), withDestinationURL: external)
    try state.removePaper(paper.id)
    try await store.save(state, deleting: paper)
    let reopened = try LibraryStore(directory: root)
    try await reopened.recoverFileRemovals(keeping: reopened.load().papers)
    #expect(!fs.fileExists(atPath: folder.path) && fs.fileExists(atPath: canary.path))

    let papersFolder = root.appending(path: "Papers")
    try fs.removeItem(at: papersFolder)
    try fs.createSymbolicLink(at: papersFolder, withDestinationURL: external)
    try fs.createDirectory(at: external.appending(path: paper.id.uuidString), withIntermediateDirectories: true)
    try await store.stageFileRemoval(paper)
    await #expect(throws: ReaderError.self) { try await store.recoverFileRemovals(keeping: []) }
    #expect(fs.fileExists(atPath: external.appending(path: paper.id.uuidString).path))
}
