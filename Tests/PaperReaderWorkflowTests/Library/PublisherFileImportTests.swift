import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

@MainActor struct PublisherFileImportTests {
    private let citation = PaperCandidate(
        id: "https://doi.org/10.1234/reader.fixture", title: "Publisher fixture", authors: "", year: "2025",
        source: .crossref, abstract: "A different abstract supplied by the selected bibliography entry.")

    @Test func selectedFileKeepsBibliographicLinkAndLocalPDFReadingAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let shelf = try #require(await reader.createShelf(name: "研究"))
        let url = root.appendingPathComponent("download.pdf")
        try AttentionFixture.write(to: url)
        let bytes = try Data(contentsOf: url)
        let id = try await reader.importPublisherPDF(url, for: citation, shelfID: shelf)
        #expect(reader.selectedPaperID == nil)
        let restored = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await restored.load()
        #expect(restored.importedPaperID(for: citation) == id)
        #expect(restored.state.shelfID(for: id) == shelf)
        restored.select(id)
        let paper = try #require(restored.paper)
        #expect(paper.title == citation.title && paper.linkedPublicationURLs == [citation.id])
        #expect(paper.onlineSource == nil && paper.sourceURL == nil && !paper.usesSourceReflow)
        #expect(await restored.previewContent(for: id).abstract?.hasPrefix("Attention is a way") == true)
        #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == bytes)
        #expect(restored.openBilingualReading(translatingDocument: false) && restored.pdfBilingual.isOpen)
        restored.pdfBilingual.close()
    }

    @Test func identicalLocalFileLinksMultipleIndexesWithoutOverwritingReadingOrChangingShelf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let shelf = try #require(await reader.createShelf(name: "已有书架"))
        let url = root.appendingPathComponent("original.pdf")
        try AttentionFixture.write(to: url)
        let id = try #require(await reader.importURLs([url], selectAfterImport: false, shelfID: shelf).first)
        let original = try #require(reader.state.papers.first)
        let reading = RetainedReading(paper: original)
        let mark = Highlight(
            paperID: id, pageKey: "original-0", pageIndex: 0, text: "Attention", rects: [[1, 2, 3, 4]])
        reader.state.highlights = [mark]
        reader.state.papers[0].retainedReadings = [reading]
        #expect(await reader.save())
        let copy = root.appendingPathComponent("different-name.pdf")
        try FileManager.default.copyItem(at: url, to: copy)
        let otherIndex = PaperCandidate(
            id: "https://dblp.org/rec/conf/fixture/2025", title: "Another index title", authors: "", year: "",
            source: .dblp)
        for record in [citation, otherIndex, citation] {
            #expect(try await reader.importPublisherPDF(copy, for: record) == id)
        }
        let restored = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await restored.load()
        let paper = try #require(restored.state.papers.first)
        #expect(restored.state.papers.count == 1)
        #expect(paper.linkedPublicationURLs == [citation.id, otherIndex.id])
        #expect(paper.title == original.title && paper.originalPath == original.originalPath)
        #expect(paper.retainedReadings?.first?.id == reading.id)
        #expect(restored.state.highlights == [mark])
        #expect(restored.state.shelfID(for: id) == shelf)
    }

    @Test func explicitReimportOfDeletedPDFCreatesAnIndependentPaperAndRejectsOlderDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let url = root.appendingPathComponent("sample.pdf")
        try AttentionFixture.write(to: url)
        let id = try await reader.importPublisherPDF(url, for: citation)
        let oldPaper = try #require(reader.state.papers.first)
        reader.state.highlights = [
            Highlight(paperID: id, pageKey: "original-0", pageIndex: 0, text: "Attention", rects: [[1, 2, 3, 4]])
        ]
        #expect(await reader.save())
        #expect(await reader.deletePaper(id))

        #expect(await reader.importURLs([url], requestedAt: .distantPast).isEmpty)
        let updatedPDF = root.appendingPathComponent("updated.pdf")
        try (Data(contentsOf: url) + Data("\n% updated\n".utf8)).write(to: updatedPDF)
        await #expect(throws: ReaderError.self) {
            try await reader.importPublisherPDF(updatedPDF, for: citation, requestedAt: .distantPast)
        }
        #expect(reader.state.papers.isEmpty && reader.state.highlights.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(oldPaper.originalPath).path))

        let destination = try #require(await reader.createShelf(name: "注意力"))
        let newID = try await reader.importPublisherPDF(url, for: citation, shelfID: destination)
        #expect(newID != id)
        let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reopened.load()
        #expect(reopened.state.papers.map(\.id) == [newID])
        #expect(reopened.state.shelfID(for: newID) == destination && reopened.importedPaperID(for: citation) == newID)
        #expect(reopened.state.highlights.isEmpty)
        let paper = try #require(reopened.state.papers.first)
        #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == Data(contentsOf: url))
    }

    @Test func distinctBytesWithEqualNamesSizesAndBibliographyStaySeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let url = root.appendingPathComponent("download.pdf")
        try AttentionFixture.write(to: url)
        let bytes = try Data(contentsOf: url)
        let endings = ["\n% A\n", "\n% B\n"]
        let shelves = [
            try #require(await reader.createShelf(name: "First")),
            try #require(await reader.createShelf(name: "Second")),
        ]
        var ids: [UUID] = []
        for (ending, shelf) in zip(endings, shelves) {
            try (bytes + Data(ending.utf8)).write(to: url)
            ids.append(try await reader.importPublisherPDF(url, for: citation, shelfID: shelf))
        }
        #expect(Set(ids).count == 2)
        for (id, ending) in zip(ids, endings) {
            let paper = try #require(reader.state.papers.first { $0.id == id })
            #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == bytes + Data(ending.utf8))
        }
        let restored = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await restored.load()
        let search = OnlinePaperSearch(reader: restored)
        for (id, shelf) in zip(ids, shelves) {
            search.open(shelfID: shelf)
            #expect(search.importedPaperID(for: citation) == id)
        }
    }

    @Test func downloadedResultCanUpgradeUserLinkedCopyAndReopenAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let url = root.appendingPathComponent("download.pdf")
        try AttentionFixture.write(to: url)
        let openRecord = PaperCandidate(
            id: "https://doi.org/10.18653/v1/2025.acl-long.12", title: "Publisher fixture", authors: "", year: "2025",
            source: .crossref)
        let id = try await reader.importPublisherPDF(url, for: openRecord)
        #expect(reader.importedPaperID(for: openRecord) == id)
        #expect(reader.importedPaperID(for: openRecord, includeUserLinked: false) == nil)
        #expect(await reader.importURLs([url], selectAfterImport: false, metadata: openRecord) == [id])
        let restored = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await restored.load()
        #expect(restored.importedPaperID(for: openRecord, includeUserLinked: false) == id)
        #expect(restored.state.papers.count == 1)
        #expect(restored.state.papers.first?.onlineSource?.candidateID == openRecord.id)
    }

    @Test func invalidCandidateFileCancelledImportAndMissingShelfDoNotPublishLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let incomplete = root.appendingPathComponent("login-page.pdf")
        try Data("<html>Sign in</html>".utf8).write(to: incomplete)
        await #expect(throws: ReaderError.self) { try await reader.importPublisherPDF(incomplete, for: citation) }
        let url = root.appendingPathComponent("download.pdf")
        try AttentionFixture.write(to: url)
        var invalid = citation
        invalid.id = "https://example.org/record"
        await #expect(throws: ReaderError.self) { try await reader.importPublisherPDF(url, for: invalid) }
        let task = Task { try await reader.importPublisherPDF(url, for: citation) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reader.state.papers.isEmpty && !reader.isImporting)
        let id = try #require(await reader.importURLs([url], selectAfterImport: false).first)
        await #expect(throws: (any Error).self) {
            try await reader.importPublisherPDF(url, for: citation, shelfID: UUID())
        }
        #expect(reader.importedPaperID(for: citation) == nil)
        let folders = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Papers"), includingPropertiesForKeys: nil)
        #expect(folders.map(\.lastPathComponent) == [id.uuidString])
        let restored = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await restored.load()
        #expect(restored.state.papers.map(\.id) == [id] && restored.importedPaperID(for: citation) == nil)
    }
}
