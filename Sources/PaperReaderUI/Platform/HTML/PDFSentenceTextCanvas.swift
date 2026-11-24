import PaperReaderKit
import SwiftUI
import WebKit

/// Paragraph text remains selectable while sentence IDs connect translated text to stable local anchors.
@MainActor struct PDFSentenceTextCanvas {
    enum Layout: String { case split, paragraph }
    let sentences: [PDFSourceSentence]
    let translations: [String: String]
    let layout: Layout
    let fontSize: Int
    let onSelection: ([String]) -> Void
    var illustrations: [PDFReadingIllustration] = []
    var onRevealIllustration: ((PDFReadingIllustration) -> Void)?
    var copyTableText: (String) -> Bool = { text in
        #if os(macOS)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
            return true
        #endif
    }

    var continuous: Continuous?
    var inlineNotes: [PDFInlineNote] = []
    var onOpenNote: (UUID) -> Void = { _ in }
    var onOpenHighlight: (UUID) -> Void = { _ in }
    var inlineHighlights: [PDFInlineNote] = []
    var onTextSelection: ([PDFReflowTextSelection]) -> Void = { _ in }
    var onSelectionAction: (PDFReflowSelectionAction, [PDFReflowTextSelection]) -> Void = { _, _ in }
    var noteModel: ReaderModel?
    var sidebarOpen = true

    struct Continuous {
        let paperID: UUID
        let pageCount: Int
        let pages: [Int: PDFParagraphPage]
        let targetPage: Int
        let jumpRevision: Int
        var outlineItem: PaperNavigationItem? = nil
        let onVisiblePage: (Int) -> Void
        let onOpenOriginalPage: (Int) -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var latest: PDFSentenceTextCanvas
        private var renderedSentences: [PDFSourceSentence] = []
        private var renderedIllustrations: [PDFReadingIllustration] = []
        private var translated: [String: String] = [:]
        private var displayedLayout: Layout?
        private var displayedFontSize: Int?
        private var displayedNotes: [PDFInlineNote] = []
        private var displayedHighlights: [PDFInlineNote] = []
        private var ready = false
        private var paragraphWindow = PDFParagraphWindowBridge()
        private var noteBridge: HTMLNoteBridge?
        private var notePaperID: UUID?
        private var projectedNotes: [UUID: [NoteAnchor]] = [:]

        init(_ parent: PDFSentenceTextCanvas) { latest = parent }

        func makeView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let controller = config.userContentController
            controller.add(self, contentWorld: .defaultClient, name: "sentence")
            var script = HTMLImagePreviewScript.source + "\n" + PDFSentenceTextCanvas.script
            if latest.noteModel != nil {
                controller.add(self, contentWorld: .defaultClient, name: "reader")
                script +=
                    HTMLNativeNoteEditorScript.source + HTMLNoteStyle.source
                    + HTMLNoteLiftScript.source + HTMLNoteLayoutScript.source + HTMLNotesScript.source
            }
            controller.addUserScript(
                WKUserScript(
                    source: script,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true, in: .defaultClient))
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = self
            view.loadHTMLString(PDFSentenceTextCanvas.document, baseURL: nil)
            return view
        }

        func stop(_ view: WKWebView) {
            ready = false
            view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(
                forName: "sentence", contentWorld: .defaultClient)
            view.configuration.userContentController.removeScriptMessageHandler(
                forName: "reader", contentWorld: .defaultClient)
            noteBridge?.stop()
            view.stopLoading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            update(latest, view: webView)
        }

