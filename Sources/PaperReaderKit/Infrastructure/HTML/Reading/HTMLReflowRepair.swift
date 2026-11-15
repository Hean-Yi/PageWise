import Foundation
import PDFKit
import SwiftSoup

public struct HTMLReflowRepairResult: Sendable {
    public var paper: Paper
    public var changedKeys: Set<String>
    public var repairedPages: Int
}

extension HTMLReadingStore {
    /// Publishes a new document, preserving every unaffected section byte-for-byte.
    /// The caller must recheck annotation dependencies and commit before cleanup.
    public func repairPDFRegions(
        paper: Paper, root: URL, protectedKeys: Set<String>, discovery: (any PaperDiscovery)? = nil
    ) async throws -> HTMLReflowRepairResult {
        guard paper.previewPages.isEmpty, paper.translatedPages.isEmpty,
            let document = PDFDocument(url: root.appendingPathComponent(paper.originalPath))
        else { return HTMLReflowRepairResult(paper: paper, changedKeys: [], repairedPages: 0) }
        if protectedKeys.isEmpty, paper.translations.isEmpty, let discovery {
            let parsed = try await PDFImporter(root: root).importPDF(
                at: root.appendingPathComponent(paper.originalPath), preservingComplexPages: true, discovery: discovery)
            defer {
                try? FileManager.default.removeItem(
                    at: root.appendingPathComponent(parsed.originalPath).deletingLastPathComponent())
            }
            guard parsed.digest == paper.digest, parsed.canReflow else {
                return HTMLReflowRepairResult(paper: paper, changedKeys: [], repairedPages: 0)
            }
            var updated = paper
            updated.blocks = parsed.blocks
            updated.warnings = parsed.warnings
            updated.canReflow = parsed.canReflow
            updated.sourceURL = parsed.sourceURL ?? paper.sourceURL
            updated.htmlReading = nil
            updated.translatedBlockCount = 0
            updated.htmlReading = try prepareOriginal(paper: updated, root: root)
            for index in updated.blocks.indices { updated.blocks[index].richContent?.html = "" }
            let before = Set(paper.blocks.filter { $0.preservesSourcePage == true }.map(\.sourcePage))
            let after = Set(updated.blocks.filter { $0.preservesSourcePage == true }.map(\.sourcePage))
            return HTMLReflowRepairResult(
                paper: updated, changedKeys: Set(paper.blocks.map { $0.id.uuidString }),
                repairedPages: before.subtracting(after).count)
        }
        guard let artifact = paper.htmlReading, artifact.fullSource == true else {
            return HTMLReflowRepairResult(paper: paper, changedKeys: [], repairedPages: 0)
        }
        let old = try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8)
        let protectedPages = Set(
            paper.blocks.filter { protectedKeys.contains($0.id.uuidString) && $0.preservesSourcePage == true }.map(
                \.sourcePage))
        var replacements: [UUID: [TextBlock]] = [:]
        var repairedPages = Set<Int>()
        if paper.blocks.contains(where: { $0.hasImageFailure == true }), let discovery,
            let candidate = PDFSourceIdentity.arxivCandidate(document: document, title: paper.title)
        {
            do {
                if let source = try await discovery.structuredContent(candidate) {
                    for (key, block) in HTMLRepairAlignment.images(previous: paper.blocks, recovered: source)
                    where !protectedKeys.contains(key.uuidString) {
                        replacements[key] = [block]
                        repairedPages.insert(block.sourcePage)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the existing object when its source cannot be verified.
            }
        }
        var bibliographies = paper.blocks
        for index in bibliographies.indices where bibliographies[index].preservesSourcePage != true {
            let range = try Self.sectionRange(bibliographies[index].id, in: old)
            let section = String(old[range])
            guard section.contains("id=\"ref-bib.") || section.contains("id='ref-bib.") else { continue }
            let parsed = try SwiftSoup.parseBodyFragment(section)
            try parsed.select(".translation").remove()
            if let content = try parsed.select("section").first() {
                bibliographies[index].richContent = RichContent(
                    html: try content.html(), translationInput: "", mathematics: [:], mathDescriptions: [:])
            }
        }
        let restored = try PDFBibliographyRecovery.restore(in: bibliographies, document: document)
        for (index, block) in restored.enumerated() where block.text != paper.blocks[index].text {
            guard !protectedKeys.contains(block.id.uuidString) else { continue }
            replacements[block.id] = [block]
        }
        let hasSupplements = paper.blocks.contains { ($0.imageWarnings ?? []).contains { $0.contains("HTML 内容不完整") } }
        let margins = hasSupplements ? PDFTextCoverage.repeatedMargins(in: document) : []
        let corpus = PDFTextCoverage.normalized(
            paper.blocks.filter { $0.preservesSourcePage != true }.map {
                (replacements[$0.id] ?? [$0]).map(\.text).joined(separator: " ")
            }.joined(separator: " "))
        for block in paper.blocks where block.preservesSourcePage == true {
            try Task.checkCancellation()
            guard !protectedKeys.contains(block.id.uuidString), !protectedPages.contains(block.sourcePage),
                block.hasImageFailure != true,
                let page = document.page(at: block.sourcePage)
            else { continue }
            if (block.imageWarnings ?? []).contains(where: { $0.contains("HTML 内容不完整") }) {
                if PDFTextCoverage.covers(page, sourcePage: block.sourcePage, corpus: corpus, repeatedMargins: margins)
                {
                    replacements[block.id] = []
                    repairedPages.insert(block.sourcePage)
                }
                continue
            }
            if paper.blocks.contains(where: { $0.sourcePage == block.sourcePage && $0.hasImageFailure == true }) {
                continue
            }
            if repairedPages.contains(block.sourcePage) {
                replacements[block.id] = []
            } else if let recovered = try PDFRegionalReflow.recover(page, sourcePage: block.sourcePage) {
                replacements[block.id] = recovered
                repairedPages.insert(block.sourcePage)
            }
        }
        guard !replacements.isEmpty else {
            return HTMLReflowRepairResult(paper: paper, changedKeys: [], repairedPages: 0)
        }
        let blocks = paper.blocks.flatMap { replacements[$0.id] ?? [$0] }
        let generated = try append(
            paper.blocks.flatMap { replacements[$0.id] ?? [] }.map { BilingualBlock(block: $0, translation: nil) },
            to: nil, paper: paper, root: root, preparingOriginal: true)
        let generatedURL = root.appendingPathComponent(generated.relativePath)
        defer { try? FileManager.default.removeItem(at: generatedURL) }
        let new = try String(contentsOf: generatedURL, encoding: .utf8)
        var merged = old
        for block in paper.blocks {
            guard let replacement = replacements[block.id] else { continue }
            let range = try Self.sectionRange(block.id, in: merged)
            let markup = try replacement.map { String(new[try Self.sectionRange($0.id, in: new)]) }.joined()
            merged.replaceSubrange(range, with: markup)
        }
        let path = "Papers/\(paper.id.uuidString)/reading/document-\(UUID().uuidString).html"
        try Data(merged.utf8).write(to: root.appendingPathComponent(path), options: .withoutOverwriting)
        var updated = paper
        updated.blocks = blocks
        for index in updated.blocks.indices { updated.blocks[index].richContent?.html = "" }
        let remainingIDs = Set(blocks.map { $0.id.uuidString })
        updated.translations = paper.translations.filter { remainingIDs.contains($0.key) }
        updated.translatedBlockCount =
            blocks.prefix { block in
                block.preservesSourcePage == true || block.richContent?.requiresTranslation == false
                    || updated.translations[block.id.uuidString] != nil
            }.count
        var result = HTMLReadingArtifact(
            relativePath: path,
            sections: blocks.map {
                PageArtifact(id: $0.id, blockIDs: [$0.id], sourcePage: $0.sourcePage, relativePath: path)
            },
            assets: Array(Set(artifact.assets + generated.assets)).filter {
                merged.contains(URL(fileURLWithPath: $0).lastPathComponent)
            }.sorted())
        result.fullSource = true
        updated.htmlReading = result
        updated.canReflow = true
        updated.warnings = paper.warnings.filter { warning in
            !repairedPages.contains { warning.hasPrefix("第 \($0 + 1) 页保留原始版面") }
        }
        return HTMLReflowRepairResult(
            paper: updated, changedKeys: Set(replacements.keys.map(\.uuidString)), repairedPages: repairedPages.count)
    }

    static func sectionRange(_ id: UUID, in document: String) throws -> Range<String.Index> {
        guard let start = document.range(of: "<section id='block-\(id.uuidString)'"),
            let end = document.range(of: "</section>", range: start.upperBound..<document.endIndex)
        else { throw ReaderError.message("已发布内容结构不完整，保留原版式。") }
        return start.lowerBound..<end.upperBound
    }
}
