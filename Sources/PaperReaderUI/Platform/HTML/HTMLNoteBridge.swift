import Foundation
import PaperReaderKit
import WebKit

@MainActor
final class HTMLNoteBridge {
    let model: ReaderModel
    private let renderer = NoteMarkdownRenderer()
    private var snapshot: [ReadingNote]?
    private var sidebar: Bool?
    private var persistence = ""
    private var navigationToken: UUID?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private struct Preview {
        let source: String
        let passages: Set<UUID>
        let html: String

        func matches(_ note: ReadingNote) -> Bool {
            source == note.markdown && passages == Set((note.citations ?? []).map(\.id))
        }
    }
    private var previewCache: [UUID: Preview] = [:]
    init(model: ReaderModel) { self.model = model }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        snapshot = nil
        previewCache = [:]
        sidebar = nil
        Task { await model.flushReadingNotes() }
    }

    func update(_ view: WKWebView, sidebarOpen: Bool) {
        if sidebar != sidebarOpen {
            sidebar = sidebarOpen
            call(view, "window.paperNotes?.sidebar(open)", ["open": sidebarOpen])
        }
        let paragraphNotes = model.displayedHTMLReadingNotes
        let summary = model.currentDocumentSummary
        let notes = paragraphNotes + [summary].compactMap { $0 }
        if snapshot != notes {
            let previous = snapshot
            snapshot = notes
            let ids = Set(notes.map(\.id))
            for id in Array(previewCache.keys) where !ids.contains(id) { previewCache[id] = nil }
            if previous?.filter({ !$0.isDocumentSummary }) != paragraphNotes {
                let values: [[String: Any]] = paragraphNotes.map { note in
                    [
                        "id": note.id.uuidString, "markdown": note.markdown, "anchors": note.anchors.map(Self.anchor),
                        "dimensionTitle": note.dimension?.title ?? "",
                        "html": previewCache[note.id].flatMap { $0.matches(note) ? $0.html : nil } ?? "",
                    ]
                }
                call(view, "window.paperNotes?.sync(notes)", ["notes": values])
            }
            if previous?.last(where: \.isDocumentSummary) != summary {
                call(
                    view, "window.paperNotes?.summary(id,source,html)",
                    [
                        "id": summary?.id.uuidString ?? "", "source": summary?.markdown ?? "",
                        "html": summary.flatMap { note in
                            previewCache[note.id].flatMap { $0.matches(note) ? $0.html : nil }
                        } ?? "",
                    ])
            }
            for note in notes where previewCache[note.id]?.matches(note) != true {
                tasks[note.id]?.cancel()
                let expectedPaper = note.paperID
                tasks[note.id] = Task { [weak self, weak view] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(60))
                        let passages = Set((note.citations ?? []).map(\.id))
                        let html = try await self.renderer.renderReadingNote(note.markdown, passageIDs: passages)
                        let preview = Preview(source: note.markdown, passages: passages, html: html)
                        try Task.checkCancellation()
                        guard let view, self.model.selectedPaperID == expectedPaper,
                            self.snapshot?.contains(where: {
                                $0.id == note.id && preview.matches($0)
                            }) == true
                        else { return }
                        self.previewCache[note.id] = preview
                        self.call(
                            view, "window.paperNotes?.preview(id,source,html)",
                            ["id": note.id.uuidString, "source": note.markdown, "html": html])
                    } catch is CancellationError {} catch {
                        guard let view, self.model.selectedPaperID == expectedPaper else { return }
                        self.call(view, "window.paperNotes?.previewError(id)", ["id": note.id.uuidString])
                    }
                }
            }
        }
        let status = model.noteSaveFailed ? "保存失败，请重试" : model.savedNoteRevision < model.noteRevision ? "保存中…" : "已保存"
        if persistence != status {
            persistence = status
            call(view, "window.paperNotes?.saved(status)", ["status": status])
        }
        if let id = model.requestedReadingNote, navigationToken != model.readingNoteNavigationToken,
            paragraphNotes.contains(where: { $0.id == id })
        {
            navigationToken = model.readingNoteNavigationToken
            call(view, "window.paperNotes?.open(id,true)", ["id": id.uuidString])
        }
    }

    func receive(_ value: [String: Any], view: WKWebView) {
        guard value["paperID"] as? String == model.selectedPaperID?.uuidString else { return }
        switch value["kind"] as? String {
        case "noteEditSummary":
            if let summary = model.currentDocumentSummary, value["id"] as? String == summary.id.uuidString {
                model.openReadingNote(summary)
                model.editingDocumentSummary = true
            }
        case "notePreviewPassage":
            guard let raw = value["id"] as? String, let id = UUID(uuidString: raw),
                let destination = value["passage"] as? String, let passage = UUID(uuidString: destination)
            else { return }
            model.presentNotePassage(noteID: id, citationID: passage)
        case "noteInsertPassage":
            guard let raw = value["id"] as? String, let id = UUID(uuidString: raw),
                let anchors = Self.anchors(value["anchors"]), let markdown = value["markdown"] as? String,
                let from = value["from"] as? Int, let to = value["to"] as? Int
            else { return }
            model.pickNotePassage(noteID: id, anchors: anchors, source: markdown, from: from, to: to) {
                [weak self, weak view] link in
                guard let self, let view else { return }
                call(
                    view, "window.paperNotes?.insertPassage(id,source,from,to,link)",
                    ["id": raw, "source": markdown, "from": from, "to": to, "link": link])
                update(view, sidebarOpen: sidebar ?? true)
            }
        case "noteChange":
            guard let raw = value["id"] as? String, let id = UUID(uuidString: raw),
                let markdown = value["markdown"] as? String, let anchors = Self.anchors(value["anchors"]),
                model.updateReadingNote(id: id, anchors: anchors, markdown: markdown)
            else {
                call(view, "window.paperNotes?.saved(status)", ["status": "保存失败：笔记位置未核对"])
                return
            }
            update(view, sidebarOpen: sidebar ?? true)
        case "noteFlush":
            Task {
                await model.flushReadingNotes()
                update(view, sidebarOpen: sidebar ?? true)
            }
        case "noteDelete":
            if let raw = value["id"] as? String, let id = UUID(uuidString: raw) {
                model.deleteReadingNote(id)
                update(view, sidebarOpen: sidebar ?? true)
            }
        case "noteUndo":
            model.undoReadingNoteDeletion()
            update(view, sidebarOpen: sidebar ?? true)
        default: break
        }
    }

    private func call(_ view: WKWebView, _ source: String, _ arguments: [String: Any]) {
        view.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .defaultClient, completionHandler: nil)
    }
    private static func anchor(_ a: NoteAnchor) -> [String: Any] {
        ["key": a.key, "target": a.target, "text": a.text, "start": a.start, "end": a.end]
    }
    private static func anchors(_ value: Any?) -> [NoteAnchor]? {
        guard let items = value as? [[String: Any]], !items.isEmpty, items.count <= 10_000 else { return nil }
        var result: [NoteAnchor] = []
        for item in items {
            guard let key = item["key"] as? String, let target = item["target"] as? String,
                target == "source" || target == "translation"
                    || (target.hasPrefix("object:") && Int(target.dropFirst(7)).map { $0 >= 0 } == true),
                let text = item["text"] as? String, let start = item["start"] as? Int, let end = item["end"] as? Int,
                start >= 0, end > start, end - start == text.utf16.count
            else { return nil }
            result.append(NoteAnchor(key: key, target: target, text: text, start: start, end: end))
        }
        return result
    }
}
