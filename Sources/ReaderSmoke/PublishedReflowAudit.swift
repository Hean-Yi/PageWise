import CryptoKit
import Foundation
import PaperReaderKit
import SwiftSoup

/// Read-only integrity checks of the files the app actually opens, not prospective extraction output.
enum PublishedReflowAudit {
    struct Entry: Codable {
        var id: UUID
        var title: String
        var pages: Int
        var blocks: Int
        var originalDigestMatches: Bool
        var fullPageFigures: Int
        var unresolvedImages: Int
        var images: Int
        var mathElements: Int
        var tables: Int
        var missingFiles: [String]
        var duplicateSectionKeys: [String]
        var missingInternalTargets: [String]
        var textHeavyCropsToReview: Int
        var warnings: [String]
    }

    static func run(root: URL, report: URL) async throws {
        let state = try await LibraryStore(directory: root).load()
        var entries: [Entry] = []
        for paper in state.papers {
            let original = try Data(contentsOf: root.appendingPathComponent(paper.originalPath))
            var entry = Entry(
                id: paper.id, title: paper.title, pages: paper.pageCount, blocks: paper.blocks.count,
                originalDigestMatches: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
                    == paper.digest,
                fullPageFigures: 0, unresolvedImages: 0, images: 0, mathElements: 0, tables: 0,
                missingFiles: [], duplicateSectionKeys: [], missingInternalTargets: [], textHeavyCropsToReview: 0,
                warnings: paper.warnings)
            if let artifact = paper.htmlReading {
                let url = root.appendingPathComponent(artifact.relativePath)
                let document = try SwiftSoup.parse(String(contentsOf: url, encoding: .utf8))
                entry.missingFiles = (artifact.assets + [artifact.relativePath]).filter {
                    !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                }
                entry.fullPageFigures = try document.select("figure.source-page").count
                entry.unresolvedImages = paper.blocks.filter { $0.hasImageFailure == true }.count
                entry.images = try document.select("img").count
                entry.mathElements = try document.select("math").count
                entry.tables = try document.select("table").count
                let sections = try document.select("#reader > section[data-key]").map { try $0.attr("data-key") }
                entry.duplicateSectionKeys = Dictionary(grouping: sections, by: { $0 }).filter { $0.value.count > 1 }
                    .keys.sorted()
                let ids = Set(try document.select("[id]").map { try $0.attr("id") })
                entry.missingInternalTargets = Array(
                    Set(
                        try document.select("a[href^=#]").map {
                            String(try $0.attr("href").dropFirst()).removingPercentEncoding ?? ""
                        }.filter { !$0.isEmpty && !ids.contains($0) })
                ).sorted()
                for block in paper.blocks where block.text.count > 500 {
                    if let section = try document.getElementById("block-" + block.id.uuidString),
                        !(try section.select("figure.pdf-region").isEmpty())
                    {
                        entry.textHeavyCropsToReview += 1
                    }
                }
            } else {
                entry.missingFiles.append("HTML reading artifact")
            }
            entries.append(entry)
            print(
                "published \(entries.count)/\(state.papers.count) retained=\(entry.fullPageFigures) missing=\(entry.missingFiles.count) images=\(entry.images) unresolved=\(entry.unresolvedImages) math=\(entry.mathElements) links=\(entry.missingInternalTargets.count) \(paper.id)"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: report, options: .atomic)
    }
}
