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
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
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
    let supersededOld = try #require(reader.state.memories.first { $0.id == item.id })
    let revisedActive = try #require(reader.state.memories.first { $0.isActive })
    #expect(!supersededOld.isActive)
    #expect(supersededOld.invalidAt != nil)
    #expect(supersededOld.supersededBy == revisedActive.id)
    #expect(!revisedActive.userEdited)
    #expect(revisedActive.text == MemoryItem.automaticPrefix + "新记录")
    let reloaded = try await LibraryStore(directory: root).load()
    #expect(reloaded.memories.first { $0.isActive }?.text == MemoryItem.automaticPrefix + "新记录")

    var edited = revisedActive
    let corrected = edited.correct(to: "读者自己改的记录")
    #expect(corrected)
    reader.state.memories = [edited]
    #expect(await reader.save())
    let rejected = MemoryRecordMutation(operation: .forget(id: edited.id), auditTrigger: "删除记忆")
    #expect(!(await reader.save(cancellable: true, memoryMutation: rejected)))
    #expect(reader.state.memories.first?.text == "读者自己改的记录")
    #expect(try await LibraryStore(directory: root).load().memories.first?.text == "读者自己改的记录")
}

@Test func noteReviewCursorDoesNotSkipTheTailBeyondOnePage() {
    let base = Date(timeIntervalSinceReferenceDate: 1_000)
    let notes = (0..<10).map { offset in
        var note = ReadingNote(
            paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Note \(offset).")
        note.modifiedAt = base.addingTimeInterval(Double(offset))
        note.createdAt = note.modifiedAt
        return note
    }
    var cursor = NoteReviewCursor(date: base.addingTimeInterval(-1))
    let pending = notes.filter { cursor.needsReview($0, at: NoteReviewCursor.stamp($0)) }
    #expect(pending.count == 10)
    let firstPage = Array(pending.prefix(8))
    let targets = firstPage.map {
        NoteReviewInput.Target(
            noteID: $0.id, title: "Paper", modifiedAt: $0.modifiedAt, markdown: $0.markdown, relations: [])
    }
    cursor = NoteReviewCursor.advanced(
        cursor, processed: targets, startedAt: base.addingTimeInterval(100), hasMore: true)
    #expect(cursor.date == firstPage.last?.modifiedAt)
    let remaining = notes.filter { cursor.needsReview($0, at: NoteReviewCursor.stamp($0)) }
    #expect(remaining.map(\.id) == [notes[8].id, notes[9].id])
}

@Test func noteReviewCursorDisambiguatesEqualTimestamps() {
    let base = Date(timeIntervalSinceReferenceDate: 2_000)
    let notes = (0..<3).map { _ in
        var note = ReadingNote(paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Same instant.")
        note.modifiedAt = base
        note.createdAt = base
        return note
    }
    var cursor = NoteReviewCursor(date: base.addingTimeInterval(-1))
    let firstPage = Array(notes.prefix(2))
    let targets = firstPage.map {
        NoteReviewInput.Target(
            noteID: $0.id, title: "Paper", modifiedAt: $0.modifiedAt, markdown: $0.markdown, relations: [])
    }
    cursor = NoteReviewCursor.advanced(
        cursor, processed: targets, startedAt: base.addingTimeInterval(100), hasMore: true)
    let remaining = notes.filter { cursor.needsReview($0, at: NoteReviewCursor.stamp($0)) }
    #expect(remaining.map(\.id) == [notes[2].id])
}

@Test func noteReviewCursorMovesToRunStartAfterACompletePass() {
    let base = Date(timeIntervalSinceReferenceDate: 3_000)
    let startedAt = base.addingTimeInterval(50)
    var note = ReadingNote(paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Only note.")
    note.modifiedAt = base
    note.createdAt = base
    let target = NoteReviewInput.Target(
        noteID: note.id, title: "Paper", modifiedAt: note.modifiedAt, markdown: note.markdown, relations: [])
    let cursor = NoteReviewCursor.advanced(
        NoteReviewCursor(date: base.addingTimeInterval(-1)), processed: [target], startedAt: startedAt,
        hasMore: false)
    #expect(cursor.date == startedAt)
    #expect(!cursor.needsReview(note, at: NoteReviewCursor.stamp(note)))
    var editedLater = note
    editedLater.modifiedAt = startedAt.addingTimeInterval(1)
    #expect(cursor.needsReview(editedLater, at: NoteReviewCursor.stamp(editedLater)))
}

@Test @MainActor func noteRevisionUsesARealDiffInsteadOfMatchingPrefixes() {
    let original = "方法 A 在验证集上取得了更好的结果，并且训练预算保持一致。"
    let localEdit = "方法 B 在验证集上取得了更好的结果，并且训练预算保持一致。仅在验证集。"
    #expect(ReaderModel.isSmallNoteRevision(from: original, to: localEdit))
}

@Test @MainActor func noteRelationsDoNotTreatDifferentNumbersAsConflicts() {
    #expect(
        NoteReviewSession.relationKind(
            "Table 2 reports 32.1% accuracy for the baseline.",
            "Table 3 reports 41.7% accuracy for the same baseline.") == .similar)
    #expect(
        NoteReviewSession.relationKind(
            "The method improves accuracy on the held-out split.",
            "The method does not improve accuracy on the held-out split.") == .conflict)
    #expect(
        NoteReviewSession.relationKind(
            "The method improves accuracy on CIFAR. We did not tune batch size.",
            "The method improves accuracy on CIFAR under matched compute.") == .similar)
    #expect(
        NoteReviewSession.relationKind(
            "该方法在等算力下提升显著，原文未提供源码。",
            "该方法在等算力下提升显著。") == .similar)
}

