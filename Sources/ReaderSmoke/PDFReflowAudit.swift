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
    }

    static func run(root: URL, report: URL) async throws {
        let state = try await LibraryStore(directory: root).load()
        var entries: [Entry] = []
        for paper in state.papers {
            let started = Date()
            let url = root.appendingPathComponent(paper.originalPath)
            let result = try PDFProcessor.extract(from: url, preservingComplexPages: true)
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
                characterMismatchPages: mismatch, seconds: Date().timeIntervalSince(started))
            entries.append(entry)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: report, options: .atomic)
            print(
                "\(entries.count)/\(state.papers.count) pages=\(entry.pages) retained=\(entry.retainedPages.count) prose=\(entry.textBlocks) crops=\(entry.croppedRegions) mismatch=\(mismatch.count) seconds=\(Int(entry.seconds)) \(paper.id)"
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
