import CryptoKit
import Foundation
import PDFKit

/// Copies a local PDF into the library before exposing any references to it.
/// Duplicate detection belongs to the library, using the returned SHA-256 digest.
public actor PDFImporter {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func importPDF(
        at url: URL, preservingComplexPages: Bool = false, structuredBlocks: [TextBlock]? = nil,
        discovery: (any PaperDiscovery)? = nil,
        onProgress: @Sendable (PDFImportProgress) -> Void = { _ in }
    )
        async throws -> Paper
    {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard url.isFileURL else { throw ReaderError.message("请选择本地 PDF 文件。") }
        var sequence = 0
        func report(_ stage: String, _ completed: Int = 0, _ total: Int? = nil) {
            sequence += 1
            onProgress(PDFImportProgress(sequence: sequence, stage: stage, completed: completed, total: total))
        }
        report("读取 PDF")
        let bytes = try Data(contentsOf: url)
        guard bytes.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil,
            let document = PDFDocument(data: bytes), document.pageCount > 0
        else { throw ReaderError.message("文件不是有效的 PDF，未导入。") }
        guard !document.isLocked else { throw ReaderError.message("PDF 已加密，请先在本地解锁后再导入。") }

        let metadataTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        var sourceBlocks = structuredBlocks
        var candidate: PaperCandidate?
        if sourceBlocks == nil, let discovery,
            let identified = PDFSourceIdentity.arxivCandidate(document: document, title: title)
        {
            candidate = identified
            report("读取同版本 arXiv HTML")
            do { sourceBlocks = try await discovery.structuredContent(identified) } catch is CancellationError {
                throw CancellationError()
            } catch { sourceBlocks = nil }
        }
        let structured = try sourceBlocks.flatMap { blocks -> [TextBlock]? in
            guard document.allowsCopying, !blocks.isEmpty, blocks.allSatisfy({ $0.richContent != nil }),
                (0..<document.pageCount).allSatisfy({
                    // PDFAnnotation.type is "Link"; the subtype raw value is "/Link".
                    document.page(at: $0)?.annotations.allSatisfy {
                        $0.type == String(PDFAnnotationSubtype.link.rawValue.dropFirst())
                    }
                        == true
                })
            else { return nil }
            let blocks = try PDFBibliographyRecovery.restore(in: blocks, document: document)
            let rawPageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
            let pageTexts = rawPageTexts.map(Self.normalized)
            var completedBlocks = 0
            report("检查正文与补全图片", 0, blocks.count)
            var richBytes = blocks.reduce(0) { $0 + ($1.richContent?.html.utf8.count ?? 0) }
            let mappedBlocks = try blocks.map { block in
                try Task.checkCancellation()
                defer {
                    completedBlocks += 1
                    report("检查正文与补全图片", completedBlocks, blocks.count)
                }
                var mapped = block
                let needle = Self.normalized(block.richContent?.figureCaption?.text ?? block.text)
                let matches = pageTexts.indices.filter { !needle.isEmpty && pageTexts[$0].contains(needle) }
                mapped.sourcePage = matches.count == 1 ? matches[0] : -1
                if matches.isEmpty, let caption = block.richContent?.figureCaption {
                    mapped.sourcePage = try PDFFigureCropper.captionPage(caption.text, in: document) ?? -1
                }
                if block.hasImageFailure == true, mapped.sourcePage < 0,
                    let text = block.richContent?.imageTextForCoverage
                {
                    mapped.sourcePage = Self.uniqueGraphicPage(text: text, pageTexts: pageTexts) ?? -1
                }
                if block.hasImageFailure == true, mapped.sourcePage >= 0 {
                    if let page = document.page(at: mapped.sourcePage) {
                        do {
                            if let recovered = try PDFFigureCropper.replacingFailedFigure(mapped, from: page) {
                                let proposedBytes =
                                    richBytes - (block.richContent?.html.utf8.count ?? 0)
                                    + (recovered.richContent?.html.utf8.count ?? 0)
                                if proposedBytes <= 100_000_000 {
                                    richBytes = proposedBytes
                                    return recovered
                                }
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // An undecodable crop keeps the original page below.
                        }
                    }
                    mapped.preservesSourcePage = true
                    mapped.richContent = nil
                    mapped.imageWarnings = (mapped.imageWarnings ?? []) + ["此图已保留对应原 PDF 整页，可能包含相邻正文。"]
                }
                return mapped
            }
            // Compare ordinary words, excluding formula glyphs and short labels. A partial HTML
            // conversion must not replace a substantially more complete PDF.
            let htmlWords = Self.words(mappedBlocks.map(\.text).joined(separator: " "))
            let graphicLabels = mappedBlocks.filter { $0.hasImageFailure != true }
                .compactMap { $0.richContent?.imageTextForCoverage }.map(Self.normalized)
            let retainedPages = Set(mappedBlocks.filter { $0.preservesSourcePage == true }.map(\.sourcePage))
            report("核对原文覆盖", 0, document.pageCount)
            var missingPages: [Int] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                defer { report("核对原文覆盖", index + 1, document.pageCount) }
                // The complete source page is already part of the reading result. Missing
                // image labels on this page must not reject unrelated structured content.
                if retainedPages.contains(index) { continue }
                let words = Self.words(rawPageTexts[index])
                // SVG exporters may outline letters and keep data-text glyph labels. These
                // labels can explain a PDF word without pretending to be ordered body text.
                let covered = words.filter { word in
                    htmlWords.contains(word) || graphicLabels.contains { $0.contains(Self.normalized(word)) }
                }
                if words.count >= 20, Double(covered.count) / Double(words.count) < 0.85 {
                    missingPages.append(index)
                }
            }
            // Never append a full PDF page alongside overlapping HTML. If coverage still
            // cannot be established, build one complete regional PDF reading result instead.
            if !missingPages.isEmpty || !retainedPages.isEmpty
                || mappedBlocks.contains(where: { $0.hasImageFailure == true })
            {
                return nil
            }
            return mappedBlocks
        }
        // Structured content already passed coverage checks; do not also perform PDF column analysis.
        let analysis =
            try structured == nil
            ? PDFProcessor.extract(from: document, preservingComplexPages: preservingComplexPages) { completed, total in
                report("解析 PDF 页面", completed, total)
            }
            : PDFProcessingResult(blocks: [], warnings: [], canReflow: true)
        report("保存原始 PDF")
        let id = UUID()
        let papersDirectory = root.appendingPathComponent("Papers", isDirectory: true)
        let staging = papersDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let destination = papersDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedPDF = staging.appendingPathComponent("original.pdf")
        try bytes.write(to: stagedPDF, options: .withoutOverwriting)
        try Task.checkCancellation()
        // Moving the complete directory makes the original visible as one file-system operation.
        try FileManager.default.moveItem(at: staging, to: destination)

        var paper = Paper(
            id: id,
            title: title,
            digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            originalPath: "Papers/\(id.uuidString)/original.pdf",
            pageCount: document.pageCount,
            blocks: structured ?? analysis.blocks,
            warnings: structured == nil
                ? analysis.warnings
                : (structured!.contains { $0.sourcePage < 0 } ? ["部分 HTML 内容尚未匹配原文页码；可定位重排内容，查看原版时请核对。"] : [])
                    + Array(Set(structured!.flatMap { $0.imageWarnings ?? [] })).sorted(),
            canReflow: structured != nil || analysis.canReflow
        )
        if structured != nil { paper.sourceURL = candidate?.id }
        return paper
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func uniqueGraphicPage(text: String, pageTexts: [String]) -> Int? {
        let characters = Array(normalized(text).prefix(20_000))
        guard characters.count >= 160 else { return nil }
        var hits: [Int: Int] = [:]
        for offset in stride(from: 0, through: characters.count - 80, by: 80) {
            let fragment = String(characters[offset..<offset + 80])
            let matches = pageTexts.indices.filter { pageTexts[$0].contains(fragment) }
            if matches.count == 1 { hits[matches[0], default: 0] += 1 }
        }
        // Two independent long matches on exactly one page; never guess across pages.
        guard hits.count == 1, let hit = hits.first, hit.value >= 2 else { return nil }
        return hit.key
    }
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.filter { $0.count >= 4 }.map(String.init))
    }
}
