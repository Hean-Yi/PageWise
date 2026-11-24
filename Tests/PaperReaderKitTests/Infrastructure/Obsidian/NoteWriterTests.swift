import Foundation
import Testing

@testable import PaperReaderKit

@Test func notesPreserveUserTextAndDetectEdits() throws {
    let id = UUID()
    let first = try NoteMerger.merge(
        existing: "# My notes\n\nMy own ideas.\n", body: "Summary one", paperID: id, baseline: nil)
    let second = try NoteMerger.merge(existing: first.text, body: "Summary two", paperID: id, baseline: first.baseline)
    #expect(second.text.contains("My own ideas."))
    #expect(!second.text.contains("Summary one"))
    #expect(second.text.components(separatedBy: "Summary two").count == 2)
    #expect(throws: (any Error).self) {
        try NoteMerger.merge(
            existing: first.text.replacingOccurrences(of: "Summary one", with: "Edited by me"), body: "New",
            paperID: id, baseline: first.baseline)
    }
}

@Test func missingMarkersCannotOverwriteManagedNote() {
    #expect(throws: (any Error).self) {
        try NoteMerger.merge(existing: "User removed the block", body: "new", paperID: UUID(), baseline: "previous")
    }
}

@Test func noteRecoveryChecksFileAndPreservesDiscussion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = VaultService(root: root)
    try await service.select(folder)
    var paper = Paper(
        title: "Paper", digest: "x", originalPath: "x.pdf", pageCount: 1, blocks: [], warnings: [], canReflow: false)
    paper.savedDiscussion = "A previously saved discussion"
    let saved = try await service.save(paper: paper, body: "Generated summary")
    // Simulate an app/database failure after the external file write: the original paper still has no binding.
    let recovered = try await service.recover(paper)
    #expect(recovered.noteBaseline == saved.baseline)
    #expect(recovered.savedDiscussion == paper.savedDiscussion)
    let file = folder.appendingPathComponent(saved.path)
    let existing = try String(contentsOf: file, encoding: .utf8)
    try Data((existing + "\nMy own idea\n").utf8).write(to: file, options: .atomic)
    _ = try await service.save(paper: recovered, body: "Updated summary")
    #expect(try String(contentsOf: file, encoding: .utf8).contains("My own idea"))
    let generated = try String(contentsOf: file, encoding: .utf8)
    try Data(generated.replacingOccurrences(of: "Updated summary", with: "User-edited summary").utf8).write(
        to: file, options: .atomic)
    let stale = try await service.recover(paper)
    #expect(stale.noteBaseline == nil)
    await #expect(throws: (any Error).self) { try await service.save(paper: stale, body: "Should not overwrite") }
}

@Test func vaultUsesReadableNamesAndNeverAdoptsAnOccupiedTitle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = VaultService(root: root)
    try await service.select(folder)
    let paper = Paper(
        title: "../观察: 阅读 #证据?", digest: "fixture", originalPath: "fixture.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    let independent = folder.appendingPathComponent("观察 阅读 证据.md")
    let second = folder.appendingPathComponent("观察 阅读 证据 — \(paper.id.uuidString.prefix(8)).md")
    for occupied in [independent, second] { try Data("自己的笔记".utf8).write(to: occupied) }
    let saved = try await service.save(paper: paper, body: "一")
    #expect(saved.path == "观察 阅读 证据 — \(paper.id.uuidString.prefix(8))-2.md")
    let written = folder.appendingPathComponent(saved.path)
    var modified = try await service.recover(paper)
    modified.title = "后改的论文名"
    #expect(try await service.save(paper: modified, body: "二").path == saved.path)
    for occupied in [independent, second] { #expect(try String(contentsOf: occupied, encoding: .utf8) == "自己的笔记") }
    let externalEdit = "自己在 Obsidian 中重写了正文与标记"
    try Data(externalEdit.utf8).write(to: written, options: .atomic)
    await #expect(throws: (any Error).self) { try await service.save(paper: paper, body: "三") }
    #expect(try String(contentsOf: written, encoding: .utf8) == externalEdit)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3)
}

@Test func vaultKeepsLegacyUUIDFilenameAndRecallsTheBindingOfEachVault() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = VaultService(root: root)
    let folders = ["First", "Second"].map { root.appendingPathComponent($0) }
    let bindings = root.appendingPathComponent("NoteBindings")
    for directory in folders + [bindings] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let paper = Paper(
        title: "Reading Methods", digest: "fixture", originalPath: "fixture.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    let name = "PaperReader-\(paper.id.uuidString).md"
    let legacy = try NoteMerger.merge(existing: "", body: "旧版", paperID: paper.id, baseline: nil)
    let record = ["filename": name, "baseline": legacy.baseline, "discussion": "旧库讨论", "summary": ""]
    try JSONEncoder().encode(record).write(to: bindings.appendingPathComponent(paper.id.uuidString + ".json"))
    let firstFile = folders[0].appendingPathComponent(name)
    try Data(legacy.text.utf8).write(to: firstFile)
    try await service.select(folders[0])
    let old = try await service.recover(paper)
    #expect(old.notePath == name && old.savedDiscussion == "旧库讨论")
    #expect(try await service.save(paper: old, body: "新版").path == name)
    try await service.select(folders[1])
    let new = try await service.recover(old)
    #expect(new.notePath == nil && new.savedDiscussion.isEmpty)
    #expect(try await service.save(paper: new, body: "第二库").path == "Reading Methods.md")
    try await service.select(folders[0])
    let back = try await service.recover(new)
    #expect(back.notePath == name && back.savedDiscussion == "旧库讨论")
    #expect(try await service.save(paper: back, body: "同一份").path == name)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folders[0].path) == [name])
    await #expect(throws: (any Error).self) {
        try await service.saveReadingDocument(paper: back, body: "错误目标", root: root, destination: folders[1])
    }
    #expect(try String(contentsOf: firstFile, encoding: .utf8).contains("同一份"))
}

