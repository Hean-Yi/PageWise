import Foundation
import Testing

@testable import PaperReaderKit

struct PaperAbstractStoreTests {
    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    @Test func concurrentImportAndPreviewPersistTheSameOriginalSentencesOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperAbstractStore(root: root)
        let source = PaperAbstractStore.Source.pdf(digest: "same-bytes")
        let counter = Counter()
        let sentence = PDFSourceSentence(
            id: "p1-s0", text: "Our measurement is repeatable.", pageIndex: 1, rects: [[12, 34, 56, 9]],
            paragraphID: "p1-line0", characterRanges: [NSRange(location: 9, length: 30)], readingParagraphID: "p1-para0"
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let record = try await store.record(for: source) {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(20))
                        return PDFAbstractRecord(
                            parts: [
                                .init(text: sentence.text, paragraph: sentence.readingParagraphID, key: sentence.id)
                            ],
                            sentences: [sentence])
                    }
                    #expect(record.sentences == [sentence])
                }
            }
            try await group.waitForAll()
        }
        let reopened = PaperAbstractStore(root: root)
        let persisted = try await reopened.record(for: source) {
            throw ReaderError.message("已保存的原句不可再次提取。")
        }
        #expect(await counter.count == 1)
        #expect(persisted.parts.first?.key == sentence.id)
        #expect(persisted.parts.first?.text == sentence.text)
        #expect(persisted.parts.first?.paragraph == sentence.readingParagraphID)
        #expect(persisted.sentences == [sentence])
    }

    @Test func completedNegativeResultSurvivesReopeningAndLeavesPublishedSourcesIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperAbstractStore(root: root)
        let pdf = PaperAbstractStore.Source.pdf(digest: "original")
        let publication = PaperAbstractStore.Source.publication(digest: "original", revision: "edition A")
        #expect(try await store.cached(pdf) == nil)
        _ = try await store.record(for: pdf) { PDFAbstractRecord(parts: [], sentences: []) }
        let reopened = PaperAbstractStore(root: root)
        let negative = try await reopened.record(for: pdf) { throw ReaderError.message("不应重复识别。") }
        #expect(negative.parts.isEmpty)
        #expect(try await reopened.cached(publication) == nil)
        _ = try await reopened.record(for: publication) {
            .init(parts: [.init(text: "A bounded comparison.", paragraph: "front", key: "section")], sentences: [])
        }
        #expect(try await reopened.cached(publication)?.parts.first?.key == "section")
        #expect(try await reopened.cached(.publication(digest: "original", revision: "edition B")) == nil)
        #expect(try await reopened.cached(pdf)?.parts.isEmpty == true)
    }

    @Test func closingPreviewDuringImportKeepsTheSharedExtraction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperAbstractStore(root: root)
        let source = PaperAbstractStore.Source.pdf(digest: "in-progress")
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let preview = Task {
            try await store.record(for: source) {
                started.continuation.finish()
                for await _ in resume.stream {}
                return .init(parts: [.init(text: "Stable content.", paragraph: "a", key: "s")], sentences: [])
            }
        }
        for await _ in started.stream {}
        let importing = Task {
            try await store.record(for: source) { throw ReaderError.message("导入不应再次读取同一 PDF。") }
        }
        preview.cancel()
        resume.continuation.finish()
        await #expect(throws: CancellationError.self) { try await preview.value }
        #expect(try await importing.value.parts.first?.text == "Stable content.")
        #expect(try await PaperAbstractStore(root: root).cached(source)?.parts.first?.key == "s")
    }

    @Test func extractionErrorsDoNotTurnIntoNegativeResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperAbstractStore(root: root)
        let source = PaperAbstractStore.Source.pdf(digest: "temporary-error")
        await #expect(throws: CancellationError.self) {
            try await store.record(for: source) { throw CancellationError() }
        }
        #expect(try await store.cached(source) == nil)
        _ = try await store.record(for: source) {
            .init(parts: [.init(text: "The file is now readable.", paragraph: "p", key: "s")], sentences: [])
        }
        #expect(try await store.cached(source)?.parts.first?.text == "The file is now readable.")
    }

    @Test func aTemporaryCacheWriteFailureKeepsTheTextReadableAndRetriesPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperAbstractStore(root: root)
        let source = PaperAbstractStore.Source.pdf(digest: "readable-pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let obstruction = root.appendingPathComponent("PaperAbstracts")
        try Data().write(to: obstruction)
        let initial = try await store.record(for: source) {
            .init(parts: [.init(text: "A recoverable result.", paragraph: "a", key: "s")], sentences: [])
        }
        #expect(initial.parts.first?.text == "A recoverable result.")
        try FileManager.default.removeItem(at: obstruction)
        _ = try await store.record(for: source) { throw ReaderError.message("已有可读摘要，不应重新提取。") }
        #expect(try await PaperAbstractStore(root: root).cached(source)?.parts.first?.text == "A recoverable result.")
    }
}
