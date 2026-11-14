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

    public func importPDF(at url: URL, preservingComplexPages: Bool = false, structuredBlocks: [TextBlock]? = nil)
        throws -> Paper
    {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard url.isFileURL else { throw ReaderError.message("请选择本地 PDF 文件。") }
        let bytes = try Data(contentsOf: url)
        guard bytes.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil,
            let document = PDFDocument(data: bytes), document.pageCount > 0
        else { throw ReaderError.message("文件不是有效的 PDF，未导入。") }
        guard !document.isLocked else { throw ReaderError.message("PDF 已加密，请先在本地解锁后再导入。") }

        let analysis = try PDFProcessor.extract(from: document, preservingComplexPages: preservingComplexPages)
        let structured = structuredBlocks.flatMap { blocks -> [TextBlock]? in
            guard document.allowsCopying, !blocks.isEmpty, blocks.allSatisfy({ $0.richContent != nil }),
                (0..<document.pageCount).allSatisfy({
                    // PDFAnnotation.type is "Link"; the subtype raw value is "/Link".
                    document.page(at: $0)?.annotations.allSatisfy {
                        $0.type == String(PDFAnnotationSubtype.link.rawValue.dropFirst())
                    }
                        == true
                })
            else { return nil }
            let pageTexts = (0..<document.pageCount).map { Self.normalized(document.page(at: $0)?.string ?? "") }
            let mappedBlocks = blocks.map { block in
                var mapped = block
                let needle = Self.normalized(block.text)
                let matches = pageTexts.indices.filter { !needle.isEmpty && pageTexts[$0].contains(needle) }
                mapped.sourcePage = matches.count == 1 ? matches[0] : -1
                if block.hasImageFailure == true, mapped.sourcePage >= 0 {
                    mapped.preservesSourcePage = true
                    mapped.richContent = nil
                    mapped.imageWarnings = (mapped.imageWarnings ?? []) + ["此图已保留对应原 PDF 整页，可能包含相邻正文。"]
                }
                return mapped
            }
            // Compare ordinary words, excluding formula glyphs and short labels. A partial HTML
            // conversion must not replace a substantially more complete PDF.
            let htmlWords = Self.words(blocks.map(\.text).joined(separator: " "))
            let graphicLabels = blocks.compactMap { $0.richContent?.imageTextForCoverage }.map(Self.normalized)
            let retainedPages = Set(mappedBlocks.filter { $0.preservesSourcePage == true }.map(\.sourcePage))
            for index in 0..<document.pageCount {
                // The complete source page is already part of the reading result. Missing
                // image labels on this page must not reject unrelated structured content.
                if retainedPages.contains(index) { continue }
                let words = Self.words(document.page(at: index)?.string ?? "")
                // SVG exporters may outline letters and keep data-text glyph labels. These
                // labels can explain a PDF word without pretending to be ordered body text.
                let covered = words.filter { word in
                    htmlWords.contains(word) || graphicLabels.contains { $0.contains(Self.normalized(word)) }
                }
                if words.count >= 20, Double(covered.count) / Double(words.count) < 0.85 {
                    return nil
                }
            }
            return mappedBlocks
        }
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

        let metadataTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        return Paper(
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
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.filter { $0.count >= 4 }.map(String.init))
    }
}
