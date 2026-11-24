import CryptoKit
import Foundation

/// Holds only translations for immutable source anchors. The library's main snapshot need not be rewritten per sentence.
public actor PDFSentenceTranslationStore {
    private struct Page: Codable {
        var schema = 1
        var revisions: [String: [String: String]] = [:]
        var recent: [String] = []
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let directory: URL
    // An entry means a writer holds this page. Other pages can progress independently.
    private var waiters: [URL: [Waiter]] = [:]
    private var deletionGenerations: [String: UUID] = [:]

    public init(root: URL) {
        directory = root.appendingPathComponent("PDFTranslations", isDirectory: true)
    }

    public func invalidatePendingWrites(documentHash: String) {
        deletionGenerations[documentHash] = UUID()
    }

    func hasSavedPage(documentHash: String, among pages: Range<Int>) -> Bool {
        pages.contains { FileManager.default.fileExists(atPath: pageURL(documentHash: documentHash, page: $0).path) }
    }

    /// Opens an existing translation without credentials. Prefer the configured edition, then the latest saved one.
    public func cached(documentHash: String, sentences: [PDFSourceSentence], settings: ModelSettings? = nil) throws
        -> [String: String]
    {
        guard let first = sentences.first else { return [:] }
        let url = pageURL(documentHash: documentHash, page: first.pageIndex)
        let page = try read(url)
        let keys = try sourceKeys(sentences)
        let preferred = settings.flatMap { try? revision(for: $0) }
        for revision in [preferred].compactMap({ $0 }) + page.recent {
            let result = values(keys: keys, from: page.revisions[revision] ?? [:])
            if !result.isEmpty { return result }
        }
        return [:]
    }

    @discardableResult
    public func translate(
        documentHash: String, sentences: [PDFSourceSentence], settings: ModelSettings, client: ModelClient,
        key: @Sendable () async throws -> String,
        onUpdate: @Sendable ([String: String]) async -> Void = { _ in }
    ) async throws -> [String: String] {
        guard let first = sentences.first else { return [:] }
        let url = pageURL(documentHash: documentHash, page: first.pageIndex)
        let revision = try revision(for: settings)
        let keys = try sourceKeys(sentences)
        let generation = deletionGenerations[documentHash]
        try await acquire(url)
        defer { release(url) }
        try Task.checkCancellation()

        var page = try read(url)
        var stored = page.revisions[revision] ?? [:]
        var result = values(keys: keys, from: stored)
        let missing = sentences.filter { result[$0.id] == nil }
        guard !missing.isEmpty else {
            await onUpdate(result)
            return result
        }
        let eligible = missing.filter { $0.text.utf8.count <= 8_000 }
        guard !eligible.isEmpty else {
            throw ReaderError.pdfTranslationIncomplete("未译内容过长，无法可靠分句。可在原页选取较短的文字。")
        }
        try Task.checkCancellation()
        let credential = try await key()
        // After a complete first pass allow at most one corrective request for this page action.
        // Transport failures still pause immediately; individual bad sentences do not hide their neighbors.
        for corrective in [false, true] {
            let batches = batches(for: eligible.filter { result[$0.id] == nil })
            for batch in batches.prefix(corrective ? 1 : batches.count) {
                try Task.checkCancellation()
                let translations = try await client.translatePDFBatch(
                    batch, settings: settings, key: credential, corrective: corrective)
                try Task.checkCancellation()
                guard deletionGenerations[documentHash] == generation else { throw CancellationError() }
                guard !translations.isEmpty else { continue }
                for (id, translation) in translations {
                    if let sourceKey = keys[id] {
                        stored[sourceKey] = translation
                        result[id] = translation
                    }
                }
                page.revisions[revision] = stored
                page.recent.removeAll { $0 == revision }
                page.recent.insert(revision, at: 0)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(page).write(to: url, options: .atomic)
                await onUpdate(result)
            }
        }
        guard result.count == sentences.count else {
            throw ReaderError.pdfTranslationIncomplete(
                "已译 \(result.count) / \(sentences.count) 句。其余 \(sentences.count - result.count) 句未能核对，请参照原页；继续翻译仅重试未完成的句子。"
            )
        }
        return result
    }

    private func acquire(_ url: URL) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if waiters[url] == nil {
                    waiters[url] = []
                    continuation.resume()
                } else {
                    waiters[url, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, for: url) }
        }
    }

    private func cancelWaiter(_ id: UUID, for url: URL) {
        guard let index = waiters[url]?.firstIndex(where: { $0.id == id }) else { return }
        waiters[url]?.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ url: URL) {
        if waiters[url]?.isEmpty == false {
            waiters[url]?.removeFirst().continuation.resume()
        } else {
            waiters[url] = nil
        }
    }

    private func batches(for sentences: [PDFSourceSentence]) -> [[PDFSourceSentence]] {
        var result: [[PDFSourceSentence]] = []
        var batch: [PDFSourceSentence] = []
        var size = 0
        for sentence in sentences {
            let bytes = sentence.text.utf8.count
            // Keep adjacent sentences of a paragraph together when they fit; cap both input and expected output.
            let paragraphBreak = batch.last?.readingParagraphID != sentence.readingParagraphID
            if !batch.isEmpty, size + bytes > 3_200 || batch.count >= 10 || (paragraphBreak && size >= 1_100) {
                result.append(batch)
                batch = []
                size = 0
            }
            batch.append(sentence)
            size += bytes
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }

    private func revision(for settings: ModelSettings) throws -> String {
        let normalized = try settings.normalized()
        return digest(
            Data("pdf-sentence-v2\nzh-Hans\n\(normalized.baseURL)\n\(normalized.model)\n\(normalized.temperature)".utf8)
        )
    }

    private func sourceKeys(_ sentences: [PDFSourceSentence]) throws -> [String: String] {
        struct Signature: Encodable {
            let id: String
            let paragraph: String
            let text: String
            let rects: [[Double]]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var keys: [String: String] = [:]
        for sentence in sentences {
            guard sentence.pageIndex == sentences[0].pageIndex, keys[sentence.id] == nil, !sentence.text.isEmpty else {
                throw ReaderError.message("本页的原句定位不完整。")
            }
            // The same source sentence can move to a new display paragraph as layout detection improves.
            let signature = Signature(
                id: sentence.id, paragraph: sentence.paragraphID, text: sentence.text, rects: sentence.rects)
            keys[sentence.id] = digest(try encoder.encode(signature))
        }
        return keys
    }

    private func values(keys: [String: String], from stored: [String: String]) -> [String: String] {
        keys.compactMapValues { stored[$0] }
    }

    private func pageURL(documentHash: String, page: Int) -> URL {
        directory.appendingPathComponent(digest(Data(documentHash.utf8)), isDirectory: true)
            .appendingPathComponent("p\(page).json")
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ url: URL) throws -> Page {
        guard FileManager.default.fileExists(atPath: url.path) else { return Page() }
        let page = try JSONDecoder().decode(Page.self, from: Data(contentsOf: url))
        guard page.schema == 1 else { throw ReaderError.message("本机译文版本较新，请使用兼容的应用版本阅读。") }
        return page
    }
}
