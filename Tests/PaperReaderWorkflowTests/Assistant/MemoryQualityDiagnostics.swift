import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_QUALITY_DIAGNOSTICS"] == "1"))
@MainActor func diagnoseNoteReviewQualityAndCost() async throws {
    let environment = ProcessInfo.processInfo.environment
    let key = try #require(environment["PAGEWISE_TEST_SLEEP_KEY"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var settings = ModelSettings()
    settings.baseURL = "https://api.deepseek.com"
    settings.model = "deepseek-flash"
    _ = try reader.saveSettings(settings, key: key)
    let paper = Paper(
        id: UUID(), title: "Matched-budget study", digest: "diagnostic", originalPath: "unused.pdf",
        pageCount: 1, blocks: [], warnings: [], canReflow: false)
    let notes = [
        "在匹配训练时长下，方法 A 的准确率提升 3.2 个百分点。",
        "在匹配训练时长下，方法 A 的准确率提升 5.0 个百分点。",
        "方法 A 在验证集上的提升不显著。",
        "在相同计算预算下，方法 B 的推理延迟降低 12%。",
        "更正：在匹配训练时长下，方法 A 的提升为 3.2 个百分点；此前记录的 5.0 是旧版笔误。",
    ].enumerated().map { index, markdown in
        var note = ReadingNote(
            paperID: paper.id, contentVersion: "diagnostic", anchors: [], markdown: markdown)
        note.createdAt = Date(timeIntervalSinceReferenceDate: 1_000 + Double(index))
        note.modifiedAt = note.createdAt
        return note
    }
    reader.state.papers = [paper]
    reader.state.readingNotes = notes
    _ = await reader.save()
    let start = ContinuousClock.now
    reader.noteReview.run(reader: reader, automatic: false, withModel: true)
    for _ in 0..<240 where reader.noteReview.running {
        try await Task.sleep(for: .milliseconds(250))
    }
    let elapsed = ContinuousClock.now - start
    let revisions = reader.state.readingNotes.filter { !($0.revisions ?? []).isEmpty }
    let markdownBytes = notes.reduce(0) { $0 + $1.markdown.utf8.count }
    print(
        "QUALITY_NOTE_REVIEW",
        "elapsed_ms", Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
        "notes", notes.count, "revised", revisions.count,
        "input_chars_upper_bound", markdownBytes * 3,
        "message", reader.noteReview.message ?? "nil")
    for note in revisions {
        let old = note.revisions?.last?.markdown ?? ""
        let lengthRatio = Double(note.markdown.count) / Double(max(old.count, 1))
        print(
            "QUALITY_NOTE_REVISION",
            "old_chars", old.count, "new_chars", note.markdown.count,
            "length_ratio", lengthRatio, "new", String(note.markdown.prefix(160)))
    }
}

