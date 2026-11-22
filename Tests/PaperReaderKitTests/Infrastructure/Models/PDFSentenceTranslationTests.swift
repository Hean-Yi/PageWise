import Foundation
import Testing

@testable import PaperReaderKit

private actor SentenceReplies: HTTPTransport {
    enum Mode { case correct, reverseIDs, loseUnit, failAfterFirst, missVariable }
    let mode: Mode
    private(set) var counts: [Int] = []
    private(set) var paragraphGroups: [[Int]] = []
    init(_ mode: Mode = .correct) { self.mode = mode }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(body["messages"] as? [[String: String]])
        let input = try #require(messages.last?["content"])
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let sources = try #require(parsed["sentences"] as? [[String: Any]])
        counts.append(sources.count)
        paragraphGroups.append(sources.compactMap { $0["paragraph"] as? Int })
        let status = mode == .failAfterFirst && counts.count > 1 ? 429 : 200
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        var pairs = sources.compactMap { source -> [String: String]? in
            guard let id = source["id"] as? String else { return nil }
            let translated: String
            if let text = source["en"] as? String, text.hasPrefix("The threshold T") {
                translated = mode == .missVariable ? "阈值保持恒定。" : "阈值 T 保持恒定。"
            } else {
                translated = mode == .loseUnit ? "延迟在 3.25 以下，见 [12]。" : "延迟在 3.25 ms以下，见[12]。"
            }
            return ["id": id, "zh": translated]
        }
        if mode == .reverseIDs { pairs.reverse() }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["sentences": pairs]), as: UTF8.self)
        let envelope: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": content]]]]
        return (try JSONSerialization.data(withJSONObject: envelope), response)
    }
}

private func sampleSettings() -> ModelSettings {
    var configuration = ModelSettings()
    configuration.model = "deepseek-flash"
    configuration.baseURL = "https://api.deepseek.com"
    return configuration
}

private func sampleSentences(_ count: Int) -> [PDFSourceSentence] {
    (0..<count).map { index in
        PDFSourceSentence(
            id: "p0-s\(index)", text: "The latency was below 3.25 ms [12].", pageIndex: 0,
            rects: [[8, Double(index * 10), 75, 9]], paragraphID: "paragraph")
    }
}

@Test func pdfSentenceTranslationPreservesAnchorsAndResumesWithoutRebillOfCompletedBatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentences = sampleSentences(12)
    let failing = SentenceReplies(.failAfterFirst)
    let settings = sampleSettings()
    let store = PDFSentenceTranslationStore(root: root)
    await #expect(throws: ReaderError.self) {
        try await store.translate(
            documentHash: "original-digest", sentences: sentences, settings: settings,
            client: ModelClient(transport: failing),
            key: { "test-only" })
    }
    #expect(await failing.counts == [10, 2])
    let restarted = PDFSentenceTranslationStore(root: root)
    let partial = try await restarted.cached(documentHash: "original-digest", sentences: sentences)
    #expect(Set(partial.keys) == Set(sentences.prefix(10).map(\.id)))
    let recovered = SentenceReplies()
    let complete = try await restarted.translate(
        documentHash: "original-digest", sentences: sentences, settings: settings,
        client: ModelClient(transport: recovered),
        key: { "test-only" })
    #expect(complete.count == 12)
    #expect(await recovered.counts == [2])
    let offline = try await restarted.translate(
        documentHash: "original-digest", sentences: sentences, settings: settings,
        client: ModelClient(transport: recovered),
        key: { throw ReaderError.message("unexpected credential lookup") })
    #expect(offline == complete)
    #expect(await recovered.counts == [2])
    #expect(try await restarted.cached(documentHash: "other-pdf", sentences: sentences).isEmpty)
    let changed = PDFSourceSentence(
        id: sentences[0].id, text: "Changed source.", pageIndex: 0, rects: [], paragraphID: "paragraph")
    #expect(try await restarted.cached(documentHash: "original-digest", sentences: [changed]).isEmpty)
}

