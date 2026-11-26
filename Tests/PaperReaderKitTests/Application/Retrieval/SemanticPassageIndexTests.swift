import Foundation
import Testing

@testable import PaperReaderKit

private actor FixtureEncoder: SemanticTextEncoder {
    nonisolated let identifier: String
    var encodedPassages = 0
    init(_ identifier: String = "fixture-v1") { self.identifier = identifier }

    func encode(_ texts: [String], as role: SemanticTextRole) -> [[Float]] {
        if role == .passage { encodedPassages += texts.count }
        return texts.map { text in
            if text.contains("对齐") || text.contains("equal budgets") { return [1, 0, 0] }
            if text.contains("单位") || text.contains("kilograms") { return [0, 1, 0] }
            return [0, 0, 1]
        }
    }
}

@Test func semanticNotesFindUnsharedWordsAndRetireWithdrawnVersionsAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("notes.sqlite")
    let encoder = FixtureEncoder()
    let index = ReadingNoteMemoryIndex(encoder: encoder, cacheURL: url)
    let paper = UUID()
    let titles = [paper: "Protocol"]
    var note = ReadingNote(
        paperID: paper, contentVersion: "v", anchors: [], markdown: "Under equal budgets the ranking reverses.")
    func search(
        _ index: ReadingNoteMemoryIndex, _ current: ReadingNote, _ query: String, _ mode: RetrievalMode = .hybrid
    ) async throws -> [Evidence] {
        try await index.search(query: query, notes: [current], paperTitles: titles, mode: mode)
    }
    #expect(try await search(index, note, "天气", .lexical).isEmpty)
    #expect(try await search(index, note, "对齐").first?.text == note.markdown)
    #expect(try await search(index, note, "天气").isEmpty)
    #expect(await encoder.encodedPassages == 1)
    let reopened = ReadingNoteMemoryIndex(encoder: encoder, cacheURL: url)
    #expect(try await search(reopened, note, "对齐", .semantic).first?.readingNoteID == note.id)
    #expect(await encoder.encodedPassages == 1)
    note.markdown = "The unit is kilograms."
    #expect(try await search(reopened, note, "对齐").isEmpty)
    #expect(try await search(reopened, note, "单位").first?.text == note.markdown)
    #expect(await encoder.encodedPassages == 2)
    note.deletedAt = Date()
    #expect(try await search(reopened, note, "单位").isEmpty)
    #expect(try SemanticVectorCache(url: url).load().isEmpty)
}

@Test func semanticPassageFilteringPreservesScopeAndEncoderSpaceAcrossWarmStarts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("vectors.sqlite")
    let sources = (1...6).map { SemanticPassage(sourceID: UUID(), text: "equal budgets in trial \($0)") }
    let encoder = FixtureEncoder()
    let index = SemanticPassageIndex(encoder: encoder, cacheURL: url)
    try await index.prepare(sources)
    let selected = sources[3]
    let matches = try await index.matches("对齐", passages: sources, allowed: [selected.sourceID], limit: 3)
    #expect(matches.map(\.passage) == [selected])
    try await index.prepare(sources)
    #expect(await encoder.encodedPassages == 6)
    let newer = FixtureEncoder("fixture-v2")
    try await SemanticPassageIndex(encoder: newer, cacheURL: url).prepare(sources)
    #expect(await newer.encodedPassages == 6)
    #expect(try SemanticVectorCache(url: url).load().count == 6)
}