        func update(_ parent: PDFSentenceTextCanvas, view: WKWebView) {
            latest = parent
            guard ready else { return }
            let continuous = parent.layout == .paragraph ? parent.continuous : nil
            let paperID = parent.noteModel?.selectedPaperID
            let changedPaper = notePaperID != paperID
            if changedPaper {
                notePaperID = paperID
                noteBridge?.stop()
                noteBridge = parent.noteModel.map { HTMLNoteBridge(model: $0) }
                projectedNotes = [:]
                view.callAsyncJavaScript(
                    "if(document.body.dataset.paperId) window.paperNotes?.reset(); document.body.dataset.paperId = paper",
                    arguments: ["paper": paperID?.uuidString ?? ""], in: nil, in: .defaultClient, completionHandler: nil
                )
            }
            let leftDocument = continuous == nil && paragraphWindow.paperID != nil
            let changed =
                continuous == nil
                && (leftDocument || renderedSentences != parent.sentences || translated != parent.translations)
            let windowChanged =
                continuous.map { paragraphWindow.update($0, fontSize: parent.fontSize, view: view) } ?? false
            let layoutChanged = displayedLayout != parent.layout
            let paragraph = parent.layout == .paragraph
            let illustrations = paragraph ? parent.illustrations : []
            let illustrationsChanged = leftDocument || renderedIllustrations != illustrations
            if continuous == nil && (changed || layoutChanged || illustrationsChanged) {
                paragraphWindow = PDFParagraphWindowBridge()
                let rows = Self.rows(parent.sentences, translations: parent.translations, paragraph: paragraph)
                var arguments: [String: Any] = ["rows": rows, "layout": parent.layout.rawValue, "figures": NSNull()]
                if illustrationsChanged {
                    arguments["figures"] = illustrations.map(Self.figure)
                    renderedIllustrations = illustrations
                }
                view.callAsyncJavaScript(
                    "window.sentenceReader.render(rows, layout, figures)", arguments: arguments,
                    in: nil, in: .defaultClient, completionHandler: nil)
                renderedSentences = parent.sentences
                translated = parent.translations
            }
            var notes = parent.inlineNotes
            let editor = parent.noteModel?.pdfNoteEditor
            if let editor, editor.usesReflowMargin, editor.note.paperID == paperID,
                !notes.contains(where: { $0.id == editor.id })
            {
                notes.append(
                    PDFInlineNote(id: editor.id, anchors: editor.note.anchors, color: editor.note.dimension?.color))
            }
            if (changedPaper || changed || windowChanged || layoutChanged || displayedNotes != notes
                || displayedHighlights != parent.inlineHighlights)
                && (!displayedNotes.isEmpty || !notes.isEmpty
                    || !displayedHighlights.isEmpty || !parent.inlineHighlights.isEmpty)
            {
                let sentences =
                    continuous.map { $0.pages.sorted { $0.key < $1.key }.flatMap { $0.value.sentences } }
                    ?? parent.sentences
                let translations =
                    continuous.map { window in
                        window.pages.values.reduce(into: [String: String]()) {
                            $0.merge($1.translations) { _, new in new }
                        }
                    } ?? parent.translations
                let marks = Self.noteMarks(in: sentences, notes: notes, translations: translations)
                let highlights = Self.noteMarks(
                    in: sentences, notes: parent.inlineHighlights, translations: translations)
                view.callAsyncJavaScript(
                    "window.sentenceReader.markNotes(marks, highlights, inlineEditor)",
                    arguments: ["marks": marks, "highlights": highlights, "inlineEditor": noteBridge != nil],
                    in: nil, in: .defaultClient, completionHandler: nil)
                if noteBridge != nil {
                    projectedNotes = Self.cardAnchors(
                        marks, sentences: sentences, translations: translations, paragraph: paragraph)
                }
                displayedNotes = notes
                displayedHighlights = parent.inlineHighlights
            }
            if let noteBridge {
                noteBridge.updatePDF(view, sidebarOpen: parent.sidebarOpen, projection: projectedNotes)
                if let editor, editor.usesReflowMargin, editor.note.paperID == paperID,
                    projectedNotes[editor.id] == nil,
                    let page = editor.note.anchors.first?.readingPageIndex,
                    let model = parent.noteModel,
                    continuous.map({ $0.pages[page] != nil })
                        ?? (model.pdfBilingual.pageIndex == page && !model.pdfBilingual.isLoading)
                {
                    Task { [weak self, weak model] in
                        guard let self, self.ready, self.notePaperID == paperID, self.projectedNotes[editor.id] == nil
                        else { return }
                        model?.useOriginalPDFNoteCard(for: editor.id)
                    }
                }
            }
            if changed || windowChanged || layoutChanged || displayedFontSize != parent.fontSize {
                view.callAsyncJavaScript(
                    "window.sentenceReader.show(fontSize)", arguments: ["fontSize": parent.fontSize],
                    in: nil, in: .defaultClient, completionHandler: nil)
                displayedLayout = parent.layout
                displayedFontSize = parent.fontSize
            }
        }

        static func rows(_ sentences: [PDFSourceSentence], translations: [String: String], paragraph: Bool)
            -> [[String: String]]
        {
            sentences.compactMap { sentence in
                let translation = translations[sentence.id]
                guard paragraph || translation != nil else { return nil }
                return [
                    "id": sentence.id, "paragraph": paragraph ? sentence.readingParagraphID : sentence.paragraphID,
                    "en": sentence.text, "zh": translation ?? "",
                    "anchorable": sentence.characterRanges.isEmpty ? "" : "1",
                ]
            }
        }

        /// DOM ranges position cards only. All note writes use their verified original PDF anchors.
        private static func cardAnchors(
            _ marks: [[String: Any]], sentences: [PDFSourceSentence], translations: [String: String], paragraph: Bool
        ) -> [UUID: [NoteAnchor]] {
            let bySentence = Dictionary(grouping: marks) { $0["sentence"] as? String ?? "" }
            var result: [UUID: [NoteAnchor]] = [:]
            for sentence in sentences {
                for mark in bySentence[sentence.id] ?? [] {
                    guard let raw = mark["note"] as? String, let id = UUID(uuidString: raw),
                        let ranges = mark["ranges"] as? [[Int]]
                    else { continue }
                    let english = mark["language"] as? String == "en"
                    guard paragraph || !english,
                        let text = (english ? sentence.text : translations[sentence.id]) as NSString?
                    else { continue }
                    for range in ranges where range.count == 2 {
                        let start = range[0]
                        let end = range[1]
                        guard start >= 0, start < end, end <= text.length else { continue }
                        let part = text.substring(with: NSRange(location: start, length: end - start))
                        result[id, default: []].append(
                            NoteAnchor(
                                key: sentence.id, target: english ? "source" : "translation", text: part, start: start,
                                end: end))
                    }
                }
            }
            return result
        }