@Test @MainActor func diagnoseSilentForgetDedupAndAudit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    reader.state.memories = [
        MemoryItem(text: "旧的吞吐量比较记录", sourceID: UUID()),
        MemoryItem(text: "旧的延迟比较记录", sourceID: UUID()),
    ]
    let forgetStart = ContinuousClock.now
    let ambiguous = reader.respondToMemoryCommand("忘掉旧的比较记录。")
    let ambiguousMs = (ContinuousClock.now - forgetStart).components
    let unique = reader.respondToMemoryCommand("忘掉旧的吞吐量比较记录。")
    let uniqueMs = (ContinuousClock.now - forgetStart).components
    for _ in 0..<100 where (try? await reader.store.memoryAuditCount()) != 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    print(
        "QUALITY_FORGET",
        "ambiguous_handled_locally", ambiguous != nil,
        "unique_handled_locally", unique != nil,
        "ambiguous_ms", Double(ambiguousMs.seconds) * 1000 + Double(ambiguousMs.attoseconds) / 1e15,
        "unique_and_audit_ms", Double(uniqueMs.seconds) * 1000 + Double(uniqueMs.attoseconds) / 1e15,
        "audit_rows", (try? await reader.store.memoryAuditCount()) ?? -1)
    print(
        "QUALITY_DEDUP",
        "paraphrase_equal",
        MemoryDedupKey.key("匹配计算预算后比较方法。") == MemoryDedupKey.key("在相同 compute budget 下比较方法。"),
        "different_numbers_equal",
        MemoryDedupKey.key("提升 3.2 个点。") == MemoryDedupKey.key("提升 5.0 个点。"),
        "negation_equal",
        MemoryDedupKey.key("有提升。") == MemoryDedupKey.key("没有提升。"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_LIBRARY_DIAGNOSTICS"] == "1"))
@MainActor func diagnoseCopiedLibraryState() async throws {
    let environment = ProcessInfo.processInfo.environment
    let source = try #require(environment["PAGEWISE_TEST_LIBRARY"])
    let sourceRoot = URL(fileURLWithPath: source, isDirectory: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: sourceRoot.appendingPathComponent("library.sqlite"), to: root.appendingPathComponent("library.sqlite"))
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    print(
        "QUALITY_LIBRARY",
        "papers", reader.state.papers.count, "notes", reader.state.readingNotes.count,
        "chats", reader.state.chats.count, "memories", reader.state.memories.count,
        "events", try await reader.store.researchEventCounts(),
        "index_generation", try await reader.store.researchGeneration())
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_INSTALL_E5"] == "1"))
func installE5ForDiagnostics() async throws {
    let encoder = DeviceSemanticEncoder.shared
    if await !encoder.isInstalled() {
        try await encoder.install()
    }
    print("QUALITY_E5", "installed", await encoder.isInstalled(), "identifier", encoder.identifier)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_QUALITY_DIAGNOSTICS"] == "1"))
@MainActor func diagnoseDirectConflictRevision() async throws {
    let environment = ProcessInfo.processInfo.environment
    let key = try #require(environment["PAGEWISE_TEST_SLEEP_KEY"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var settings = ModelSettings()
    settings.baseURL = "https://api.deepseek.com"
    settings.model = "deepseek-flash"
    _ = try reader.saveSettings(settings, key: key)
    let paper = Paper(
        id: UUID(), title: "Conflict fixture", digest: "conflict", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    var old = ReadingNote(
        paperID: paper.id, contentVersion: "v", anchors: [],
        markdown: "在匹配训练时长下，方法 A 的准确率提升 5.0 个百分点。")
    var newer = ReadingNote(
        paperID: paper.id, contentVersion: "v", anchors: [],
        markdown: "更正：在匹配训练时长下，方法 A 的提升为 3.2 个百分点；5.0 是旧版笔误。")
    old.createdAt = Date(timeIntervalSinceReferenceDate: 100)
    old.modifiedAt = old.createdAt
    newer.createdAt = Date(timeIntervalSinceReferenceDate: 200)
    newer.modifiedAt = newer.createdAt
    reader.state.papers = [paper]
    reader.state.readingNotes = [old, newer]
    _ = await reader.save()
    let target = NoteReviewInput.Target(
        noteID: old.id, title: "Conflict fixture", modifiedAt: old.modifiedAt, markdown: old.markdown,
        relations: [
            .init(
                noteID: newer.id, title: "Conflict fixture", modifiedAt: newer.modifiedAt, kind: "conflict",
                overlap: 4, excerpt: String(newer.markdown.prefix(120)))
        ])
    let start = ContinuousClock.now
    let response = try await reader.reviewNoteBatch(NoteReviewInput(targets: [target]))
    let elapsed = ContinuousClock.now - start
    let report = try JSONDecoder.noteReview.decode(NoteReviewReport.self, from: Data(response.utf8))
    let changed = try await reader.applyNoteReview(report, contexts: [target])
    print(
        "QUALITY_DIRECT_CONFLICT", "ms",
        Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
        "response_chars", response.count, "revision_count", report.revisions.count, "changed", changed,
        "response", String(response.prefix(500)))
}

extension JSONDecoder {
    fileprivate static var noteReview: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
