import CryptoKit
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test @MainActor func pdfImportPreservesOriginalAnnotationsAndDoesNotCreateReadingContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("source.pdf")
    try DemoPaper.write(to: input)
    let document = try #require(PDFDocument(url: input))
    document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Original fixture"]
    try #require(document.page(at: 0)).addAnnotation(
        PDFAnnotation(bounds: CGRect(x: 50, y: 100, width: 60, height: 20), forType: .highlight, withProperties: nil))
    #expect(document.write(to: input))
    let library = root.appendingPathComponent("library")
    let paper = try await PDFImporter(root: library).storeOriginal(at: input)
    #expect(paper.title == "Original fixture" && paper.pageCount == 2)
    #expect(!paper.canReflow && paper.blocks.isEmpty && paper.previewPages.isEmpty)
    #expect(paper.htmlReading == nil && paper.reflowJob == nil)
    let bytes = try Data(contentsOf: input)
    #expect(try Data(contentsOf: library.appendingPathComponent(paper.originalPath)) == bytes)
    #expect(paper.digest == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    let duplicate = try await PDFImporter(root: library).storeOriginal(at: input)
    #expect(duplicate.digest == paper.digest)
}

@Test func invalidPDFDoesNotCreateALibraryArtifact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("invalid.pdf")
    try Data("<html>download failed</html>".utf8).write(to: input)
    await #expect(throws: (any Error).self) { try await PDFImporter(root: root).storeOriginal(at: input) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Papers").path))
}
