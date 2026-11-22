import Foundation

public struct PDFDocumentTranslationProgress: Equatable, Sendable {
    public let pageCount: Int
    public fileprivate(set) var processedPages = 0
    public fileprivate(set) var skippedPages = 0
    public fileprivate(set) var partialPages = 0
    public fileprivate(set) var activePageIndex: Int?

    public init(pageCount: Int) {
        self.pageCount = max(0, pageCount)
    }
}

/// Translates one original PDF a page at a time. Only the sentence store survives a new reading session.
public actor PDFDocumentTranslationQueue {
    private let url: URL
    private let documentHash: String
    private let store: PDFSentenceTranslationStore
    private let settings: ModelSettings
    private let client: ModelClient
    private let key: @Sendable () async throws -> String
    private var remaining: IndexSet
    private var partial: IndexSet = []
    private var priorityPage: Int?
    private var progress: PDFDocumentTranslationProgress
    private var isRunning = false

    public init(
        url: URL, documentHash: String, pageCount: Int, store: PDFSentenceTranslationStore,
        settings: ModelSettings, client: ModelClient, key: @escaping @Sendable () async throws -> String
    ) {
        self.url = url
        self.documentHash = documentHash
        self.store = store
        self.settings = settings
        self.client = client
        self.key = key
        progress = PDFDocumentTranslationProgress(pageCount: pageCount)
        remaining = IndexSet(integersIn: 0..<progress.pageCount)
    }

    /// Apply navigation at the next page boundary. Never interrupt an in-flight model request to reorder pages.
    public func prioritize(_ pageIndex: Int) {
        priorityPage = remaining.contains(pageIndex) ? pageIndex : nil
    }

    public func run(
        prioritizing pageIndex: Int,
        onProgress: @Sendable (PDFDocumentTranslationProgress) async -> Void,
        onUpdate: @Sendable (Int, [String: String]) async -> Void
    ) async throws {
        guard !isRunning else { throw ReaderError.message("全文翻译正在进行中。") }
        isRunning = true
        defer {
            isRunning = false
            progress.activePageIndex = nil
        }
        // Starting again after a full pass is an explicit retry of only unverified pages.
        if remaining.isEmpty, !partial.isEmpty {
            remaining = partial
            progress.processedPages -= partial.count
            partial.removeAll()
            progress.partialPages = 0
        }
        prioritize(pageIndex)
        while let index = priorityPage ?? remaining.first {
            try Task.checkCancellation()
            priorityPage = nil
            progress.activePageIndex = index
            await onProgress(progress)
            try Task.checkCancellation()
            // Capture only the sentence anchors. Release PDFKit objects and all rendered crops before awaiting I/O.
            let sentences = try autoreleasepool {
                try PDFSentenceExtractor.extractPage(url: url, pageIndex: index, includingIllustrations: true)
                    .paragraphSentences
            }
            if sentences.isEmpty {
                progress.skippedPages += 1
            } else {
                do {
                    try await store.translate(
                        documentHash: documentHash, sentences: sentences, settings: settings, client: client, key: key,
                        onUpdate: { values in await onUpdate(index, values) })
                } catch ReaderError.pdfTranslationIncomplete {
                    partial.insert(index)
                    progress.partialPages = partial.count
                }
            }
            remaining.remove(index)
            if priorityPage == index { priorityPage = nil }
            progress.processedPages += 1
        }
        progress.activePageIndex = nil
        await onProgress(progress)
    }
}
