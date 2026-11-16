import CryptoKit
import Foundation
import PDFKit

public struct ReflowEvidence: Sendable {
    public var blocks: [TextBlock]
    public var warnings: [String]
    public var nextPage: Int
    public var finished: Bool
    public init(blocks: [TextBlock], warnings: [String], nextPage: Int = 0, finished: Bool = true) {
        self.blocks = blocks
        self.warnings = warnings
        self.nextPage = nextPage
        self.finished = finished
    }
}

/// Reads the stored PDF directly. No discovery, duplicate import, or full-document layout pass.
public actor ReflowEvidenceExtractor {
    private var document: PDFDocument?
    private var loadedURL: URL?
    private var loadedDigest: String?
    public init() {}

    public func extractBatch(
        paper: Paper, root: URL, startingAt: Int, pageLimit: Int = 1,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> ReflowEvidence {
        try Task.checkCancellation()
        let url = root.appendingPathComponent(paper.originalPath)
        if document == nil || loadedURL != url || loadedDigest != paper.digest {
            onProgress("读取本地 PDF")
            let bytes = try Data(contentsOf: url)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == paper.digest else { throw ReaderError.message("原始文件内容已变化，未发布新版本。") }
            guard let opened = PDFDocument(data: bytes), !opened.isLocked, opened.pageCount == paper.pageCount else {
                throw ReaderError.message("无法读取原始 PDF，未发布新版本。")
            }
            guard opened.allowsCopying else { throw ReaderError.message("此 PDF 不允许文字提取，请查看原版。") }
            document = opened
            loadedURL = url
            loadedDigest = digest
        }
        guard let document, startingAt >= 0, startingAt <= document.pageCount, pageLimit > 0 else {
            throw ReaderError.message("PDF 提取进度无效。")
        }
        let end = min(document.pageCount, startingAt + min(pageLimit, 4))
        var blocks: [TextBlock] = []
        var warnings: [String] = []
        for index in startingAt..<end {
            try Task.checkCancellation()
            onProgress("提取 PDF 文字：第 \(index + 1) / \(document.pageCount) 页")
            guard let page = document.page(at: index) else { throw ReaderError.message("无法读取第 \(index + 1) 页。") }
            let result: ReflowEvidence = try autoreleasepool {
                if let native = try PDFRegionalReflow.recover(page, sourcePage: index, modelOrdering: true) {
                    return ReflowEvidence(blocks: native, warnings: [])
                }
                onProgress("设备端 OCR：第 \(index + 1) / \(document.pageCount) 页")
                do {
                    if let recovered = try PDFOCREvidence.recover(page, sourcePage: index, modelOrdering: true) {
                        return ReflowEvidence(blocks: recovered.blocks, warnings: [recovered.warning])
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    // A failed OCR page retains its original, while later pages can continue.
                }
                var original = TextBlock(sourcePage: index, text: page.string ?? "")
                original.preservesSourcePage = true
                return ReflowEvidence(
                    blocks: [original], warnings: ["第 \(index + 1) 页文字提取与 OCR 未能可靠分离内容，已保留原版。"])
            }
            blocks += result.blocks
            warnings += result.warnings
        }
        return ReflowEvidence(blocks: blocks, warnings: warnings, nextPage: end, finished: end == document.pageCount)
    }

    /// Batch consumers use extractBatch so translation can start before later pages are parsed.
    public func extract(paper: Paper, root: URL, onProgress: @escaping @Sendable (String) -> Void = { _ in })
        throws -> ReflowEvidence
    {
        var result = ReflowEvidence(blocks: [], warnings: [], finished: false)
        repeat {
            let batch = try extractBatch(paper: paper, root: root, startingAt: result.nextPage, onProgress: onProgress)
            result.blocks += batch.blocks
            result.warnings += batch.warnings
            result.nextPage = batch.nextPage
            result.finished = batch.finished
        } while !result.finished
        return result
    }
}
