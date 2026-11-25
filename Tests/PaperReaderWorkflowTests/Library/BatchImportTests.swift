import Foundation
import PDFKit
import PaperReaderKit
import PaperReaderTestSupport
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

@MainActor @Test(arguments: [false, true])
func importStoresThePDFAbstractBeforeFirstPreviewAndReusesItOnDuplicate(downloaded: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let url = try batchFixture(named: "Abstract fixture.pdf", in: root)
    // This download result has no abstract in its metadata. Both origins must read the PDF during import.
    let record = PaperCandidate(
        id: "https://doi.org/10.18653/v1/2025.acl-long.12", title: "Abstract fixture", authors: "", year: "2025",
        source: .crossref)
    let id = try #require(
        await reader.importURLs([url], selectAfterImport: false, metadata: downloaded ? record : nil).first)
    let stored = try #require(reader.state.papers.first)
    try FileManager.default.moveItem(
        at: root.appendingPathComponent(stored.originalPath), to: root.appendingPathComponent("held-aside.pdf"))
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    let preview = await reopened.previewContent(for: id)
    #expect(preview.abstract?.hasPrefix("Attention is a way") == true)
    #expect(preview.abstract?.hasSuffix("interpreted carefully.") == true)
    #expect(await reopened.importURLs([url], selectAfterImport: false, metadata: downloaded ? record : nil) == [id])
    #expect(await reopened.previewContent(for: id).abstract == preview.abstract)
    #expect(reopened.state.papers.count == 1 && reopened.selectedPaperID == nil)
}

@MainActor @Test(arguments: [false, true])
func repeatedDownloadFillsMissingSameEditionAbstractAndKeepsIt(hasArchive: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let url = try batchFixture(named: "Pinned fixture.pdf", in: root)
    var record = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Pinned fixture", authors: "", year: "2024",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1"))
    let tex = Data(#"\documentclass{article}\begin{document}Fixture\end{document}"#.utf8)
    let first = DownloadedPublication(pdfURL: url, candidate: record, texArchive: hasArchive ? tex : nil)
    let id = try #require(
        await reader.importURLs([url], selectAfterImport: false, metadata: record, onlineDownload: first).first)
    let abstract = "This edition compares two measures of attention."
    record.abstractText = abstract
    #expect(await reader.importURLs([url], selectAfterImport: false, metadata: record) == [id])
    record.abstractText = "Later, conflicting index text."
    #expect(await reader.importURLs([url], selectAfterImport: false, metadata: record) == [id])
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    let source = try #require(reopened.state.papers.first?.onlineSource)
    #expect(source.abstractText == abstract)
    #expect((source.archivePath != nil) == hasArchive)
    #expect(reopened.state.papers.map(\.id) == [id])
}

@MainActor @Test func importChecksNormalizedTitlesForLocalAndOnlinePDFsAndContinuesTheBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let first = try batchFixture(named: "C++ Methods.pdf", in: root)
    let duplicate = try batchFixture(named: "Ｃ++   METHODS.pdf", in: root)
    let distinct = try batchFixture(named: "C Methods.pdf", in: root)
    let ids = await reader.importURLs([first, duplicate, distinct], selectAfterImport: false)
    #expect(ids.count == 2)
    #expect(reader.message?.contains("同名论文") == true)
    let record = PaperCandidate(
        id: "https://doi.org/10.18653/v1/2025.acl-long.12", title: "c++ methods", authors: "", year: "2025",
        source: .crossref)
    #expect(await reader.importURLs([duplicate], selectAfterImport: false, metadata: record).isEmpty)
    #expect(reader.importedPaperID(for: record) == nil)
    #expect(Set(reader.state.papers.map(\.title)) == ["C++ Methods", "C Methods"])
    #expect(reader.state.papers.allSatisfy { $0.onlineSource == nil })
}

@MainActor @Test func walkthroughOpensItsOwnPDFWhenAnotherPaperSharesTheTitle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let other = try batchFixture(named: DemoPaper.title + ".pdf", in: root)
    let otherID = try #require(await reader.importURLs([other]).first)
    let sample = try #require(await reader.openBundledSample())
    #expect(sample != otherID && reader.paper?.title == DemoPaper.title + "（内置示例）")
    #expect(await reader.openBundledSample() == sample)
    #expect(reader.state.papers.count == 2)
}

/// Distinct metadata gives each original teaching fixture a distinct digest, without network material.
@MainActor private func batchFixture(named name: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(name)
    try AttentionFixture.write(to: url)
    let document = try #require(PDFDocument(url: url))
    var attributes = document.documentAttributes ?? [:]
    attributes[PDFDocumentAttribute.titleAttribute] = url.deletingPathExtension().lastPathComponent
    document.documentAttributes = attributes
    #expect(document.write(to: url))
    return url
}
