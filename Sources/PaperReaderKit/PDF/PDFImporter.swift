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

    public func importPDF(at url: URL) throws -> Paper {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard url.isFileURL else { throw ReaderError.message("请选择本地 PDF 文件。") }
        let bytes = try Data(contentsOf: url)
        guard bytes.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil,
            let document = PDFDocument(data: bytes), document.pageCount > 0
        else { throw ReaderError.message("文件不是有效的 PDF，未导入。") }
        guard !document.isLocked else { throw ReaderError.message("PDF 已加密，请先在本地解锁后再导入。") }

        let analysis = try PDFProcessor.extract(from: document)
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
            blocks: analysis.blocks,
            warnings: analysis.warnings,
            canReflow: analysis.canReflow
        )
    }
}
