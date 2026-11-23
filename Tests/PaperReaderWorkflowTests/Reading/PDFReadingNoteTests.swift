import Foundation
import PDFKit
import PaperReaderKit
import Testing
import WebKit

@testable import PaperReaderUI

@Test @MainActor func manualPDFNotesShareTheAgentAnchorAndSurviveEditsDeletionAndReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let file = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: file)
    let data = try Data(contentsOf: file)
    let id = try #require(await reader.importURLs([file]).first)
    let document = try #require(PDFDocument(url: file))
    defer { withExtendedLifetime(document) {} }
    let quote = "Multiple attention heads"
    let raw = try #require(document.page(at: 1)?.string as NSString?)
    let range = raw.range(of: quote)
    reader.captureSelection(text: quote, rects: [], page: 1, ranges: [range])
    let canvas = PDFCanvas(model: reader, penEnabled: false)
    let coordinator = PDFCoordinator(model: reader)
    let original = coordinator.makeView()
    coordinator.update(original, penEnabled: false, focus: canvas.sentenceDisplay)
    await reader.beginPDFReadingNote()
    let draft = try #require(reader.pdfNoteEditor)
    #expect(reader.currentReadingNotes.isEmpty && reader.state.highlights.isEmpty)
    let agent = try await PDFReadingNoteLocator().locate(quote: quote, pageIndex: 1, in: file)
    #expect(draft.note.anchors == agent.map(\.anchor))
    #expect(reader.updateReadingNote(id: draft.id, anchors: draft.note.anchors, markdown: "**观点** $x$"))
    #expect(reader.updateReadingNote(id: draft.id, anchors: draft.note.anchors, markdown: "**更新** $x^2$"))
    coordinator.update(original, penEnabled: false, focus: canvas.sentenceDisplay)
    let originalPage = try #require(original.document?.page(at: 1))
    #expect(originalPage.annotations.contains { $0.type == "Underline" })
    await reader.flushReadingNotes()
    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    reopened.select(id)
    let note = try #require(reopened.currentReadingNotes.first)
    #expect(note.id == draft.id && note.markdown == "**更新** $x^2$")
    #expect(reopened.state.highlights.count == 1 && reopened.state.highlights.first?.rects == agent.first?.rects)
    reopened.openReadingNote(note)
    #expect(reopened.pdfNoteEditor?.id == note.id && reopened.jumpPage == 1 && reopened.mode == "original")
    reopened.deleteReadingNote(note.id)
    #expect(reopened.currentReadingNotes.isEmpty)
    #expect(!reopened.updateReadingNote(id: note.id, anchors: note.anchors, markdown: "stale"))
    reopened.undoReadingNoteDeletion()
    await reopened.flushReadingNotes()
    #expect(reopened.currentReadingNotes == [note])
    let originalPath = try #require(reopened.paper?.originalPath)
    #expect(try Data(contentsOf: root.appendingPathComponent(originalPath)) == data)
}

@Test @MainActor func pdfNoteCardUsesTheBundledMarkdownAndFormulaEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let url = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: url)
    let id = try #require(await reader.importURLs([url]).first)
    let note = ReadingNote(
        paperID: id, contentVersion: "",
        anchors: [
            NoteAnchor(key: "original-0", target: "pdf", text: "Understanding", start: 0, end: 13)
        ], markdown: "")
    let draft = PDFNoteEditorSession(note: note, marks: [])
    reader.pdfNoteEditor = draft
    let editor = PDFReadingNoteEditor(model: reader, session: draft).makeCoordinator()
    let web = editor.makeView()
    defer { editor.stop() }
    web.frame = CGRect(x: 0, y: 0, width: 370, height: 220)
    let markdown = "**观点** 与 $x^2$"
    for _ in 0..<160 {
        let inserted =
            try? await web.callAsyncJavaScript(
                "if (!window.pdfEditor) return false; pdfEditor.view.dispatch({changes:{from:0,to:0,insert:markdown}});return true",
                arguments: ["markdown": markdown], in: nil, contentWorld: .defaultClient) as? Bool
        if inserted == true { break }
        try await Task.sleep(for: .milliseconds(30))
    }
    for _ in 0..<160 {
        let rendered =
            try? await web.callAsyncJavaScript(
                "return document.querySelector('.note-md-strong')!==null && document.querySelector('math')!==null",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        if rendered == true {
            #expect(reader.currentReadingNotes.first?.markdown == markdown)
            await reader.flushReadingNotes()
            return
        }
        try await Task.sleep(for: .milliseconds(40))
    }
    Issue.record("PDF 笔记卡片未在编辑区显示加粗文字和公式，正文已保存 = \(reader.currentReadingNotes.first?.markdown == markdown)")
}

@Test(arguments: [AnnotationStyle.underline, .highlight]) @MainActor
func pdfDiscussionNoteKeepsTheColorAndInkOfAnOverlappingManualMark(style: AnnotationStyle) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    let url = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: url)
    let paperID = try #require(await reader.importURLs([url]).first)
    let locator = PDFReadingNoteLocator()
    let prefix = try #require(try await locator.locate(quote: "Multiple attention", pageIndex: 1, in: url).first)
    var manual = prefix.highlight(for: paperID)
    manual.color = .purple
    manual.style = style
    reader.state.highlights = [manual]
    let canvas = PDFCanvas(model: reader, penEnabled: false)
    let coordinator = PDFCoordinator(model: reader)
    let pdf = coordinator.makeView()
    coordinator.update(pdf, penEnabled: false, focus: canvas.sentenceDisplay)
    let page = try #require(pdf.document?.page(at: 1))
    let oldInk = try #require(page.annotations.first)
    #expect(oldInk.type == (style == .underline ? "Underline" : "Highlight"))
    #if os(macOS)
        #expect(oldInk.color == NSColor.systemPurple.withAlphaComponent(style == .underline ? 1 : 0.45))
    #else
        #expect(oldInk.color == UIColor.systemPurple.withAlphaComponent(style == .underline ? 1 : 0.45))
    #endif
    let quote = "Multiple attention heads"
    let fragment = try #require(try await locator.locate(quote: quote, pageIndex: 1, in: url).first)
    let digest = try #require(reader.paper?.digest)
    let note = ReadingNote(
        paperID: paperID, contentVersion: digest + ":original-0", anchors: [fragment.anchor], markdown: "观点")
    _ = try await reader.saveAnchoredDiscussionNote(note, highlights: [fragment.highlight(for: paperID)])
    coordinator.update(pdf, penEnabled: false, focus: canvas.sentenceDisplay)
    #expect(reader.state.highlights.first == manual)
    #expect(reader.currentReadingNotes.first?.anchors == [fragment.anchor])
    #expect(page.annotations.contains { $0 === oldInk })
    let additions = page.annotations.filter { $0 !== oldInk }
    #expect(additions.contains { $0.type == "Highlight" })
    #expect(
        additions.filter { style == .underline || $0.type == "Highlight" }.allSatisfy {
            $0.bounds.intersection(oldInk.bounds).isEmpty
        })
    #expect(additions.contains { $0.type == "Underline" })
}
