import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@Test @MainActor func trashRoundTripPreservesFilesAnchorsAndCurrentReadingAcrossRestart() async throws {
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
    let bookmark = try #require(reader.currentBookmarks.first)
    #expect(try await reader.readingNoteEvidence(query: "Quartz").map(\.readingNoteID) == [note.id])
    #expect(await reader.trashPaper(id))
    #expect(reader.paper == nil && reader.selectedPaperID == nil && reader.state.papers.isEmpty)
    #expect(reader.state.readingNotes.isEmpty && reader.state.highlights.isEmpty && reader.state.chats.isEmpty)
    #expect(reader.state.memories.isEmpty && reader.state.reading.isEmpty && reader.state.bookmarks.isEmpty)
    #expect(reader.state.workspace.isEmpty && reader.state.paperShelfIDs.isEmpty && reader.state.manualPaperIDs.isEmpty)
    #expect(try await reader.readingNoteEvidence(query: "Quartz").isEmpty)
    #expect(reader.state.trashedPapers.map(\.id) == [id])
    await reader.flushReadingPosition()

    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    let archived = try #require(reopened.state.trashedPapers.first)
    #expect(try Data(contentsOf: storedPDF) == original && archived.id == id)
    #expect(await reopened.restorePaper(id))
    let restored = try await reopened.store.load()
    #expect(restored.trashedPapers.isEmpty && restored.papers.map(\.id) == [id])
    #expect(restored.shelfID(for: id) == shelf && restored.manualPaperIDs == [id])
    #expect(restored.workspace[id.uuidString]?.position?.pageKey == "original-1")
    #expect(restored.workspace[id.uuidString]?.isFavorite == true)
    #expect(restored.readingNotes == [note] && restored.highlights == [mark] && restored.bookmarks == [bookmark])
    #expect(restored.chats.map(\.id) == [turn.id] && restored.memories.map(\.id) == [memory.id])
    #expect(!restored.reading.isEmpty && restored.reading.allSatisfy { $0.paperID == id && $0.end > $0.start })
    #expect(try await reopened.readingNoteEvidence(query: "Quartz").map(\.readingNoteID) == [note.id])
    #expect(await reopened.trashPaper(id))
    #expect(await !reopened.save(paperTrashChange: .restore(id, deletedAt: archived.deletedAt)))
    #expect(reopened.state.papers.isEmpty && reopened.state.trashedPapers.count == 1)
    #expect(await reopened.deleteShelf(shelf))
    #expect(await reopened.restorePaper(id))
    #expect(reopened.state.shelfID(for: id) == nil)
}

@Test @MainActor func failedPaperTrashLeavesTheReaderAndLibraryIntact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let pdf = root.appendingPathComponent("paper.pdf")
    try DemoPaper.write(to: pdf)
    let id = try #require(await reader.importURLs([pdf]).first)
    let saved = root.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: root, to: saved)
    defer { try? FileManager.default.moveItem(at: saved, to: root) }
    #expect(await !reader.trashPaper(id))
    #expect(reader.paper?.id == id && reader.state.trashedPapers.isEmpty)
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
func deletedPaperIgnoresLateChatOrMemoryEvenAfterImmediateRestore(delayMemory: Bool) async throws {
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
    #expect(await reader.trashPaper(id))
    #expect(await reader.restorePaper(id))
    await api.release()
    await answer.value
    #expect(reader.state.chats.count == (delayMemory ? 1 : 0))
    #expect(reader.state.memories.isEmpty)
    #expect(reader.assistantDraft == nil)
}
