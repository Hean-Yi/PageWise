import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@Test @MainActor func translationCreatesOnePaperGroundedObservationMemory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    var paper = Paper(
        title: "Observed Paper", digest: "observed", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    paper.summary = "A local abstract about matched compute."
    reader.state.papers = [paper]
    await reader.ensurePaperMemory(paperID: paper.id)
    let memory = try #require(reader.state.memories.first)
    #expect(memory.librarySource == .paper(paperID: paper.id))
    #expect(memory.text.contains(MemoryItem.paperObservationPrefix))
    #expect(memory.text.contains("matched compute"))
    let count = reader.state.memories.count
    await reader.ensurePaperMemory(paperID: paper.id)
    #expect(reader.state.memories.count == count)
    reader.deleteMemory(memory.id)
    await reader.ensurePaperMemory(paperID: paper.id)
    #expect(reader.state.memories.count == count)
}

@Test @MainActor func noteReviewReportAppliesASilentRevisionAndPreservesHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    var note = ReadingNote(
        paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Reader original.")
    reader.state.readingNotes = [note]
    let report = NoteReviewReport(
        revisions: [
            .init(
                noteID: note.id, modifiedAt: note.modifiedAt,
                markdown: "Reader original. Cross-paper relation noted.")
        ])
    let changed = try await reader.applyNoteReview(report)
    #expect(changed == 1)
    note = try #require(reader.state.readingNotes.first)
    #expect(note.markdown.contains("Cross-paper relation"))
    #expect(note.revisions?.first?.markdown == "Reader original.")
    #expect(try await LibraryStore(directory: root).load().readingNotes.first?.markdown == note.markdown)
}

@MainActor @Test func noteReviewOnlyAllowsSmallAppendOrLocalEdit() {
    let original = "匹配计算预算后，方法 A 的准确率更高。"
    #expect(ReaderModel.isSmallNoteRevision(from: original, to: original + " 该结论只在验证集上成立。"))
    #expect(ReaderModel.isSmallNoteRevision(from: original, to: "匹配计算预算后，方法 A 的准确率更高（验证集）。"))
    #expect(!ReaderModel.isSmallNoteRevision(from: original, to: "这是一段完全重写的笔记，讨论另一组实验、另一个数据集和完全不同的结论。"))
}

@Test @MainActor func explicitMemoryCommandsUseTheLocalFastPath() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let source = UUID()
    reader.state.memories = [MemoryItem(text: "旧的吞吐量比较记录", sourceID: source)]
    #expect(reader.respondToMemoryCommand("请忘掉旧的吞吐量比较记录。") != nil)
    #expect(reader.state.memories.first?.deleted == true)

    reader.state.memories = [MemoryItem(text: "旧的吞吐量比较记录", sourceID: source)]
    #expect(reader.respondToMemoryCommand("把旧的吞吐量比较记录改为只比较训练时长。") != nil)
    #expect(reader.state.memories.first?.text == "只比较训练时长")
}

@Test @MainActor func noteRevisionRemembersItsRelationSourcesAndInvalidatesOnChange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let paperID = UUID()
    let paper = Paper(
        id: paperID, title: "Relation source", digest: "relation", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    reader.state.papers = [paper]
    var target = ReadingNote(
        paperID: paperID, contentVersion: "v", anchors: [], markdown: "Reader original.")
    var source = ReadingNote(
        paperID: paperID, contentVersion: "v", anchors: [], markdown: "New evidence about matching compute.")
    reader.state.readingNotes = [target, source]
    let context = NoteReviewInput.Target(
        noteID: target.id, title: "Paper", modifiedAt: target.modifiedAt, markdown: target.markdown,
        relations: [
            .init(
                noteID: source.id, title: "Paper", modifiedAt: source.modifiedAt, kind: "similar", overlap: 2,
                excerpt: "New evidence")
        ])
    let report = NoteReviewReport(
        revisions: [
            .init(noteID: target.id, modifiedAt: target.modifiedAt, markdown: "Reader original. New evidence noted.")
        ])
    #expect(try await reader.applyNoteReview(report, contexts: [context]) == 1)
    target = try #require(reader.state.readingNotes.first { $0.id == target.id })
    #expect(ChatSourceVersions.recalledNote(target, in: reader.state, excluding: []) != nil)

    source.modifiedAt = source.modifiedAt.addingTimeInterval(1)
    reader.state.readingNotes[1] = source
    #expect(ChatSourceVersions.recalledNote(target, in: reader.state, excluding: []) == nil)
}

