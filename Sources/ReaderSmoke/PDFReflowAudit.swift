import CryptoKit
import Foundation
import PDFKit
import PaperReaderKit

/// Explicit, read-only library audit. Reports stay at the caller's chosen local path.
enum PDFReflowAudit {
    struct Entry: Codable {
        let id: UUID
        let title: String
        let pages: Int
        let previousRetainedPages: Int
        let retainedPages: [Int]
        let croppedRegions: Int
        let textBlocks: Int
        let characterMismatchPages: [Int]
        let seconds: Double
        let firstPageSeconds: Double?
    }

    static func run(root: URL, report: URL, modelEvidence: Bool = false) async throws {
        let root = root.standardizedFileURL
        let papers: [Paper]
        if modelEvidence {
            // Inspect copied originals without opening, migrating, or saving any library database.
            guard
                let files = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
            else { throw ReaderError.message("无法读取样本目录。") }
            var samples: [Paper] = []
            for file in (files.allObjects as? [URL] ?? []) where file.lastPathComponent == "original.pdf" {
                let bytes = try Data(contentsOf: file)
                guard let document = PDFDocument(data: bytes) else { throw ReaderError.message("样本 PDF 无法读取。") }
                samples.append(
                    Paper(
                        title: file.deletingLastPathComponent().lastPathComponent,
                        digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                        originalPath: String(file.path.dropFirst(root.path.count + 1)), pageCount: document.pageCount,
                        blocks: [], warnings: [], canReflow: true))
            }
            guard !samples.isEmpty else { throw ReaderError.message("样本目录内没有 original.pdf。") }
            papers = samples.sorted { $0.originalPath < $1.originalPath }
        } else {
            papers = try await LibraryStore(directory: root).load().papers
        }
        var entries: [Entry] = []
        for paper in papers {
            let started = Date()
            let url = root.appendingPathComponent(paper.originalPath)
            let result: (blocks: [TextBlock], warnings: [String])
            var firstPageSeconds: Double?
            if modelEvidence {
                let extractor = ReflowEvidenceExtractor()
                let first = try await extractor.extractBatch(paper: paper, root: root, startingAt: 0)
                firstPageSeconds = Date().timeIntervalSince(started)
                var blocks = first.blocks
                var warnings = first.warnings
                var next = first.nextPage
                while next < paper.pageCount {
                    let batch = try await extractor.extractBatch(paper: paper, root: root, startingAt: next)
                    blocks += batch.blocks
                    warnings += batch.warnings
                    next = batch.nextPage
                }
                result = (blocks, warnings)
            } else {
                let parsed = try PDFProcessor.extract(from: url, preservingComplexPages: true)
                result = (parsed.blocks, parsed.warnings)
            }
            guard let document = PDFDocument(url: url) else { throw ReaderError.message("原文无法读取") }
            let grouped = Dictionary(grouping: result.blocks, by: \.sourcePage)
            let mismatch = (0..<document.pageCount).filter { index in
                counts(document.page(at: index)?.string ?? "") != counts((grouped[index] ?? []).map(\.text).joined())
            }.map { $0 + 1 }
            let entry = Entry(
                id: paper.id, title: paper.title, pages: paper.pageCount,
                previousRetainedPages: Set(paper.blocks.filter { $0.preservesSourcePage == true }.map(\.sourcePage))
                    .count,
                retainedPages: result.blocks.filter { $0.preservesSourcePage == true }.map { $0.sourcePage + 1 },
                croppedRegions: result.blocks.filter { $0.richContent?.isFigure == true }.count,
                textBlocks: result.blocks.filter { $0.preservesSourcePage != true && $0.richContent?.isFigure != true }
                    .count,
                characterMismatchPages: mismatch, seconds: Date().timeIntervalSince(started),
                firstPageSeconds: firstPageSeconds)
            entries.append(entry)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: report, options: .atomic)
            print(
                "\(entries.count)/\(papers.count) pages=\(entry.pages) retained=\(entry.retainedPages.count) prose=\(entry.textBlocks) crops=\(entry.croppedRegions) mismatch=\(mismatch.count) seconds=\(Int(entry.seconds)) \(paper.id)"
            )
        }
    }

    private static func counts(_ text: String) -> [UInt32: Int] {
        var counts: [UInt32: Int] = [:]
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            counts[scalar.value, default: 0] += 1
        }
        return counts
    }
}
