import Foundation
import PDFKit
import PaperReaderKit
import PaperReaderUI
import Testing

@MainActor @Test func multiplePDFsInOneImportPreserveOriginalsWithoutReflowAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let urls = try ["First.pdf", "Second.PDF", "Third.pdf"].map {
        try batchFixture(named: $0, in: root)
    }
    let originals = try urls.map { try Data(contentsOf: $0) }

    // The drop destination passes its complete URL array to this same entry point.
    let ids = await model.importURLs(urls)
    #expect(ids.count == 3)
    #expect(Set(ids).count == 3)
    #expect(model.state.papers.count == 3)
    #expect(!model.isImporting)
    #expect(model.message == nil)

    for (index, id) in ids.enumerated() {
        let paper = try #require(model.state.papers.first { $0.id == id })
        #expect(!paper.canReflow && paper.blocks.isEmpty && paper.htmlReading == nil)
        #expect(paper.previewPages.isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == originals[index])
        #expect(try Data(contentsOf: urls[index]) == originals[index])
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Papers/\(paper.id.uuidString)/preview").path))
    }

    let reopened = try ReaderModel(root: root)
    await reopened.load()
    #expect(Set(reopened.state.papers.map(\.id)) == Set(ids))
    #expect(reopened.state.papers.allSatisfy { $0.previewPages.isEmpty })
}

@MainActor @Test func batchImportContinuesPastBrokenPDFAndDeduplicatesCopies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root)
    await model.load()
    let first = try batchFixture(named: "First.pdf", in: root)
    let last = try batchFixture(named: "Last.pdf", in: root)
    let copy = root.appendingPathComponent("Copy.pdf")
    try FileManager.default.copyItem(at: first, to: copy)
    let broken = root.appendingPathComponent("Broken.pdf")
    try Data("This is deliberately not a PDF.".utf8).write(to: broken)

    let ids = await model.importURLs([first, broken, copy, last])
    #expect(ids.count == 3)
    #expect(ids.first == ids.dropFirst().first)
    #expect(Set(ids).count == 2)
    #expect(model.state.papers.count == 2)
    #expect(model.state.papers.contains { $0.title == "Last" && $0.previewPages.isEmpty })
    #expect(model.message?.contains("导入失败") == true)
    #expect(!model.isImporting)

    let folders = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("Papers"), includingPropertiesForKeys: nil)
    #expect(Set(folders.map(\.lastPathComponent)) == Set(model.state.papers.map { $0.id.uuidString }))
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    #expect(Set(reopened.state.papers.map(\.id)) == Set(ids))
}

/// Distinct metadata gives each original teaching fixture a distinct digest, without network material.
@MainActor private func batchFixture(named name: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(name)
    try DemoPaper.write(to: url)
    let document = try #require(PDFDocument(url: url))
    var attributes = document.documentAttributes ?? [:]
    attributes[PDFDocumentAttribute.titleAttribute] = url.deletingPathExtension().lastPathComponent
    document.documentAttributes = attributes
    #expect(document.write(to: url))
    return url
}