@Test func pdfReflowReusesCachedSentencesAndSendsNewOnesInReadingParagraphs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = sampleSentences(4)
    let store = PDFSentenceTranslationStore(root: root)
    let replies = SentenceReplies()
    let client = ModelClient(transport: replies)
    let settings = sampleSettings()
    let first = try await store.translate(
        documentHash: "hash", sentences: [original[0]], settings: settings, client: client, key: { "test-only" })
    let regrouped = original.enumerated().map { index, sentence in
        PDFSourceSentence(
            id: sentence.id, text: sentence.text, pageIndex: sentence.pageIndex,
            rects: sentence.rects, paragraphID: sentence.paragraphID, characterRanges: sentence.characterRanges,
            readingParagraphID: index < 2 ? "opening" : "results")
    }
    #expect(try await store.cached(documentHash: "hash", sentences: regrouped) == first)
    let complete = try await store.translate(
        documentHash: "hash", sentences: regrouped, settings: settings, client: client, key: { "test-only" })
    #expect(complete.count == 4)
    #expect(await replies.paragraphGroups == [[1], [1, 2, 2]])
}

@Test func pdfSentenceTranslationRejectsInvalidAlignmentAndMissingUnits() async throws {
    for mode in [SentenceReplies.Mode.reverseIDs, .loseUnit] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replies = SentenceReplies(mode)
        let store = PDFSentenceTranslationStore(root: root)
        let source = sampleSentences(2)
        await #expect(throws: ReaderError.self) {
            try await store.translate(
                documentHash: "original-digest", sentences: source, settings: sampleSettings(),
                client: ModelClient(transport: replies),
                key: { "test-only" })
        }
        #expect(await replies.counts == [2, 2])
        #expect(try await store.cached(documentHash: "original-digest", sentences: source).isEmpty)
    }
}

@Test func pdfSentenceTranslationKeepsLaterAnchorsAndRetriesOnlyUnverifiedSentence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var source = sampleSentences(12)
    let original = source[3]
    source[3] = PDFSourceSentence(
        id: original.id, text: "The threshold T stays constant.", pageIndex: 0,
        rects: original.rects, paragraphID: original.paragraphID)
    let store = PDFSentenceTranslationStore(root: root)
    let failing = SentenceReplies(.missVariable)
    do {
        _ = try await store.translate(
            documentHash: "hash", sentences: source, settings: sampleSettings(),
            client: ModelClient(transport: failing), key: { "test-only" })
        Issue.record("Expected partial completion")
    } catch {
        #expect(error.localizedDescription.contains("11 / 12"))
    }
    #expect(await failing.counts == [10, 2, 1])
    let saved = try await store.cached(documentHash: "hash", sentences: source)
    #expect(saved.count == 11)
    #expect(saved[original.id] == nil)
    #expect(saved[source[11].id] != nil)
    let repaired = SentenceReplies()
    let result = try await store.translate(
        documentHash: "hash", sentences: source, settings: sampleSettings(),
        client: ModelClient(transport: repaired), key: { "test-only" })
    #expect(result.count == 12)
    #expect(await repaired.counts == [1])
}

@Test func pdfSentenceTranslationChecksAddedValuesReferencesAndMath() {
    let original = "The threshold T is -3.25 ms [12]."
    #expect(PDFTranslationIntegrity.accepts("阈值 T 是 −3.25 ms [12]。", source: original))
    #expect(!PDFTranslationIntegrity.accepts("阈值 T 是 −3.25 ms [12]，方差为 0.80。", source: original))
    #expect(!PDFTranslationIntegrity.accepts("阈值 T 是 3.25 ms [12]。", source: original))
    #expect(!PDFTranslationIntegrity.accepts("阈值 T 是 −3.25 s [12]。", source: original))
    #expect(!PDFTranslationIntegrity.accepts("阈值 T 是 −3.25 ms，分为 12 组。", source: original))
    #expect(!PDFTranslationIntegrity.accepts("阈值是 −3.25 ms [12]。", source: original))
    #expect(!PDFTranslationIntegrity.accepts("设 y = 3。", source: "Let x = 3."))
    #expect(PDFTranslationIntegrity.accepts("例如在美国的一项评估。", source: "An evaluation, e.g. in the U.S."))
}
