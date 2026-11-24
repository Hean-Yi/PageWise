import CryptoKit
import Foundation

/// An empty parts array records a completed search. Sentences keep the original translation-cache signatures.
struct PDFAbstractRecord: Codable, Sendable {
    let parts: [AbstractPassage.Part]
    let sentences: [PDFSourceSentence]
}

actor PaperAbstractStore {
    enum Source: Hashable, Sendable {
        case pdf(digest: String)
        case publication(digest: String, revision: String)
        var digest: String {
            switch self {
            case .pdf(let digest), .publication(let digest, _): digest
            }
        }
    }

    private let directory: URL
    private var pending: [Source: (id: UUID, task: Task<PDFAbstractRecord, any Error>)] = [:]
    private var deletedPaperIDs: Set<UUID> = []
    private var unsaved: [(source: Source, record: PDFAbstractRecord)] = []

    init(root: URL) {
        // A new recognizer or incompatible anchor format gets a new directory, including for negative results.
        directory = root.appending(path: "PaperAbstracts/v1", directoryHint: .isDirectory)
    }

    func cached(_ source: Source) throws -> PDFAbstractRecord? {
        if let recent = unsaved.first(where: { $0.source == source }) { return recent.record }
        return try read(at: fileURL(for: source))
    }

    func discard(paperID: UUID, digest: String) {
        deletedPaperIDs.insert(paperID)
        for source in pending.keys where source.digest == digest { pending.removeValue(forKey: source)?.task.cancel() }
        unsaved.removeAll { $0.source.digest == digest }
    }

    func record(
        for source: Source, paperID: UUID? = nil, extract: @escaping @Sendable () async throws -> PDFAbstractRecord
    ) async throws
        -> PDFAbstractRecord
    {
        try Task.checkCancellation()
        if let paperID, deletedPaperIDs.contains(paperID) { throw CancellationError() }
        let work: Task<PDFAbstractRecord, any Error>
        if let active = pending[source] {
            work = active.task
        } else {
            let url = fileURL(for: source)
            if let recent = unsaved.first(where: { $0.source == source }) {
                persist(recent.record, for: source, at: url)
                return recent.record
            }
            if let saved = try? read(at: url) { return saved }
            let token = UUID()
            work = Task {
                defer { if pending[source]?.id == token { pending[source] = nil } }
                let result = try await extract()
                try Task.checkCancellation()
                persist(result, for: source, at: url)
                return result
            }
            pending[source] = (token, work)
        }
        // The import/backfill may still need this result if a reader dismisses the preview.
        let result = try await work.value
        try Task.checkCancellation()
        return result
    }

    private func persist(_ record: PDFAbstractRecord, for source: Source, at url: URL) {
        unsaved.removeAll { $0.source == source }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
        } catch {
            // Keep a small working set when disk space or file protection temporarily prevents caching.
            unsaved.append((source, record))
            if unsaved.count > 32 { unsaved.removeFirst() }
        }
    }

    private func read(at url: URL) throws -> PDFAbstractRecord? {
        do {
            return try JSONDecoder().decode(PDFAbstractRecord.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch is DecodingError {
            // This index is derived from the immutable source. A successful recognition safely replaces a damaged entry.
            return nil
        }
    }

    private func fileURL(for source: Source) -> URL {
        let digest: String
        let filename: String
        switch source {
        case .pdf(let hash):
            digest = hash
            filename = "pdf.json"
        case .publication(let hash, let revision):
            digest = hash
            filename = "publication-" + hashComponent(revision) + ".json"
        }
        return directory.appendingPathComponent(hashComponent(digest), isDirectory: true).appendingPathComponent(
            filename)
    }

    private func hashComponent(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
