import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import PaperReaderKit

/// One numbered sentence per reading sample, so the transport's log can identify exactly which work was sent.
private actor QueueTransport: HTTPTransport {
    private(set) var requests: [[String]] = []
    private var invalid: String?
    private var denied: String?

    init(invalid: String? = nil, denied: String? = nil) {
        self.invalid = invalid
        self.denied = denied
    }

    func repair() {
        invalid = nil
        denied = nil
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        struct Envelope: Decodable {
            struct Message: Decodable { let content: String }
            let messages: [Message]
        }
        struct Input: Decodable {
            struct Sentence: Decodable {
                let id: String
                let en: String
            }
            let sentences: [Sentence]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: #require(request.httpBody))
        let payload = try #require(envelope.messages.last?.content)
        let input = try JSONDecoder().decode(Input.self, from: Data(payload.utf8))
        let numbers = input.sentences.map { $0.en.filter(\.isNumber) }
        requests.append(numbers)
        let status = denied.map { numbers.contains($0) } == true ? 401 : 200
        let pairs = zip(numbers, input.sentences).map { number, sentence in
            ["id": sentence.id, "zh": invalid == number ? "数量未知。" : "样本数为 \(number)。"]
        }
        let output = try JSONSerialization.data(withJSONObject: ["sentences": pairs])
        let response: [String: Any] = [
            "choices": [["finish_reason": "stop", "message": ["content": String(decoding: output, as: UTF8.self)]]]
        ]
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: response), http)
    }
}

private struct QueueFixture {
    let root: URL
    let url: URL
    let count: Int
    let settings: ModelSettings
    let store: PDFSentenceTranslationStore