        /// Intersections are computed in the immutable PDF character space. Reflowed text receives ink
        /// only when the overlapping glyphs also identify a unique substring of the rendered sentence.
        static func noteMarks(
            in sentences: [PDFSourceSentence], notes: [PDFInlineNote], translations: [String: String] = [:]
        ) -> [[String: Any]] {
            let byPage = Dictionary(grouping: sentences, by: \.pageIndex)
            var translatedSentences: [String: PDFSourceSentence] = [:]
            if notes.contains(where: { $0.anchors.contains { $0.pdfTranslationPageIndex != nil } }) {
                for sentence in sentences {
                    guard let text = translations[sentence.id] else { continue }
                    translatedSentences[NoteAnchor.pdfTranslationTarget(sentenceID: sentence.id, translation: text)] =
                        sentence
                }
            }
            var output: [[String: Any]] = []
            for note in notes {
                var hits: [String: [[Int]]] = [:]
                var chinese: [String: [[Int]]] = [:]
                for anchor in note.anchors {
                    if let page = anchor.pdfTranslationPageIndex {
                        guard let sentence = translatedSentences[anchor.target], sentence.pageIndex == page,
                            let text = translations[sentence.id] as NSString?, anchor.start >= 0,
                            anchor.end > anchor.start, anchor.end <= text.length,
                            text.substring(with: NSRange(location: anchor.start, length: anchor.end - anchor.start))
                                == anchor.text
                        else { continue }
                        chinese[sentence.id, default: []].append([anchor.start, anchor.end])
                        continue
                    }
                    guard let page = anchor.pdfPageIndex, anchor.start >= 0, anchor.end > anchor.start,
                        anchor.end - anchor.start == anchor.text.utf16.count
                    else { continue }
                    let source = NSRange(location: anchor.start, length: anchor.end - anchor.start)
                    for sentence in byPage[page] ?? [] {
                        let english = sentence.text as NSString
                        var sourceOffset = 0
                        for (runIndex, run) in sentence.characterRanges.enumerated() {
                            defer { sourceOffset += run.length }
                            let overlap = NSIntersectionRange(source, run)
                            guard overlap.length > 0 else { continue }
                            if hits[sentence.id] == nil { hits[sentence.id] = [] }
                            let piece = (anchor.text as NSString).substring(
                                with:
                                    NSRange(location: overlap.location - source.location, length: overlap.length))
                            // Each earlier line boundary can remove one hyphen or insert one space.
                            // Verify all feasible offsets. If two positions fit, leave just the note button.
                            let offset = sourceOffset + overlap.location - run.location
                            let low = max(0, offset - runIndex)
                            let high = min(english.length, offset + runIndex)
                            guard low <= high else { continue }
                            var match: NSRange?
                            for start in low...high {
                                let remaining = english.length - start
                                var length = overlap.length
                                if length > remaining
                                    || english.substring(with: NSRange(location: start, length: length)) != piece
                                {
                                    guard NSMaxRange(overlap) == NSMaxRange(run),
                                        ["-", "‐", "\u{00ad}"].contains(String(piece.suffix(1))),
                                        length > 1, length - 1 <= remaining,
                                        english.substring(with: NSRange(location: start, length: length - 1))
                                            == String(piece.dropLast())
                                    else { continue }
                                    length -= 1
                                }
                                if match != nil {
                                    match = nil
                                    break
                                }
                                match = NSRange(location: start, length: length)
                            }
                            if let match { hits[sentence.id, default: []].append([match.location, NSMaxRange(match)]) }
                        }
                    }
                }
                for (language, entries) in [("en", hits), ("zh", chinese)] {
                    for (sentenceID, ranges) in entries {
                        output.append([
                            "note": note.id.uuidString, "sentence": sentenceID, "ranges": ranges,
                            "language": language, "color": note.color?.rawValue ?? "yellow",
                            "style": note.style?.rawValue ?? "highlight",
                        ])
                    }
                }
            }
            return output
        }

        static func figure(_ item: PDFReadingIllustration) -> [String: Any] {
            var result: [String: Any] = [
                "id": item.id, "label": item.label, "before": item.insertBeforeSentenceID ?? "",
                "presentation": item.presentation.rawValue,
            ]
            if let original = item.originalText {
                result["originalKind"] = original.kind.rawValue
                result["paragraphs"] = original.paragraphs
                return result
            }
            if let table = item.table {
                func runs(_ values: [PDFReadingTable.Run]) -> [[String: Any]] {
                    values.map { run in
                        ["text": run.text, "baseline": run.baseline.rawValue, "bold": run.bold, "italic": run.italic]
                    }
                }
                let styled = table.styledCells.map { cell -> [String: Any] in
                    ["row": cell.row, "column": cell.column, "runs": runs(cell.runs)]
                }
                let headers = table.headerRows.map { row in
                    row.map { cell -> [String: Any] in
                        [
                            "text": cell.text, "column": cell.column, "rowSpan": cell.rowSpan,
                            "columnSpan": cell.columnSpan, "runs": runs(cell.runs),
                        ]
                    }
                }
                var data: [String: Any] = [
                    "header": table.header, "rows": table.rows, "styledCells": styled, "headerRows": headers,
                ]
                if !table.sourceCellBounds.isEmpty, item.imagePNG != nil {
                    let source = item.sourceBounds
                    data["cellBounds"] = table.sourceCellBounds.map { boxes in
                        boxes.map { box in
                            [
                                (box.minX - source.minX) / source.width, (source.maxY - box.maxY) / source.height,
                                box.width / source.width, box.height / source.height,
                            ]
                        }
                    }
                    result["sourceWidth"] = source.width
                }
                result["table"] = data
                if data["cellBounds"] == nil { return result }
            }
            result["png"] = item.imagePNG?.base64EncodedString() ?? ""
            if item.presentation == .excerpt { result["sourceWidth"] = item.sourceBounds.width }
            // Reserve the exact raster aspect ratio before WebKit decodes it, including rotated crops.
            if let data = item.imagePNG, data.count >= 24 {
                let dimensions = data.dropFirst(16).prefix(8)
                result["width"] = dimensions.prefix(4).reduce(0) { $0 * 256 + Int($1) }
                result["height"] = dimensions.suffix(4).reduce(0) { $0 * 256 + Int($1) }
            }
            return result
        }

        private func isDisplayed(_ id: String) -> Bool {
            if let continuous = latest.continuous {
                return continuous.pages.values.contains { page in page.sentences.contains { $0.id == id } }
            }
            return latest.translations[id] != nil
                || (latest.layout == .paragraph && latest.sentences.contains { $0.id == id })
        }

