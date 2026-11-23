import PaperReaderKit
import SwiftUI
import WebKit

/// The source PDF hosts the same bundled Markdown editor, styles and offline formula compiler as HTML margin notes.
@MainActor struct PDFReadingNoteEditor {
    let model: ReaderModel
    let session: PDFNoteEditorSession
    var citationRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let editor: PDFReadingNoteEditor
        private let renderer = NoteMarkdownRenderer()
        private weak var view: WKWebView?
        private var previewTask: Task<Void, Never>?
        private var source: String
        private var ready = false
        private var lastRequest = 0
        private var pendingRequest = 0

        init(_ editor: PDFReadingNoteEditor) {
            self.editor = editor
            lastRequest = editor.citationRequest
            pendingRequest = editor.citationRequest
            source =
                editor.model.currentReadingNotes.first { $0.id == editor.session.id }?.markdown
                ?? editor.session.note.markdown
        }

        func makeView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            let content = config.userContentController
            content.add(self, contentWorld: .defaultClient, name: "pdfNote")
            for script in [HTMLNativeNoteEditorScript.source, HTMLNoteStyle.source] {
                content.addUserScript(
                    WKUserScript(
                        source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
            }
            let view = WKWebView(frame: .zero, configuration: config)
            self.view = view
            view.navigationDelegate = self
            view.loadHTMLString(Self.document, baseURL: nil)
            return view
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy
        {
            action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let js = """
                const send = message => window.webkit.messageHandlers.pdfNote.postMessage(message);
                window.pdfEditor = window.PaperNoteEditor.create(document.querySelector('.note-editor'), source,
                    text => send({text}), () => send({done:true}));
                window.PaperNoteEditor.bindPassages(document, passage => send({passage}));
                window.pdfEditor.focus();
                """
            webView.callAsyncJavaScript(js, arguments: ["source": source], in: nil, in: .defaultClient) {
                [weak self] result in
                guard let self else { return }
                if case .failure = result {
                    editor.model.message = "笔记编辑器暂未就绪，请重新打开。"
                    return
                }
                ready = true
                updateCitationRequest(pendingRequest, in: webView)
                preview()
            }
        }

        func updateCitationRequest(_ request: Int, in view: WKWebView) {
            pendingRequest = request
            guard ready, request != lastRequest else { return }
            lastRequest = request
            let script = """
                const e=window.pdfEditor;
                window.webkit.messageHandlers.pdfNote.postMessage({pick:true,markdown:e.value,from:e.selectionStart,to:e.selectionEnd});
                """
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            let note = editor.session.note
            guard message.frameInfo.isMainFrame, editor.model.pdfNoteEditor?.id == note.id,
                note.paperID == editor.model.selectedPaperID,
                let value = message.body as? [String: Any]
            else { return }
            if value["pick"] as? Bool == true, let source = value["markdown"] as? String,
                let from = value["from"] as? Int, let to = value["to"] as? Int
            {
                editor.model.pickNotePassage(noteID: note.id, anchors: note.anchors, source: source, from: from, to: to)
                {
                    [weak self] link in
                    guard let self, let view else { return }
                    view.callAsyncJavaScript(
                        "window.pdfEditor?.insertPassage(source,from,to,link)",
                        arguments: ["source": source, "from": from, "to": to, "link": link], in: nil,
                        in: .defaultClient, completionHandler: nil)
                }
            } else if let raw = value["passage"] as? String, let passage = UUID(uuidString: raw) {
                editor.model.presentNotePassage(noteID: note.id, citationID: passage)
            } else if let text = value["text"] as? String {
                if editor.model.updateReadingNote(id: note.id, anchors: note.anchors, markdown: text) {
                    source = text
                    preview()
                }
            } else if value["done"] as? Bool == true {
                editor.model.closePDFReadingNote()
            }
        }

        private func preview() {
            previewTask?.cancel()
            let expected = source
            previewTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    let ids =
                        editor.model.currentReadingNotes.first { $0.id == editor.session.id }?.citations?.map(\.id)
                        ?? []
                    let html = try await renderer.renderReadingNote(expected, passageIDs: Set(ids))
                    try Task.checkCancellation()
                    guard expected == source, let view else { return }
                    view.callAsyncJavaScript(
                        "window.pdfEditor?.preview(source,html)", arguments: ["source": expected, "html": html],
                        in: nil, in: .defaultClient, completionHandler: nil)
                } catch {}
            }
        }

        func stop() {
            previewTask?.cancel()
            view?.configuration.userContentController.removeScriptMessageHandler(
                forName: "pdfNote", contentWorld: .defaultClient)
        }

        private static let document = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none';style-src 'unsafe-inline';base-uri 'none';form-action 'none'">
            <style>html,body{margin:0;height:100%;overflow:hidden;color-scheme:light dark}
            body article.reader-note-card.active{position:static;border:0;box-shadow:none;border-radius:0;width:100%;max-width:none;max-height:none;height:100%;transform:none}
            .note-editor{height:100%}</style></head><body><article class="reader-note-card active"><div class="note-editor"></div></article></body></html>
            """
    }
}

#if os(macOS)
    extension PDFReadingNoteEditor: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateNSView(_ view: WKWebView, context: Context) {
            context.coordinator.updateCitationRequest(citationRequest, in: view)
        }
        static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#else
    extension PDFReadingNoteEditor: UIViewRepresentable {
        func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateUIView(_ view: WKWebView, context: Context) {
            context.coordinator.updateCitationRequest(citationRequest, in: view)
        }
        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#endif
