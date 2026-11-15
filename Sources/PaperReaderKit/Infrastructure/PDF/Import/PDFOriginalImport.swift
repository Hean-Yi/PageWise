import CryptoKit
import Foundation
import PDFKit

extension PDFImporter {
    /// Import performs no structure conversion, OCR, resource downloads or model requests.
    public func storeOriginal(at url: URL) throws -> Paper {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard url.isFileURL else { throw ReaderError.message("请选择本地 PDF 文件。") }
        let data = try Data(contentsOf: url)
        guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil,
            let document = PDFDocument(data: data), document.pageCount > 0, !document.isLocked
        else { throw ReaderError.message("无法读取 PDF，请先确认文件完整且已解锁。") }
        let id = UUID()
        let directory = root.appendingPathComponent("Papers", isDirectory: true)
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("original.pdf"), options: .withoutOverwriting)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        let metadata = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var paper = Paper(
            id: id, title: metadata.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent,
            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            originalPath: "Papers/\(id.uuidString)/original.pdf", pageCount: document.pageCount,
            blocks: [], warnings: [], canReflow: true)
        paper.deferredReflow = true
        return paper
    }
}