        /// WebKit measures offsets in UTF-16. Validate its snapshot against the displayed edition
        /// before passing any selection to the PDF anchor resolver.
        private func textSelection(_ event: [String: Any]) -> [PDFReflowTextSelection] {
            guard let pieces = event["pieces"] as? [[String: Any]] else { return [] }
            var result: [PDFReflowTextSelection] = []
            var seen = Set<String>()
            for piece in pieces {
                guard let id = piece["id"] as? String,
                    let language = piece["language"] as? String, language == "en" || language == "zh",
                    (result.first?.language ?? language) == language, seen.insert(id).inserted,
                    let start = piece["start"] as? Int, let end = piece["end"] as? Int,
                    let text = piece["text"] as? String, start >= 0, end > start
                else { return [] }
                let page = latest.continuous?.pages.values.first { $0.sentences.contains { $0.id == id } }
                guard latest.continuous == nil || page != nil,
                    let sentence = (page?.sentences ?? latest.sentences).first(where: { $0.id == id }),
                    !sentence.characterRanges.isEmpty,
                    let displayed = language == "en" ? sentence.text : (page?.translations ?? latest.translations)[id]
                else { return [] }
                let range = NSRange(location: start, length: end - start)
                let source = displayed as NSString
                guard end <= source.length, source.substring(with: range) == text else { return [] }
                result.append(.init(sentence: sentence, language: language, range: range, text: text))
            }
            return result
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready, message.frameInfo.isMainFrame, let event = message.body as? [String: Any] else { return }
            if message.name == "reader" {
                guard let model = latest.noteModel, model.mode == "original", model.pdfBilingual.isOpen,
                    let paperID = notePaperID, model.selectedPaperID == paperID,
                    event["paperID"] as? String == paperID.uuidString,
                    let view = message.webView
                else { return }
                noteBridge?.receive(event, view: view)
                return
            }
            if let stamp = event["paper"] as? String {
                guard let window = latest.continuous, stamp == window.paperID.uuidString,
                    event["revision"] as? Int == window.jumpRevision
                else { return }
                if let index = event["page"] as? Int, (0..<window.pageCount).contains(index) {
                    switch event["action"] as? String {
                    case "viewport":
                        window.onVisiblePage(index)
                        return
                    case "original":
                        window.onOpenOriginalPage(index)
                        return
                    default: break
                    }
                }
            } else if latest.continuous != nil {
                return
            }
            let action = event["action"] as? String
            if action == "annotate" {
                let tool: PDFReflowSelectionAction
                switch event["tool"] as? String {
                case "note": tool = .note
                case "bookmark": tool = .bookmark
                case "mark":
                    guard let color = (event["color"] as? String).flatMap(AnnotationColor.init(rawValue:)),
                        let style = (event["style"] as? String).flatMap(AnnotationStyle.init(rawValue:)),
                        let removing = event["remove"] as? Bool
                    else { return }
                    tool = .mark(color: color, style: style, removing: removing)
                default: return
                }
                let selection = textSelection(event)
                guard !selection.isEmpty else { return }
                latest.onSelectionAction(tool, selection)
                return
            }
            if action == "note", let raw = event["id"] as? String, let id = UUID(uuidString: raw),
                latest.inlineNotes.contains(where: { $0.id == id })
            {
                latest.onOpenNote(id)
                return
            }
            if action == "openHighlight", let raw = event["id"] as? String, let id = UUID(uuidString: raw),
                latest.inlineHighlights.contains(where: { $0.id == id })
            {
                latest.onOpenHighlight(id)
                return
            }
            if action == "illustration" || action == "copyTable" {
                if latest.layout == .paragraph, let id = event["id"] as? String,
                    let item = latest.continuous?.pages.values.lazy.compactMap({
                        $0.illustrations.first(where: { $0.id == id })
                    }).first
                        ?? latest.illustrations.first(where: { $0.id == id })
                {
                    if action == "illustration" {
                        latest.onRevealIllustration?(item)
                    } else if let table = item.table {
                        let copied = latest.copyTableText(table.tabSeparatedText)
                        message.webView?.callAsyncJavaScript(
                            "window.sentenceReader.tableCopied(id, copied)",
                            arguments: ["id": id, "copied": copied], in: nil, in: .defaultClient, completionHandler: nil
                        )
                    }
                }
                return
            }
            if event["action"] as? String == "selection", let ids = event["ids"] as? [String],
                ids.allSatisfy({ isDisplayed($0) })
            {
                latest.onSelection(ids)
                latest.onTextSelection(textSelection(event))
                return
            }
        }
    }
}

#if os(macOS)
    extension PDFSentenceTextCanvas: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self, view: view) }
        static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(view) }
    }
#else
    extension PDFSentenceTextCanvas: UIViewRepresentable {
        func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self, view: view) }
        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(view) }
    }
#endif

