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
        // Previously retained structured evidence can be reused without another source download.
        var structured: [TextBlock]? =
            !paper.blocks.isEmpty && paper.blocks.allSatisfy { $0.richContent != nil && $0.preservesSourcePage != true }
            ? paper.blocks : nil
        let discovery = ArxivClient()
        if structured == nil, let identity = paper.sourceURL, let url = URL(string: identity),
            ["arxiv.org", "www.arxiv.org"].contains(url.host?.lowercased() ?? ""), url.path.hasPrefix("/abs/"),
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
        guard let document = PDFDocument(url: root.appendingPathComponent(paper.originalPath)), document.allowsCopying
        else { return ReflowEvidence(blocks: parsed.blocks, warnings: parsed.warnings) }
        var blocks: [TextBlock] = []
        var warnings = parsed.warnings
        var attemptedPages: Set<Int> = []
        var imageBytes = 0
        for block in parsed.blocks {
            try Task.checkCancellation()
            guard block.preservesSourcePage == true, let page = document.page(at: block.sourcePage),
                !attemptedPages.contains(block.sourcePage), attemptedPages.count < 40
            else {
                blocks.append(block)
                continue
            }
            attemptedPages.insert(block.sourcePage)
            onProgress("设备端 OCR：第 \(block.sourcePage + 1) / \(document.pageCount) 页")
            do {
                let recovered = try autoreleasepool { try PDFOCREvidence.recover(page, sourcePage: block.sourcePage) }
                if let recovered {
                    let bytes = recovered.blocks.reduce(0) { $0 + ($1.richContent?.html.utf8.count ?? 0) }
                    guard imageBytes + bytes <= 40_000_000 else {
                        blocks.append(block)
                        warnings.append("第 \(block.sourcePage + 1) 页超过 OCR 局部图像预算，已保留原版。")
                        continue
                    }
                    imageBytes += bytes
                    blocks += recovered.blocks
                    warnings.removeAll { $0.hasPrefix("第 \(block.sourcePage + 1) 页") }
                    warnings.append(recovered.warning)
                } else {
                    blocks.append(block)
                    warnings.append("第 \(block.sourcePage + 1) 页 OCR 未能可靠分离正文与对象，已保留原版。")
                }
            } catch is CancellationError { throw CancellationError() } catch {
                blocks.append(block)
                warnings.append("第 \(block.sourcePage + 1) 页本地 OCR 未完成，已保留原版。")
            }
        }
        if parsed.blocks.filter({ $0.preservesSourcePage == true }).count > attemptedPages.count {
            warnings.append("部分页面超出单次 OCR 的 40 页预算，已保留原版。")
        }
        return ReflowEvidence(blocks: blocks, warnings: warnings)
    }
}