@Test func semanticPaperSearchRevalidatesAnchorsAndMatchesExactIdentifiers() async throws {
    let index = LibraryAgentSearchIndex(encoder: FixtureEncoder())
    let distractor = TextBlock(sourcePage: 0, text: "OPSDPlus with DOI references. Other trial ID: RZQ_9132.")
    let evidence = TextBlock(sourcePage: 1, text: "OPSD used equal budgets in RZQ_9131; see 10.1234/trial.")
    var paper = Paper(
        title: "Comparison", digest: "fixture", originalPath: "fixture.pdf", pageCount: 2,
        blocks: [distractor, evidence], warnings: [], canReflow: false)
    try await index.refresh([paper])
    try await index.warmVectors()
    let found = try await index.search("对齐", papers: [paper]).first
    #expect(found?.blockID == evidence.id)
    #expect(found?.sourcePage == 2)
    #expect(found?.excerpt == evidence.text)
    for identifier in ["OPSD", "RZQ_9131", "https://doi.org/10.1234/trial", "DOI:10.1234/trial"] {
        #expect(try await index.search(identifier, papers: [paper]).first?.blockID == evidence.id)
    }
    paper.blocks.removeLast()
    #expect(try await index.search("对齐", papers: [paper]).isEmpty)
    #expect(try await index.search("OPSD", papers: [paper]).isEmpty)
    await index.discard(paper.id)
    #expect(try await index.search("Comparison", papers: []).isEmpty)
}

private actor UnavailableEncoder: SemanticTextEncoder {
    nonisolated let identifier = "absent"
    func isInstalled() -> Bool { false }
    func encode(_ texts: [String], as role: SemanticTextRole) -> [[Float]] {
        Issue.record("A device without model files should only run lexical retrieval.")
        return []
    }
}

@Test func paperSearchWithoutInstalledModelKeepsLexicalIndexAndSkipsVectorDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let index = LibraryAgentSearchIndex(root: root, encoder: UnavailableEncoder())
    let text = TextBlock(sourcePage: 0, text: "Training was cost matched.")
    let paper = Paper(
        title: "Training protocol", digest: "fixture", originalPath: "fixture.pdf", pageCount: 1,
        blocks: [text], warnings: [], canReflow: false)
    try await index.prepareIfAbsent(paper)
    try await index.warmVectors()
    #expect(try await index.search("cost", papers: [paper]).first?.blockID == text.id)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("DerivedIndexes/papers.sqlite").path))
}

@Test func reopenedVectorCachePreventsLateWritesFromPreviousWindows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SemanticVectorCache(url: root.appendingPathComponent("vectors.sqlite"))
    let key = Data(repeating: 0x37, count: 32)
    _ = try cache.load(writer: "A")
    try cache.update(adding: [key: [1, 0]], removing: [], writer: "A")
    #expect(try cache.load(writer: "B")[key] != nil)
    try cache.update(adding: [:], removing: [key], writer: "B")
    try cache.update(adding: [key: [1, 0]], removing: [], writer: "A")
    #expect(try cache.load().isEmpty)
}

@Test func aSingleIncidentalTermDoesNotOutrankAValidatedSemanticNote() async throws {
    let index = ReadingNoteMemoryIndex(encoder: FixtureEncoder())
    let paper = UUID()
    let weak = ReadingNote(paperID: paper, contentVersion: "v", anchors: [], markdown: "A travel budget.")
    let relevant = ReadingNote(
        paperID: paper, contentVersion: "v", anchors: [], markdown: "The comparison used equal budgets.")
    let query = "对齐 the evaluation budget between the runs"
    let hits = try await index.search(query: query, notes: [weak, relevant], paperTitles: [paper: "Protocol"])
    #expect(hits.map(\.readingNoteID) == [relevant.id, weak.id])
}

