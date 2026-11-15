import Foundation
import PDFKit

public struct ReflowEvidence: Sendable {
    public var blocks: [TextBlock]
    public var warnings: [String]
    public init(blocks: [TextBlock], warnings: [String]) {
        self.blocks = blocks
        self.warnings = warnings
    }
}

/// Runs only after the reader explicitly asks to generate a bilingual edition.
public actor ReflowEvidenceExtractor {
    public init() {}
    public func extract(paper: Paper, root: URL, onProgress: @escaping @Sendable (String) -> Void = { _ in })
        async throws -> ReflowEvidence
    {
        onProgress("读取原始论文")
        let importer = PDFImporter(root: root)
        var structured: [TextBlock]?
        let discovery = ArxivClient()
        if let identity = paper.sourceURL, let url = URL(string: identity), url.path.hasPrefix("/abs/"),
            let pdfURL = URL(string: "https://arxiv.org/pdf/" + url.path.dropFirst(5))
        {
            let candidate = PaperCandidate(id: identity, title: paper.title, authors: "", year: "", pdfURL: pdfURL)
            onProgress("读取同版本结构化原文")
            do { structured = try await discovery.structuredContent(candidate) } catch is CancellationError {
                throw CancellationError()
            } catch { structured = nil }
        }
        let parsed = try await importer.importPDF(
            at: root.appendingPathComponent(paper.originalPath), preservingComplexPages: true,
            structuredBlocks: structured, discovery: discovery
        ) { progress in onProgress(progress.stage) }
        defer {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent(parsed.originalPath).deletingLastPathComponent())
        }
        guard parsed.digest == paper.digest else { throw ReaderError.message("原始文件内容已变化，未发布新版本。") }
        return ReflowEvidence(blocks: parsed.blocks, warnings: parsed.warnings)
    }
}