    init(_ pages: [[Int]], illustrated: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("original.pdf")
        count = pages.count
        var settings = ModelSettings()
        settings.model = "fixture"
        self.settings = settings
        store = PDFSentenceTranslationStore(root: root)
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat) {
            let string = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        for page in pages {
            context.beginPDFPage(nil)
            for (index, number) in page.enumerated() {
                draw("The sample contains \(number) elements.", x: 50, y: CGFloat(700 - index * 24))
            }
            if illustrated {
                context.stroke(CGRect(x: 74, y: 528, width: 274, height: 103))
                context.fill(CGRect(x: 124, y: 528, width: 25, height: 50))
                context.fill(CGRect(x: 170, y: 528, width: 25, height: 68))
                draw("The signal reaches 99.", x: 200, y: 606)
                draw("Time (s).", x: 181, y: 514)
                draw("Figure 1: Measured uptake.", x: 72, y: 487)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    func queue(_ transport: QueueTransport, store: PDFSentenceTranslationStore? = nil) -> PDFDocumentTranslationQueue {
        PDFDocumentTranslationQueue(
            url: url, documentHash: "fixture", pageCount: count, store: store ?? self.store, settings: settings,
            client: ModelClient(transport: transport), key: { "fixture" })
    }
}

private actor QueueProgressLog {
    private(set) var values: [PDFDocumentTranslationProgress] = []
    func record(_ progress: PDFDocumentTranslationProgress) {
        values.append(progress)
    }
}

@Test func pdfQueuePrioritizesVisiblePagesSkipsBlanksAndRetriesOnlyUnverifiedText() async throws {
    let fixture = try QueueFixture([[10, 11], [], [20], [30]])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transport = QueueTransport(invalid: "11")
    let queue = fixture.queue(transport)
    let log = QueueProgressLog()
    try await queue.run(prioritizing: 2) { progress in
        await log.record(progress)
        if progress.activePageIndex == 2 { await queue.prioritize(3) }
    } onUpdate: { _, _ in
    }
    let progress = await log.values
    #expect(progress.compactMap(\.activePageIndex) == [2, 3, 0, 1])
    #expect(progress.last?.processedPages == 4)
    #expect(progress.last?.partialPages == 1)
    #expect(progress.last?.skippedPages == 1)
    #expect(await transport.requests == [["20"], ["30"], ["10", "11"], ["11"]])

    await transport.repair()
    let retry = QueueProgressLog()
    try await queue.run(prioritizing: 3, onProgress: { await retry.record($0) }, onUpdate: { _, _ in })
    #expect(await retry.values.compactMap(\.activePageIndex) == [0])
    #expect(await retry.values.last?.partialPages == 0)
    #expect(await retry.values.last?.processedPages == 4)
    #expect(await transport.requests == [["20"], ["30"], ["10", "11"], ["11"], ["11"]])
}

@Test func pdfQueueStopsOnAuthorizationFailureAndReusesCompletedPagesAfterRestart() async throws {
    let fixture = try QueueFixture([[10], [20], [30]])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let failing = QueueTransport(denied: "10")
    let queue = fixture.queue(failing)
    await #expect(throws: ReaderError.self) {
        try await queue.run(prioritizing: 1, onProgress: { _ in }, onUpdate: { _, _ in })
    }
    #expect(await failing.requests == [["20"], ["10"]])
    let healthy = QueueTransport()
    let reopened = fixture.queue(healthy, store: PDFSentenceTranslationStore(root: fixture.root))
    let log = QueueProgressLog()
    try await reopened.run(prioritizing: 1, onProgress: { await log.record($0) }, onUpdate: { _, _ in })
    #expect(await healthy.requests == [["10"], ["30"]])
    #expect(await log.values.compactMap(\.activePageIndex) == [0, 2])
    #expect(await log.values.last?.processedPages == 3)
}

@Test func pdfQueueSendsBodyAndCaptionWhilePreservingTextInsideFigure() async throws {
    let fixture = try QueueFixture([[10]], illustrated: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let plain = try PDFSentenceExtractor.extract(url: fixture.url, pageIndex: 0)
    #expect(plain.contains(where: { $0.text == "The signal reaches 99." }))
    let transport = QueueTransport()
    try await fixture.queue(transport).run(prioritizing: 0, onProgress: { _ in }, onUpdate: { _, _ in })
    #expect(await transport.requests.flatMap { $0 } == ["10", "1"])
}

@Test func pdfQueueResumesLongInterruptedPageWithoutResendingItsCompletedBatch() async throws {
    let fixture = try QueueFixture([Array(10...21), [30]])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transport = QueueTransport(denied: "20")
    let queue = fixture.queue(transport)
    let log = QueueProgressLog()
    await #expect(throws: ReaderError.self) {
        try await queue.run(prioritizing: 0, onProgress: { await log.record($0) }, onUpdate: { _, _ in })
    }
    #expect(await log.values.last?.processedPages == 0)
    let firstBatch = (10...19).map(String.init)
    #expect(await transport.requests == [firstBatch, ["20", "21"]])
    await transport.repair()
    try await queue.run(prioritizing: 1, onProgress: { await log.record($0) }, onUpdate: { _, _ in })
    #expect(await transport.requests == [firstBatch, ["20", "21"], ["30"], ["20", "21"]])
    #expect(await log.values.last?.processedPages == 2)
}

@Test func pdfQueueCancellationRetainsPublishedBatchAndSerializesManualTranslationsOnItsPage() async throws {
    let fixture = try QueueFixture([[10], [20]])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transport = QueueTransport()
    let queue = fixture.queue(transport)
    let sentences = try PDFSentenceExtractor.extract(url: fixture.url, pageIndex: 0)
    let published = AsyncStream<Void>.makeStream()
    let proceed = AsyncStream<Void>.makeStream()
    let worker = Task {
        try await queue.run(prioritizing: 0, onProgress: { _ in }) { _, _ in
            published.continuation.finish()
            for await _ in proceed.stream {}
        }
    }
    for await _ in published.stream {}
    let started = AsyncStream<Void>.makeStream()
    let abandoned = Task {
        started.continuation.finish()
        return try await fixture.store.translate(
            documentHash: "fixture", sentences: sentences, settings: fixture.settings,
            client: ModelClient(transport: transport), key: { "fixture" })
    }
    for await _ in started.stream {}
    abandoned.cancel()
    await #expect(throws: CancellationError.self) { try await abandoned.value }
    let manual = Task {
        try await fixture.store.translate(
            documentHash: "fixture", sentences: sentences, settings: fixture.settings,
            client: ModelClient(transport: transport),
            key: { throw ReaderError.message("已保存的译句不需要密钥。") })
    }
    // Cancellation unblocks the worker's AsyncStream wait while the published page remains in the store.
    worker.cancel()
    proceed.continuation.finish()
    await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(try await manual.value.count == 1)
    #expect(await transport.requests == [["10"]])
    try await queue.run(prioritizing: 1, onProgress: { _ in }, onUpdate: { _, _ in })
    #expect(await transport.requests == [["10"], ["20"]])
}

@Test func pdfQueueReopensCompletedAndBlankPagesWithoutConsultingPDFKit() async throws {
    let fixture = try QueueFixture([[10], [], [30]])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transport = QueueTransport()
    try await fixture.queue(transport).run(prioritizing: 2, onProgress: { _ in }, onUpdate: { _, _ in })
    // Any accidental extraction would now fail. The visible reader loads its own page geometry separately.
    try FileManager.default.removeItem(at: fixture.url)
    let fresh = PDFSentenceTranslationStore(root: fixture.root)
    let log = QueueProgressLog()
    try await fixture.queue(transport, store: fresh).run(
        prioritizing: 1, onProgress: { await log.record($0) },
        onUpdate: { page, values in
            #expect(page == 1 ? values.isEmpty : values.count == 1)
        })
    #expect(await transport.requests.count == 2)
    #expect(await log.values.compactMap(\.activePageIndex).isEmpty)
    #expect(await log.values.last?.skippedPages == 1)
    #expect(await log.values.last?.processedPages == 3)
    var changed = fixture.settings
    changed.model += "-new"
    #expect(try await fresh.completedPage(documentHash: "fixture", pageIndex: 0, settings: changed) == nil)
}

@Test func pdfQueueDoesNotInterpretManualSentenceCacheAsACompletePage() async throws {
    let fixture = try QueueFixture([[10, 11]])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transport = QueueTransport()
    let first = try #require(PDFSentenceExtractor.extract(url: fixture.url, pageIndex: 0).first)
    try await fixture.store.translate(
        documentHash: "fixture", sentences: [first], settings: fixture.settings,
        client: ModelClient(transport: transport),
        key: { "fixture" })
    #expect(
        try await fixture.store.completedPage(documentHash: "fixture", pageIndex: 0, settings: fixture.settings) == nil)
    try await fixture.queue(transport).run(prioritizing: 0, onProgress: { _ in }, onUpdate: { _, _ in })
    #expect(await transport.requests == [["10"], ["11"]])
    #expect(
        try await fixture.store.completedPage(documentHash: "fixture", pageIndex: 0, settings: fixture.settings)?.count
            == 2)
}
