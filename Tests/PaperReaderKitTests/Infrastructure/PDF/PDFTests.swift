import CryptoKit
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func bundledReadingSampleHasSelectableEvidenceOnBothPages() throws {
    let file = try DemoPaper.fileURL()
    let document = try #require(PDFDocument(url: file))
    #expect(document.pageCount == 2)
    #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == DemoPaper.title)
    let abstract = try PDFAbstractExtractor.extract(url: file, pages: document.pageCount)
    #expect(abstract.sentences.first?.text.hasPrefix("A higher average can hide") == true)
    let first = try PDFSentenceExtractor.extractPage(url: file, pageIndex: 0, includingIllustrations: true)
    #expect(first.paragraphSentences.first?.text == DemoPaper.title)
    #expect(
        first.paragraphSentences.contains { $0.text == "Every fraction in the table is correct." && !$0.rects.isEmpty })
    let table = try #require(first.illustrations.first?.table)
    #expect(table.header == ["System", "Easy", "Hard", "All questions"])
    #expect(table.rows.map(\.last) == ["63 / 100 (63%)", "77 / 100 (77%)"])
    let second = try PDFSentenceExtractor.extractPage(url: file, pageIndex: 1, includingIllustrations: true)
    #expect(
        second.paragraphSentences.contains {
            $0.text == "Were the systems tested on the same cases?" && !$0.rects.isEmpty
        })
    #expect(second.illustrations.contains { $0.presentation == .illustration && $0.imagePNG != nil })
}

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

@Test func recoveryRemovesOnlyAbandonedImportsAndPreservesCommittedAndActiveOriginals() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let importer = PDFImporter(root: root)
    let input = try DemoPaper.fileURL()
    let orphan = try await importer.prepareOriginal(at: input).paper
    let committed = try await importer.prepareOriginal(at: input).paper
    let active = try await importer.prepareOriginal(at: input)
    let unmanaged = try await importer.storeOriginal(at: input)
    func exists(_ paper: Paper) -> Bool {
        manager.fileExists(atPath: root.appendingPathComponent(paper.originalPath).path)
    }
    try ReadingArtifactCleanup.removeUncommittedFiles(in: root, papers: [committed])
    #expect(!exists(orphan))
    #expect(exists(committed) && exists(unmanaged) && exists(active.paper))
    let directory = root.appendingPathComponent(committed.originalPath).deletingLastPathComponent()
    #expect(!manager.fileExists(atPath: PendingPDFImport.marker(in: directory, id: committed.id).path))
    active.discard()
    #expect(!exists(active.paper))
    try ReadingArtifactCleanup.removeUncommittedFiles(in: root, papers: [committed])
    #expect(exists(committed) && exists(unmanaged))
}

@Test func staleStartupCannotReclaimAnotherInstancesJustCommittedOriginal() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let early = try LibraryStore(directory: root)
    _ = try await early.load()
    let writer = try LibraryStore(directory: root)
    var current = try await writer.load()
    let pending = try await PDFImporter(root: root).prepareOriginal(at: DemoPaper.fileURL()).paper
    current.papers = [pending]
    try await writer.save(current)
    let file = root.appendingPathComponent(pending.originalPath)
    let marker = PendingPDFImport.marker(in: file.deletingLastPathComponent(), id: pending.id)
    try await early.recoverManagedFiles()
    #expect(manager.fileExists(atPath: file.path) && manager.fileExists(atPath: marker.path))
    try await writer.recoverManagedFiles()
    #expect(manager.fileExists(atPath: file.path) && !manager.fileExists(atPath: marker.path))
}