private struct DeterministicSemanticEncoder: SemanticTextEncoder {
    let identifier = "fixture-deterministic-e5"

    func encode(_ texts: [String], as role: SemanticTextRole) async throws -> [[Float]] {
        texts.map { text in
            let lower = text.lowercased()
            let budget: Float = (lower.contains("budget") || lower.contains("预算") || lower.contains("算力")) ? 1 : 0
            let latency: Float = (lower.contains("latency") || lower.contains("延迟")) ? 1 : 0
            return [budget + 0.1, latency + 0.1, 0.05]
        }
    }
}

@Test @MainActor func noteReviewUsesStableCorpusWithoutCancellingSemanticWarmup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.baseURL = ModelServicePreset.openAI.baseURL
    settings.model = "gpt-5-mini"
    try reader.saveSettings(settings, key: "test-only")
    let paper = Paper(
        title: "Batch Relations", digest: "batch-rel", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    let base = Date(timeIntervalSinceReferenceDate: 5_000)
    let notes = (0..<12).map { index -> ReadingNote in
        let body =
            index.isMultiple(of: 2)
            ? "Matched compute budget experiment \(index)."
            : "等算力预算实验记录 \(index)。"
        var note = ReadingNote(paperID: paper.id, contentVersion: "v", anchors: [], markdown: body)
        note.createdAt = base.addingTimeInterval(Double(index))
        note.modifiedAt = note.createdAt
        return note
    }
    reader.state.papers = [paper]
    reader.state.readingNotes = notes
    #expect(await reader.save())

    let session = NoteReviewSession(
        store: reader.store, root: root, encoder: DeterministicSemanticEncoder(), minimumScore: 0.5)
    var capturedTargets: [NoteReviewInput.Target] = []
    session.reviewOverride = { _, input in
        capturedTargets = input.targets
        return #"{"revisions":[]}"#
    }
    session.run(reader: reader, automatic: false, withModel: true)
    for _ in 0..<200 where session.running {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(capturedTargets.count == 8)
    #expect(capturedTargets.allSatisfy { !$0.relations.isEmpty })
    #expect(await session.semantic.warmupCancellationCount() == 0)
}

@Test @MainActor func recallTelemetryPersistsWithoutDisturbingResearchGenerationAndSleepSupersedesMainRecords()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let base = Date(timeIntervalSinceReferenceDate: 10_000)
    var old = MemoryItem(agentStatement: "旧计划比较十组吞吐量", sourceID: UUID(), source: .reader(quote: "旧计划比较十组吞吐量"))
    old.createdAt = base
    var newer = MemoryItem(agentStatement: "改为比较两组等算力准确率", sourceID: UUID(), source: .reader(quote: "改为比较两组等算力准确率"))
    newer.createdAt = base.addingTimeInterval(60)
    #expect(old.validFrom != nil)
    reader.state.memories = [old, newer]
    #expect(await reader.save())

    let generationBefore = try await reader.store.researchGeneration()
    reader.recordMemoryRecall([old.id], at: base.addingTimeInterval(120))
    for _ in 0..<100 where (try? await reader.store.load().memories.first { $0.id == old.id }?.recallCount) != 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    let recalled = try #require(try await reader.store.load().memories.first { $0.id == old.id })
    #expect(recalled.recallCount == 1)
    #expect(recalled.lastRecalledAt == base.addingTimeInterval(120))
    #expect(try await reader.store.researchGeneration() == generationBefore)

    // Materialize a consolidated sleep supersedence onto the main MemoryItem record.
    let oldID = old.id
    let newerID = newer.id
    let sleepStore = MemorySleepStore(store: reader.store)
    let edition = try await sleepStore.run { _ in
        #"{"groups":[{"kind":"superseded","members":["\#(oldID)","\#(newerID)"],"current":"\#(newerID)","summary":"采用新的两组等算力方案。"}]}"#
    }
    await reader.applySleepSupersedence(edition, at: base.addingTimeInterval(300))
    let updatedOld = try #require(reader.state.memories.first { $0.id == old.id })
    #expect(!updatedOld.isActive)
    #expect(updatedOld.supersededBy == newer.id)
    #expect(updatedOld.invalidAt != nil)
    let activeDirect = try await reader.researchMemory.relevant(to: "比较", state: reader.state)
    #expect(activeDirect.map(\.id) == [newer.id])
}

@Test @MainActor func noteReviewCursorPersistsInsideSQLiteAcrossSessionReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let paper = Paper(
        title: "Cursor Paper", digest: "cursor", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    let note = ReadingNote(paperID: paper.id, contentVersion: "v", anchors: [], markdown: "Persisted cursor note.")
    reader.state.papers = [paper]
    reader.state.readingNotes = [note]
    #expect(await reader.save())

    let probe = NoteReviewProbe()
    reader.noteReview.reviewOverride = { _, _ in
        probe.count += 1
        return #"{"revisions":[]}"#
    }
    reader.noteReview.run(reader: reader, automatic: false, withModel: true)
    for _ in 0..<200 where reader.noteReview.running {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.count == 1)
    #expect(try await reader.store.readNoteReviewCursor() != nil)

    // Clear UserDefaults to prove a fresh session restores the cursor strictly from SQLite.
    UserDefaults.standard.removeObject(forKey: "pagewise.noteReview." + root.standardizedFileURL.path + ".cursor")
    let reloaded = NoteReviewSession(store: reader.store, root: root)
    reloaded.reviewOverride = { _, _ in
        probe.count += 1
        return #"{"revisions":[]}"#
    }
    reloaded.run(reader: reader, automatic: false, withModel: true)
    for _ in 0..<200 where reloaded.running {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.count == 1)
}
