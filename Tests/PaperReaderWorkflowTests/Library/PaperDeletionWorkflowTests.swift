import CryptoKit
import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@Test @MainActor func permanentDeletionRemovesOwnedFilesCachesAndNotesWithoutTouchingExternalPDF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let pdf = root.appendingPathComponent("original.pdf")
    try DemoPaper.write(to: pdf)
    let shelf = try #require(await reader.createShelf(name: "Evidence"))
    let id = try #require(await reader.importURLs([pdf], shelfID: shelf).first)
    let paper = try #require(reader.paper)
    let storedPDF = root.appendingPathComponent(paper.originalPath)
    let original = try Data(contentsOf: pdf)
    reader.recordVisiblePage(1)
    reader.toggleFavorite(id)
    reader.toggleBookmark()
    let mark = Highlight(paperID: id, pageKey: "original-1", pageIndex: 1, text: "Anchor", rects: [[1, 2, 3, 4]])
    let anchor = NoteAnchor(key: mark.pageKey, target: "pdf", text: "Anchor", start: 2, end: 8)
    let note = ReadingNote(
        paperID: id, contentVersion: paper.digest + ":original-0", anchors: [anchor], markdown: "Quartz evidence")
    let turn = ChatTurn(paperID: id, question: "Which detail?", selection: "", answer: "Quartz", evidence: [])
    let memory = MemoryItem(text: "Review quartz", sourceID: turn.id)
    reader.state.highlights = [mark]
    reader.state.readingNotes = [note]
    reader.state.chats = [turn]
    reader.state.memories = [memory]
    reader.state.manualPaperIDs = [id]
    #expect(!reader.currentBookmarks.isEmpty)
    let cacheKey = SHA256.hash(data: Data(paper.digest.utf8)).map { String(format: "%02x", $0) }.joined()
    let caches = ["PDFTranslations", "PaperAbstracts/v1"].map { root.appending(path: $0 + "/" + cacheKey) }
    for cache in caches {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("derived".utf8).write(to: cache.appending(path: "test"))
    }
    #expect(try await reader.readingNoteEvidence(query: "Quartz").map(\.readingNoteID) == [note.id])
    #expect(await reader.deletePaper(id))
    #expect(reader.paper == nil && reader.selectedPaperID == nil && reader.state.papers.isEmpty)
    #expect(reader.state.readingNotes.isEmpty && reader.state.highlights.isEmpty && reader.state.chats.isEmpty)
    #expect(reader.state.memories.isEmpty && reader.state.reading.isEmpty && reader.state.bookmarks.isEmpty)
    #expect(reader.state.workspace.isEmpty && reader.state.paperShelfIDs.isEmpty && reader.state.manualPaperIDs.isEmpty)
    #expect(try await reader.readingNoteEvidence(query: "Quartz").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: storedPDF.path))
    #expect(caches.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    #expect(try Data(contentsOf: pdf) == original)
    await reader.flushReadingPosition()

    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    #expect(reopened.state.papers.isEmpty && reopened.state.readingNotes.isEmpty)
    let fresh = try #require(await reopened.importURLs([pdf]).first)
    #expect(fresh != id && reopened.state.readingNotes.isEmpty && reopened.state.bookmarks.isEmpty)

}

@Test @MainActor func failedPermanentDeletionLeavesTheReaderAndLibraryIntact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let pdf = root.appendingPathComponent("paper.pdf")
    try DemoPaper.write(to: pdf)
    let id = try #require(await reader.importURLs([pdf]).first)
    let originalPath = try #require(reader.paper?.originalPath)
    let saved = root.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: root, to: saved)
    defer { try? FileManager.default.moveItem(at: saved, to: root) }
    #expect(await !reader.deletePaper(id))
    #expect(reader.paper?.id == id && FileManager.default.fileExists(atPath: saved.appending(path: originalPath).path))
    #expect(reader.message?.contains("保存失败") == true)
}

private actor DelayedPaperAnswer: HTTPTransport {
    let delayMemory: Bool
    private var gate: CheckedContinuation<Void, Never>?
    var waiting: Bool { gate != nil }

    init(delayMemory: Bool) { self.delayMemory = delayMemory }

    func release() {
        gate?.resume()
        gate = nil
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let input = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let stream = input["stream"] as? Bool == true
        if delayMemory != stream { await withCheckedContinuation { gate = $0 } }
        let text =
            stream
            ? #"data: {"choices":[{"delta":{"content":"Context [S1]"},"finish_reason":"stop"}]}"#
                + "\n\ndata: [DONE]\n\n"
            : #"{"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}]}"#
        return (
            Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test(arguments: [false, true]) @MainActor
func permanentDeletionIgnoresLateChatOrMemoryAfterReimport(delayMemory: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = DelayedPaperAnswer(delayMemory: delayMemory)
    let reader = try ReaderModel(root: root, client: ModelClient(transport: api), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let id = try #require(await reader.importURLs([pdf]).first)
    let answer = Task { await reader.ask("How is attention described?") }
    for _ in 0..<400 where await !api.waiting { try await Task.sleep(for: .milliseconds(5)) }
    try #require(await api.waiting)
    #expect(await reader.deletePaper(id))
    let fresh = try #require(await reader.importURLs([pdf]).first)
    #expect(fresh != id)
    await api.release()
    await answer.value
    #expect(reader.state.chats.isEmpty)
    #expect(reader.state.memories.isEmpty)
    #expect(reader.assistantDraft == nil)
}