extension PDFSentenceTextCanvas {
    fileprivate static let document = """
        <!doctype html><html lang="zh-Hans"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'">
        <style>
        :root{color-scheme:light dark;--paper:#fffdf8;--ink:#292822;--en:#504d46;--active:#f2dfd2;--focus:#9f503a}
        @media(prefers-color-scheme:dark){:root{--paper:#2c2b26;--ink:#f0eee7;--en:#c9c4b9;--active:#594038;--focus:#e8a086}}
        *{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:var(--zh-size,16px)/1.7 \(ReadingPageTypography.pdfChinese)}
        main{max-width:45rem;margin:auto;padding:19px clamp(18px,4vw,38px) 60px;overflow-wrap:anywhere}
        p{margin:0 0 1em}
        .en{display:none}
        .paragraph main{\(ReadingPageTypography.pdfColumn)}
        .paragraph main>*+*{margin-top:1.7em}
        figure{margin:0}.paragraph figure+section{margin-top:.8em}
        figure button{display:block;max-width:100%;padding:0;border:0;background:none;color:var(--focus);cursor:pointer;font:inherit}
        figure button:focus-visible{outline:2px solid var(--focus);outline-offset:3px}
        figure img{display:block;max-width:100%;height:auto;margin:auto}
        figure button:has(img){width:100%;cursor:zoom-in}
        figure button:not(:has(img)){font-size:.9em;text-decoration:underline;text-underline-offset:.2em}
        .paragraph p{margin:0}.paragraph p[lang="en"]{font:1.06em/1.55 Georgia,"Times New Roman",serif;color:var(--en)}
        .paragraph .en{display:inline}.paragraph p[lang="zh-Hans"]{margin-top:.45em;line-height:1.8}
        .source-text{color:var(--en);line-height:1.6}
        .source-text h3{color:var(--ink);font:600 1.12em/1.4 Georgia,serif;margin:0 0 .65em}
        .source-text.byline{font:.92em/1.6 -apple-system,sans-serif}
        .source-text.byline p{white-space:pre-line}
        .source-text.byline p+p{margin-top:.25em}
        .source-text.author-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,15rem),1fr));
          gap:.9em 1.6em;align-items:start}
        .source-text.author-cards p+p{margin:0}
        .author-cards p::first-line{color:var(--ink);font-weight:600}
        .source-text.prose{font:1.06em/1.55 Georgia,"Times New Roman",serif}
        .source-text.references{font:1em/1.55 Georgia,serif}
        .source-text.references p{margin:0 0 .65em;padding-inline-start:1.3em;text-indent:-1.3em}
        [data-selecting="zh"] .source-line{-webkit-user-select:none;user-select:none}
        .pending{color:var(--en);font:.8em/1.6 -apple-system,sans-serif;margin-inline:.2em;-webkit-user-select:none;user-select:none}
        [data-selecting="zh"] .en,[data-selecting="en"] .zh{-webkit-user-select:none;user-select:none}
        .paragraph.continuous main{padding-top:0}
        .continuous main>.source-page{display:flow-root;margin:0;overflow-anchor:none}
        .page-body>*+*{margin-top:1.7em}
        .untranslated .page-body section>p[lang="zh-Hans"]{display:none}
        .page-marker{display:flex;align-items:center;gap:.8em;margin:2.4em 0 1.4em;color:var(--en);font:500 .75em/1.5 -apple-system,sans-serif}
        .page-marker:after{content:"";height:1px;background:currentColor;opacity:.2;flex:1}
        :root{--pdf-note-yellow:#eacb6d5c;--pdf-note-red:#f5aaa67d;--pdf-note-blue:#b5d5f884;
          --pdf-note-green:#b7db9e80;--pdf-note-purple:#cbb7ed80}
        ::highlight(pdf-reading-notes){background-color:var(--pdf-note-yellow);text-decoration:underline #ab7752}
        \(AnnotationColor.allCases.map { color in
            "::highlight(pdf-\(color.rawValue)-highlight){background-color:\(color.hex);color:#292e2e}" +
            "::highlight(pdf-\(color.rawValue)-underline){text-decoration:underline \(color.hex) 2px}"
        }.joined(separator: "\n"))
        ::highlight(pdf-notes-red){background-color:var(--pdf-note-red);text-decoration:underline #d4807a}
        ::highlight(pdf-notes-blue){background-color:var(--pdf-note-blue);text-decoration:underline #7ca3d0}
        ::highlight(pdf-notes-green){background-color:var(--pdf-note-green);text-decoration:underline #7ca663}
        ::highlight(pdf-notes-purple){background-color:var(--pdf-note-purple);text-decoration:underline #9880b6}
        .sentence-note{display:inline-flex;vertical-align:super;align-items:center;justify-content:center;border:0;
          color:var(--accent,#a55537);background:transparent;font:13px system-ui;cursor:pointer;padding:0 .2em}
        .sentence-note::before{content:'✎'}
        .page-note,.page-loading{color:var(--en);font:.82em/1.65 -apple-system,sans-serif}
        .page-body>.page-note{margin:0 0 1.2em}
        .reading-table{width:max-content;min-width:100%;max-width:max(100%,calc(100vw - 2.5rem));
          margin-inline-start:50%;transform:translateX(-50%)}
        .table-scroll{max-width:100%;overflow-x:auto;overscroll-behavior-x:contain}
        .table-scroll:focus-visible{outline:2px solid var(--focus);outline-offset:2px}
        .table-tools{display:flex;align-items:center;gap:.4em;padding-bottom:.3rem;min-height:2.2rem}
        .reading-table .table-tools button{min-height:28px;padding:.15rem .35rem;border-radius:.3rem;text-decoration:none;
          color:var(--en);font:500 .8rem/1.3 -apple-system,sans-serif}
        .table-tools .table-title{margin-inline-end:auto}.table-tools button:hover{background:var(--active)}
        .table-tools .table-step{min-width:28px;font-size:1.1rem}
        .table-tools button:disabled{opacity:.36;cursor:default}.table-tools button[hidden]{display:none}
        @media(pointer:coarse){.table-tools button{min-width:44px;min-height:44px!important}}
        .reading-table table{width:100%;border-collapse:collapse;text-align:start;font-size:.93em;line-height:1.45;font-variant-numeric:tabular-nums}
        .reading-table :is(caption,figcaption){text-align:start;padding-bottom:.5rem}
        .reading-table :is(caption,figcaption) button{color:var(--en);font-size:.9em;text-decoration:none}
        .reading-table :is(th,td){padding:.44em .7em;text-align:start;vertical-align:top;overflow-wrap:normal}
        .reading-table thead{border-block:1px solid var(--en)}
        .reading-table tbody tr{border-bottom:1px solid color-mix(in srgb,var(--en) 22%,transparent)}
        .reading-table tbody tr:last-child{border-bottom:1px solid var(--en)}
        .source-table{position:relative;container-type:inline-size;width:100%}
        .source-table>img{width:100%;pointer-events:none;-webkit-user-select:none;user-select:none}
        .source-table table{position:absolute;inset:0;display:block;height:100%}
        .source-table :is(thead,tbody,tr){display:block;border:none!important}
        .source-table :is(th,td){position:absolute;box-sizing:border-box;display:block;overflow:hidden;padding:0;
          white-space:nowrap;cursor:text;color:transparent;font-family:Georgia,serif;font-weight:normal;line-height:1}
        .source-table :is(th,td)>span{display:inline-block;transform-origin:left center}
        .page-supplement summary{width:fit-content;color:var(--en);font-size:.85em;cursor:pointer}
        .page-supplement[open] summary{margin-bottom:.6em}
        .page-source{border:0;background:none;color:var(--focus);padding:0;cursor:pointer;font:inherit;text-decoration:underline;text-underline-offset:.2em}
        ::selection{background:rgba(160,125,89,.30)}
        html.reading-range::selection,html.reading-range body::selection,html.reading-range main::selection,
        html.reading-range main ::selection{background:transparent;color:inherit}
        main{position:relative;z-index:1}
        #pdf-text-selection{position:absolute;inset:0 auto auto 0;width:0;height:0;pointer-events:none}
        </style></head><body><main id="reader" aria-label="本页段落译文"></main></body></html>
        """