@Test func vaultRejectsBodyContainingThePapersOwnManagementMarkers() throws {
    let id = UUID()
    #expect(throws: (any Error).self) {
        try NoteMerger.merge(
            existing: "", body: "<!-- paperreader:\(id.uuidString):begin -->", paperID: id, baseline: nil)
    }
}

@Test func sameFilenameInAnotherVaultCannotAuthorizeOverwritingAnExternalEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    defer { try? FileManager.default.removeItem(at: root) }
    for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let service = VaultService(root: root)
    var paper = Paper(
        title: "Shared", digest: "fixture", originalPath: "test.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    try await service.select(a)
    _ = try await service.save(paper: paper, body: "A")
    try await service.select(b)
    paper = try await service.recover(paper)
    paper.savedDiscussion = "Discussion approved only for B"
    let result = try await service.save(paper: paper, body: "B")
    let boundToB = try await service.recover(paper)
    let external = try Data(contentsOf: b.appendingPathComponent(result.path))
    let fileA = a.appendingPathComponent(result.path)
    try external.write(to: fileA, options: .atomic)
    try await service.select(a)
    let recovered = try await service.recover(boundToB)
    #expect(recovered.savedDiscussion.isEmpty && recovered.noteBaseline == nil)
    await #expect(throws: (any Error).self) { try await service.save(paper: boundToB, body: "Overwritten") }
    #expect(try Data(contentsOf: fileA) == external)
}

@Test func unwrittenVaultJournalRetriesCreationAndRefusesAnInterveningPersonalFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Vault")
    let bindings = root.appendingPathComponent("NoteBindings")
    defer { try? FileManager.default.removeItem(at: root) }
    for dir in [bindings, folder] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let service = VaultService(root: root)
    try await service.select(folder)
    var paper = Paper(
        title: "Retry", digest: "fixture", originalPath: "test.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    paper.notePath = "Retry.md"
    paper.noteBaseline = "prior-vault-baseline"
    paper.savedDiscussion = "Discussion from another vault"
    let name = "Retry.md"
    let vaultID = NoteMerger.hash(try await service.directory().standardizedFileURL.path)
    let record: [String: Any] = [
        "filename": name, "baseline": "unwritten-baseline", "discussion": "unwritten discussion",
        "summary": "", "vaultID": vaultID, "pending": true,
    ]
    try JSONSerialization.data(withJSONObject: [record]).write(
        to: bindings.appendingPathComponent(paper.id.uuidString + ".json"))
    let recovered = try await service.recover(paper)
    #expect(recovered.savedDiscussion.isEmpty && recovered.noteBaseline == nil)
    let destination = folder.appendingPathComponent(name)
    try Data("Personal content".utf8).write(to: destination)
    await #expect(throws: (any Error).self) { try await service.save(paper: recovered, body: "Retry") }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "Personal content")
    try FileManager.default.removeItem(at: destination)
    #expect(try await service.save(paper: recovered, body: "Retry").path == name)
    #expect(try await service.recover(paper).savedDiscussion.isEmpty)
}

@Test func interruptedUpdateRecoversTheVersionStillOnDiskAndRetiresItAfterRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = VaultService(root: root)
    try await service.select(folder)
    var paper = Paper(
        title: "Retried", digest: "fixture", originalPath: "test.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    paper.savedDiscussion = "Previously published discussion"
    let first = try await service.save(paper: paper, body: "First")
    let destination = folder.appendingPathComponent(first.path)
    let oldBytes = try Data(contentsOf: destination)
    let journal = root.appendingPathComponent("NoteBindings/\(paper.id.uuidString).json")
    let records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
    var pending = try #require(records.first)
    pending["baseline"] = "planned-update"
    pending["discussion"] = "Unwritten replacement"
    pending["pending"] = true
    try JSONSerialization.data(withJSONObject: [pending] + records).write(to: journal, options: .atomic)
    paper.savedDiscussion = "Discussion from another vault"
    let recovered = try await service.recover(paper)
    #expect(recovered.noteBaseline == first.baseline && recovered.savedDiscussion == "Previously published discussion")
    _ = try await service.save(paper: recovered, body: "Second")
    try oldBytes.write(to: destination, options: .atomic)
    await #expect(throws: (any Error).self) { try await service.save(paper: recovered, body: "Third") }
    #expect(try Data(contentsOf: destination) == oldBytes)
}