@Test func noteRelationCacheIsKeyedByTheSourceRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let paper = Paper(
        id: UUID(), title: "Relations", digest: "relations", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    let a = ReadingNote(paperID: paper.id, contentVersion: "v", anchors: [], markdown: "Matched compute.")
    let b = ReadingNote(paperID: paper.id, contentVersion: "v", anchors: [], markdown: "Matched compute budget.")
    state.papers = [paper]
    state.readingNotes = [a, b]
    try await store.save(state)
    let relation = NoteRelation(
        sourceID: a.id, targetID: b.id, kind: .similar, overlap: 2, targetModifiedAt: b.modifiedAt)
    try await store.saveNoteRelations([relation], sourceID: a.id, sourceModifiedAt: a.modifiedAt)
    #expect(try await store.noteRelations(sourceID: a.id, sourceModifiedAt: a.modifiedAt) == [relation])
    #expect(
        try await store.noteRelations(
            sourceID: a.id, sourceModifiedAt: a.modifiedAt.addingTimeInterval(1)) == nil)
}

@Test @MainActor func localMemoryCommandsLeaveAnInternalAudit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    reader.state.memories = [MemoryItem(text: "旧的吞吐量比较记录", sourceID: UUID())]
    #expect(reader.respondToMemoryCommand("请忘掉旧的吞吐量比较记录。") != nil)
    for _ in 0..<100 where (try? await reader.store.memoryAuditCount()) != 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await reader.store.memoryAuditCount() == 1)
}

@Test func bundledQuantizedSemanticModelIsPackaged() async {
    #expect(await DeviceSemanticEncoder.shared.isInstalled())
}

@Test @MainActor func explicitRememberCommandAvoidsAModelRound() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    reader.state.memories = []
    let response = reader.respondToRememberCommand("请记住我只关注匹配预算的比较。")
    #expect(response != nil)
    #expect(reader.state.memories.count == 1)
    #expect(reader.state.memories.first?.text.contains("匹配预算") == true)
    for _ in 0..<100 where (try? await reader.store.memoryAuditCount()) != 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await reader.store.memoryAuditCount() == 1)
}

private final class NoteReviewProbe {
    var count = 0
}

@Test @MainActor func readerTickSchedulesNoteReviewOnlyWhenEnabledAndIdle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    var settings = reader.modelSettings
    settings.baseURL = ModelServicePreset.deepSeek.baseURL
    settings.model = ModelServicePreset.deepSeek.defaultModel
    try reader.saveSettings(settings, key: "fixture-only")
    let paper = Paper(
        title: "Scheduled review", digest: "review", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    let note = ReadingNote(paperID: paper.id, contentVersion: "v", anchors: [], markdown: "Reader note.")
    reader.state.papers = [paper]
    reader.state.readingNotes = [note]
    #expect(await reader.save())
    reader.lastInteraction = Date().addingTimeInterval(-200)
    let probe = NoteReviewProbe()
    reader.noteReview.isLowPowerModeEnabled = { false }
    reader.noteReview.reviewOverride = { _, _ in
        probe.count += 1
        return #"{"revisions":[]}"#
    }

    reader.noteReview.enabled = false
    reader.tick()
    try await Task.sleep(for: .milliseconds(80))
    #expect(probe.count == 0)

    reader.noteReview.enabled = true
    reader.tick()
    for _ in 0..<300 where probe.count == 0 || reader.noteReview.running {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.count == 1)
    #expect(!reader.noteReview.running)

    // A completed pass schedules the next check; a plain tick must not start another model round.
    reader.tick()
    try await Task.sleep(for: .milliseconds(80))
    #expect(probe.count == 1)
}

@Test @MainActor func memoryMutationPersistsBeforeChangingLiveStateAndRejectsUserAuthoredTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let item = MemoryItem(text: "旧记录", sourceID: UUID())
    reader.state.memories = [item]
    #expect(await reader.save())

    let revise = MemoryRecordMutation(
        operation: .revise(id: item.id, statement: "新记录"), auditTrigger: "更正记忆")
    #expect(await reader.save(cancellable: true, memoryMutation: revise))
    #expect(reader.state.memories.first?.text == "新记录")
    #expect(try await LibraryStore(directory: root).load().memories.first?.text == "新记录")

    var edited = try #require(reader.state.memories.first)
    let corrected = edited.correct(to: "读者自己改的记录")
    #expect(corrected)
    reader.state.memories = [edited]
    #expect(await reader.save())
    let rejected = MemoryRecordMutation(operation: .forget(id: edited.id), auditTrigger: "删除记忆")
    #expect(!(await reader.save(cancellable: true, memoryMutation: rejected)))
    #expect(reader.state.memories.first?.text == "读者自己改的记录")
    #expect(try await LibraryStore(directory: root).load().memories.first?.text == "读者自己改的记录")
}