    fileprivate static let script = """
        (() => {
          const main=document.querySelector('main'), pairs=new Map();
          let figures=[];
          let lastSelection='[[],[]]', paragraphMode=false;
          let inlineNoteRanges=new WeakMap();
          let flow=null;
          function post(event) {
            if (flow) { event.paper=flow.paper;event.revision=flow.revision; }
            window.webkit.messageHandlers.sentence.postMessage(event);
          }
          const send=(action,id)=>post({action,id});
          const sideOf=node=>node?.closest('.en,.source-line') ? 'en' : 'zh';
          window.addEventListener('scroll',scheduleViewport,{passive:true});
          \(tableScript)
          \(HTMLSelectionScript.textInk)
          const selectionInk=document.createElement('div');
          selectionInk.id='pdf-text-selection';selectionInk.setAttribute('aria-hidden','true');document.body.append(selectionInk);
          function selectedRange(range, node) {
            const content = document.createRange();
            content.selectNodeContents(node);
            if (range.compareBoundaryPoints(Range.START_TO_START, content) > 0) {
              content.setStart(range.startContainer,range.startOffset);
            }
            if (range.compareBoundaryPoints(Range.END_TO_END, content) < 0) {
              content.setEnd(range.endContainer,range.endOffset);
            }
            return content;
          }
          function selectedPieces() {
            const selection = getSelection();
            if (!selection.rangeCount || selection.isCollapsed) return [];
            const anchor = selection.anchorNode;
            const start = anchor.nodeType === Node.TEXT_NODE ? anchor.parentElement : anchor;
            if (!main.contains(start)) return [];
            const anchorText=start.closest('.en,.zh,.source-line');
            const language = anchorText ? sideOf(anchorText) : main.dataset.selecting || sideOf(start);
            const range = selection.getRangeAt(0);
            const pieces = [];
            const selector=language==='en' ? '.en,.source-line' : '.zh';
            for (const text of main.querySelectorAll(selector)) {
              const node=text.firstChild;
              if (node?.nodeType!==Node.TEXT_NODE || !range.intersectsNode(node)) continue;
              const clipped=selectedRange(range,node);
              if (!clipped.collapsed) pieces.push({id:text.dataset.sentence, group:text.dataset.sourceGroup, range:clipped, language});
            }
            return pieces;
          }
          let lifted=[];
          function paintSelection(pieces) {
            document.documentElement.classList.toggle('reading-range',pieces.length>0);
            const pixels=document.createDocumentFragment();
            for (const range of excludingRanges(pieces.map(p=>p.range),lifted)) appendTextInk(pixels,range,'rgba(160,125,89,.30)');
            selectionInk.replaceChildren(pixels);
          }
          const refreshSelectionInk=()=>{if(offeredBounds.length)paintSelection(offeredBounds.map(range=>({range})));};
          \(selectionToolsScript)
          \(HTMLSelectionScript.textFragments)
          \(noteSelectionScript)
          new ResizeObserver(refreshSelectionInk).observe(main);
          document.fonts?.addEventListener('loadingdone',refreshSelectionInk);
          main.addEventListener('pointerdown', event => {
            const text = event.target.closest('.en,.zh,.source-line');
            if (text) main.dataset.selecting = sideOf(text);
            else delete main.dataset.selecting;
          });
          document.addEventListener('selectionchange', () => {
            if (window.paperNotes?.preservingSelection() || (getSelection().isCollapsed && tools.preservingSelection())) return;
            const pieces=selectedPieces();
            paintSelection(pieces);
            const ids = pieces.map(piece => piece.id).filter(Boolean);
            const parts=annotationParts(pieces), signature=JSON.stringify([ids,parts]);
            if (signature !== lastSelection) {
              lastSelection=signature;
              rememberSelection(parts,pieces);
              post({action:'selection',ids,pieces:parts});
              tools.selectionChanged();
            }
          });
          document.addEventListener('copy', event => {
            const selection=getSelection();
            if (event.clipboardData && selection.rangeCount && !selection.isCollapsed) {
              const cells=copyTableCells(selection.getRangeAt(0));
              if (cells!==null) {
                event.clipboardData.setData('text/plain',cells);event.preventDefault();return;
              }
            }
            const pieces = selectedPieces();
            if (!pieces.length || !event.clipboardData) return;
            let plain = '';
            let paragraph;
            for (const piece of pieces) {
              const next = piece.group ?? pairs.get(piece.id).group;
              if (paragraph && paragraph !== next) plain += '\\n\\n';
              else if (plain && piece.language === 'en') plain += ' ';
              plain += piece.range.toString();
              paragraph = next;
            }
            event.clipboardData.setData('text/plain', plain);
            event.preventDefault();
          });
          main.addEventListener('click',e=>{
            const note=e.target.closest('[data-reading-note]');
            if (note) {send('note',note.dataset.readingNote);return;}
            if (e.detail===1 && getSelection().isCollapsed) {
              const runs=inlineNoteRanges.get(e.target.closest('.en,.zh'));
              const hit=runs?.find(({range})=>[...range.getClientRects()].some(rect=>
                rect.left<=e.clientX && e.clientX<=rect.right && rect.top<=e.clientY && e.clientY<=rect.bottom));
              if (hit) {
                if (hit.shared) window.paperNotes.open(hit.id,true,false);else send(hit.action,hit.id);
                return;
              }
            }
            const source=e.target.closest('[data-original]');
            if (source) {post({action:'original',page:Number(source.dataset.original)});return;}
            const figure=e.target.closest('[data-illustration]');
            if (figure && (e.detail===0 || getSelection().isCollapsed)) {
              const image=figure.dataset.preview && figure.querySelector('img');
              if (image?.naturalWidth) {
                const id=figure.dataset.illustration;
                window.paperImagePreview.open(image,{title:figure.dataset.preview,details:true,opener:figure,
                  actionLabel:'查看原页',onAction:()=>send('illustration',id)});
                return;
              }
              send('illustration',figure.dataset.illustration); return;
            }
          });
          // Reuse the text nodes, including when a translation arrives before an existing selection.
          function setChildren(parent,nodes) {
            const keep=new Set(nodes);
            for (const child of [...parent.childNodes]) if (!keep.has(child)) child.remove();
            for (const [index,node] of nodes.entries()) {
              if (parent.childNodes[index]!==node) parent.insertBefore(node,parent.childNodes[index]||null);
            }
          }
          function makePair(id) {
            const span=name=>{
              const node=document.createElement('span');
              node.className=name; node.dataset.sentence=id;
              return node;
            };
            const groupSpan=span('pair'), en=span('en'), zh=span('zh');
            groupSpan.id=id; en.lang='en'; zh.lang='zh-Hans';
            const pending=document.createElement('span');
            pending.className='pending'; pending.textContent='待译';
            return {groupSpan,en,zh,pending,space:document.createTextNode(' ')};
          }
          function makeGroup(id) {
            const group=document.createElement(paragraphMode ? 'section' : 'p');
            group.dataset.group=id;group.dataset.key=id;
            if (paragraphMode) {
              for (const language of ['en','zh-Hans']) {
                const p=document.createElement('p'); p.lang=language; group.append(p);
              }
            }
            return group;
          }
          function makeFigure(item) {
            if (item.originalKind) {
              const node=document.createElement('section');
              node.className='source-text '+item.originalKind;
              if (item.originalKind==='byline' && item.paragraphs.length>1 && item.paragraphs.every(p=>p.includes('\\n'))) {
                node.classList.add('author-cards');
              }
              node.lang='en';
              node.setAttribute('aria-label',item.label || '参考文献续页');
              if (item.originalKind==='references' && item.label) {
                const title=document.createElement('h3');title.textContent=item.label;
                title.className='source-line';title.dataset.sourceGroup=item.id+'-title';node.append(title);
              }
              for (const [index,value] of item.paragraphs.entries()) {
                const p=document.createElement('p');p.textContent=value;p.className='source-line';
                p.dataset.sourceGroup=item.id+'-'+index;node.append(p);
              }
              return {id:item.id,before:item.before,node};
            }
            const node=document.createElement('figure'), button=document.createElement('button');
            button.type='button';
            button.dataset.illustration=item.id;
            const action=item.presentation==='originalPage' || item.presentation==='supplement' ? '打开原 PDF' : '在原页查看'+item.label;
            button.setAttribute('aria-label',action);
            if (item.table) {
              try {
                node.className='reading-table';
                showReadingTable(node,item,button);
                return {id:item.id,before:item.before,node};
              } catch {
                // A failure to place selectable cells must not remove the source crop or later figures.
                node.className='';node.replaceChildren();button.replaceChildren();
              }
            }
            if (item.png) {
              const image=document.createElement('img');
              image.alt=item.label; image.draggable=false;
              if (item.width>0 && item.height>0) {image.width=item.width;image.height=item.height;}
              const previewLabel='放大'+item.label;
              button.dataset.preview=item.label;button.setAttribute('aria-label',previewLabel);
              image.addEventListener('error',()=>{
                delete button.dataset.preview;button.textContent=action;button.setAttribute('aria-label',action);
                button.title=action;
              },{once:true});
              if (item.sourceWidth) image.style.width=(item.sourceWidth/10)+'em';
              image.src='data:image/png;base64,'+item.png;
              button.append(image); button.title=previewLabel;
            } else {
              button.textContent=action;
            }
            if (item.presentation==='supplement') {
              const details=document.createElement('details'), summary=document.createElement('summary');
              details.className='page-supplement';
              summary.textContent=item.label;
              details.append(summary,button);node.append(details);
            } else node.append(button);
            return {id:item.id,before:item.before,node};
          }
          function renderRows(root,rows,pageFigures,changingStructure,note=null) {
            const previous=changingStructure ? new Map() : new Map([...root.querySelectorAll('[data-group]')].map(p=>[p.dataset.group,p]));
            const groups=new Map();
            const beforeSentence=new Map();
            for (const item of pageFigures) {
              if (!beforeSentence.has(item.before)) beforeSentence.set(item.before,[]);
              beforeSentence.get(item.before).push(item.node);
            }
            let groupKey, priorParagraph;
            for (const row of rows) {
              if (row.paragraph!==priorParagraph || beforeSentence.has(row.id)) {
                groupKey=groups.has(row.paragraph) ? row.paragraph+':'+row.id : row.paragraph;
                groups.set(groupKey,[]);priorParagraph=row.paragraph;
              }
              let pair=pairs.get(row.id);
              if (!pair || changingStructure) {
                pair=pair||makePair(row.id);
                pairs.set(row.id,pair);
              }
              pair.group=row.paragraph;pair.sectionKey=groupKey;
              pair.anchorable=!!row.anchorable;
              if (pair.en.textContent!==row.en) pair.en.textContent=row.en;
              if (pair.zh.textContent!==row.zh) pair.zh.textContent=row.zh;
              groups.get(groupKey).push(pair);
            }
            const blocks=note ? [note] : [];
            for (const [id,members] of groups) {
              const anchor=members[0].en.dataset.sentence;
              if (beforeSentence.has(anchor)) {
                blocks.push(...beforeSentence.get(anchor));beforeSentence.delete(anchor);
              }
              const group=previous.get(id)||makeGroup(id);
              if (paragraphMode) {
                const english=[], chinese=[];
                let gap=false;
                for (const pair of members) {
                  if (english.length) english.push(pair.space);
                  english.push(pair.en);
                  if (pair.zh.textContent) chinese.push(pair.zh);
                  else if (!gap) chinese.push(pair.pending);
                  gap=!pair.zh.textContent;
                }
                setChildren(group.firstChild,english);setChildren(group.lastChild,chinese);
              } else {
                for (const pair of members) setChildren(pair.groupSpan,[pair.en,pair.zh]);
                setChildren(group,members.map(pair=>pair.groupSpan));
              }
              blocks.push(group);
            }
            for (const remaining of beforeSentence.values()) blocks.push(...remaining);
            setChildren(root,blocks);
          }
          \(continuousScript)
          window.sentenceReader={
            pageWindow,tableCopied,
            markNotes(marks, highlights=[], inlineEditor=false) {
              const colors={yellow:'pdf-reading-notes',red:'pdf-notes-red',blue:'pdf-notes-blue',green:'pdf-notes-green',purple:'pdf-notes-purple'};
              const ink=new Map(Object.values(colors).map(name=>[name,[]]));
              for (const color of Object.keys(\(HTMLAnnotationMenuScript.colors))) for (const style of ['highlight','underline']) ink.set('pdf-'+color+'-'+style,[]);
              projectedInk=[];
              inlineNoteRanges=new WeakMap();
              const lastButton=new Map(),located=new Set(marks.filter(m=>m.ranges.length).map(m=>m.note));
              for (const button of main.querySelectorAll('[data-reading-note]')) button.remove();
              for (const [index,mark] of [...marks,...highlights].entries()) {
                const isHighlight=index>=marks.length;
                const language=mark.language || 'en', span=pairs.get(mark.sentence)?.[language], text=span?.firstChild;
                if (!span?.isConnected || text?.nodeType!==Node.TEXT_NODE) continue;
                for (const [start,end] of mark.ranges) {
                  if (start<0 || end<=start || end>text.length) continue;
                  const range=document.createRange();range.setStart(text,start);range.setEnd(text,end);
                  if (!inlineNoteRanges.has(span)) inlineNoteRanges.set(span,[]);
                  const hits=inlineNoteRanges.get(span);
                  if (!isHighlight && inlineEditor) {
                    // The shared card draws its own note wave. A reading note alone never adds highlight ink.
                    hits.push({id:mark.note,range,shared:true});
                    continue;
                  }
                  const color=mark.color||'yellow',style=mark.style||'highlight';
                  const name=isHighlight?'pdf-'+color+'-'+style:colors[color]??colors.yellow;
                  ink.get(name)?.push(range);
                  if (isHighlight) projectedInk.push({key:mark.sentence,target:language,range:[start,end],color,style});
                  hits.push({id:mark.note,range,name,color:isHighlight?highlightColors[color]:'var(--pdf-note-'+color+')',
                    kind:isHighlight?style:'highlight',fragments:[range],action:isHighlight?'openHighlight':'note'});
                }
                if (!isHighlight && paragraphMode && (!inlineEditor || !located.has(mark.note))) {
                  const button=document.createElement('button');button.type='button';button.className='sentence-note';
                  button.dataset.readingNote=mark.note;button.setAttribute('aria-label','打开阅读笔记');
                  button.title='打开阅读笔记';(lastButton.get(span) ?? span).after(button);lastButton.set(span,button);
                }
              }
              if (window.CSS?.highlights) for (const [name,ranges] of ink) CSS.highlights.set(name,new Highlight(...ranges));
              window.paperNoteLayout?.invalidate();window.paperNotes?.layout();
              tools.refresh();
            },
            render(rows,layout,items) {
              const changingStructure=paragraphMode!==(layout==='paragraph');
              if (flow) {flow=null;figures=[];main.replaceChildren();}
              const selection=getSelection();
              const {anchorNode,anchorOffset,focusNode,focusOffset}=selection;
              paragraphMode=layout==='paragraph';
              document.body.className=layout;
              main.setAttribute('aria-label',paragraphMode ? '本页段落对照' : '本页段落译文');
              if (items) figures=items.map(makeFigure);
              const incoming=new Set(rows.map(row=>row.id));
              for (const id of pairs.keys()) if (!incoming.has(id)) pairs.delete(id);
              renderRows(main,rows,figures,changingStructure);
              if (changingStructure) {
                if (anchorNode?.nodeType===Node.TEXT_NODE && focusNode?.nodeType===Node.TEXT_NODE
                    && anchorNode.isConnected && focusNode.isConnected
                    && anchorNode.parentElement.getClientRects().length && focusNode.parentElement.getClientRects().length) {
                  selection.setBaseAndExtent(anchorNode,anchorOffset,focusNode,focusOffset);
                }
              }
            },
            show(fontSize) {
              document.documentElement.style.setProperty('--zh-size',fontSize+'px');
              updateTableWidths();
            }
          };
        })();
        """
}
