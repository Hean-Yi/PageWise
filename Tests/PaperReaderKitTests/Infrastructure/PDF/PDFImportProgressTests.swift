import Foundation
import PDFKit
import Synchronization
import Testing

@testable import PaperReaderKit

@Test @MainActor func importProgressReportsCompletedPagesAndStructuredFastPath() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("source.pdf")
    try DemoPaper.write(to: input)
    let progress = Mutex<[PDFImportProgress]>([])
    let plain = try await PDFImporter(root: root).importPDF(at: input, preservingComplexPages: true) { value in
        progress.withLock { $0.append(value) }
    }
    let events = progress.withLock { $0 }
    #expect(events.map(\.sequence) == Array(1...events.count))
    #expect(events.contains { $0.stage == "解析 PDF 页面" && $0.completed == plain.pageCount && $0.fraction == 1 })
    #expect(events.last?.stage == "保存原始 PDF")
    let pdf = try #require(PDFDocument(url: input))
    let blocks = (0..<pdf.pageCount).map { index in
        let text = pdf.page(at: index)?.string ?? ""
        var block = TextBlock(sourcePage: index, text: text)
        block.richContent = RichContent(
            html: "<p>\(HTMLPaperParser.escape(text))</p>", translationInput: text,
            mathematics: [:], mathDescriptions: [:])
        return block
    }
    progress.withLock { $0 = [] }
    let structured = try await PDFImporter(root: root).importPDF(at: input, structuredBlocks: blocks) { value in
        progress.withLock { $0.append(value) }
    }
    #expect(structured.blocks.map(\.id) == blocks.map(\.id))
    let fastEvents = progress.withLock { $0 }
    #expect(!fastEvents.contains { $0.stage == "解析 PDF 页面" })
    #expect(fastEvents.contains { $0.stage == "核对原文覆盖" && $0.completed == pdf.pageCount })
    #expect(try Data(contentsOf: root.appendingPathComponent(structured.originalPath)) == Data(contentsOf: input))
}