/// Frozen development examples exercise the production score gate independently of the held-out quality benchmark.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_BENCH_MODEL"] != nil))
func calibratedSemanticDevelopmentExamples() async throws {
    struct Example: Decodable {
        var text: String
        var target: Int?
        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            text = try row.decode(String.self)
            target = try row.decodeIfPresent(Int.self)
        }
    }
    struct SetFile: Decodable {
        var documents: [String]
        var queries: [Example]
    }
    let modelPath = try #require(ProcessInfo.processInfo.environment["PAGEWISE_BENCH_MODEL"])
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(
        SetFile.self, from: Data(contentsOf: repo.appendingPathComponent("scripts/fixtures/semantic-development.json")))
    let notes = fixture.documents.map {
        ReadingNote(paperID: UUID(), contentVersion: "development", anchors: [], markdown: $0)
    }
    let titles = Dictionary(uniqueKeysWithValues: notes.map { ($0.paperID, "Collection") })
    let index = ReadingNoteMemoryIndex(encoder: DeviceSemanticEncoder(directory: URL(fileURLWithPath: modelPath)))
    _ = try await index.search(query: "", notes: notes, paperTitles: titles, limit: 0)
    for mode in [RetrievalMode.lexical, .semantic, .hybrid] {
        var first = 0
        var recalled = 0
        var falsePositives = 0
        for example in fixture.queries {
            let result = try await index.search(
                query: example.text, notes: notes, paperTitles: titles, limit: 5, mode: mode)
            if let target = example.target {
                if result.first?.readingNoteID == notes[target].id { first += 1 }
                if result.contains(where: { $0.readingNoteID == notes[target].id }) { recalled += 1 }
            } else if !result.isEmpty {
                falsePositives += 1
            }
        }
        print("DEVELOPMENT", mode, "r@1", first, "/12 r@5", recalled, "/12 false positives", falsePositives, "/8")
        if mode == .semantic {
            #expect(recalled >= 9)
            #expect(falsePositives <= 1)
        }
    }
}

private actor GatedEncoder: SemanticTextEncoder {
    nonisolated let identifier = "gated-v1"
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func encode(_ texts: [String], as role: SemanticTextRole) async -> [[Float]] {
        if role == .passage {
            calls += 1
            if calls == 2 {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        return texts.map { text in
            text.contains("对齐") || text.contains("equal budgets") ? [1, 0, 0] : [0, 0, 1]
        }
    }

    func waitForPause() async {
        while continuation == nil { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Test func semanticIndexGatesPartialCoverageUntilFullCorpusIsWarm() async throws {
    let encoder = GatedEncoder()
    let index = SemanticPassageIndex(encoder: encoder)
    let passages = (0..<8).map { offset in
        SemanticPassage(
            sourceID: UUID(),
            text: offset == 0 ? "equal budgets hold in trial 0" : "unrelated trial \(offset)")
    }
    let allowed = Set(passages.map(\.sourceID))

    // First query on >4 passages starts background warmup and returns empty without blocking.
    let initial = try await index.matches("对齐", passages: passages, allowed: allowed, limit: 3)
    #expect(initial.isEmpty)
    await encoder.waitForPause()
    let partialCoverage = await index.coverage()
    #expect(partialCoverage > 0 && partialCoverage < 1.0)
    // While only half the corpus is warm, semantic matches stay gated so partial vectors cannot distort RRF.
    let partial = try await index.matches("对齐", passages: passages, allowed: allowed, limit: 3)
    #expect(partial.isEmpty)

    await encoder.resume()
    for _ in 0..<200 where !(await index.isWarm()) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await index.coverage() == 1.0)
    let warm = try await index.matches("对齐", passages: passages, allowed: allowed, limit: 3)
    #expect(warm.first?.passage.sourceID == passages[0].sourceID)
}

@Test func libraryFTSIndexRanksExactTitleAndBodyMatchesWithBM25AndClearsDeletedPapers() async throws {
    let index = LibraryAgentSearchIndex()
    let strongBlock = TextBlock(
        sourcePage: 0, text: "Distillation under matched compute budget improves student calibration.")
    let weakBlock = TextBlock(
        sourcePage: 1, text: "A brief mention of budget in related work without calibration details.")
    let strong = Paper(
        title: "Matched Compute Budget Distillation", digest: "fts-strong", originalPath: "s.pdf", pageCount: 1,
        blocks: [strongBlock], warnings: [], canReflow: true)
    let weak = Paper(
        title: "General Survey", digest: "fts-weak", originalPath: "w.pdf", pageCount: 2,
        blocks: [weakBlock], warnings: [], canReflow: true)

    let hits = try await index.search("compute budget distillation", papers: [weak, strong])
    #expect(hits.first?.paperID == strong.id)
    #expect(hits.first?.blockID == strongBlock.id)

    let afterRemoval = try await index.search("distillation", papers: [weak])
    #expect(afterRemoval.isEmpty)
}
