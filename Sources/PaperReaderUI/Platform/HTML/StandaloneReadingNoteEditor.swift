import PaperReaderKit
import SwiftUI
import WebKit

/// Shared standalone presentation for PDF notes and the full-paper closing page.
@MainActor struct StandaloneReadingNoteEditor {
    let model: ReaderModel
    let note: ReadingNote
    var readOnly = false
    var onDone: (() -> Void)?
    var citationRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let editor: StandaloneReadingNoteEditor
        private let renderer = NoteMarkdownRenderer()
        private weak var view: WKWebView?
        private var previewTask: Task<Void, Never>?
        private var source: String
        private var ready = false
        private var lastRequest = 0
        private var pendingRequest = 0

        init(_ editor: StandaloneReadingNoteEditor) {
            self.editor = editor
            lastRequest = editor.citationRequest
            pendingRequest = editor.citationRequest
            source =
                editor.model.currentReadingNotes.first { $0.id == editor.note.id }?.markdown
                ?? editor.note.markdown
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
                const host = document.querySelector('.note-editor');
                document.body.classList.toggle('summary-page', summary);
                if (readOnly) {
                    host.className = 'note-content';
                    host.style.whiteSpace = 'pre-wrap';
                    host.textContent = source;
                } else {
                    window.pdfEditor = window.PaperNoteEditor.create(host, source,
                        text => send({text}), () => send({done:true}));
                    window.pdfEditor.focus();
                }
                window.PaperNoteEditor.bindPassages(document, passage => send({passage}));
                """
            webView.callAsyncJavaScript(
                js,
                arguments: ["source": source, "readOnly": editor.readOnly, "summary": editor.note.isDocumentSummary],
                in: nil, in: .defaultClient
            ) {
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
            let note = editor.note
            let displayed =
                note.isDocumentSummary ? editor.model.presentedDocumentSummary?.id : editor.model.pdfNoteEditor?.id
            guard message.frameInfo.isMainFrame, displayed == note.id,
                note.paperID == editor.model.selectedPaperID,
                let value = message.body as? [String: Any]
            else { return }
            if !editor.readOnly, value["pick"] as? Bool == true, let source = value["markdown"] as? String,
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
            } else if !editor.readOnly, let text = value["text"] as? String {
                let saved =
                    note.isDocumentSummary
                    ? editor.model.updateDocumentSummary(id: note.id, markdown: text)
                    : editor.model.updateReadingNote(id: note.id, anchors: note.anchors, markdown: text)
                if saved {
                    source = text
                    preview()
                }
            } else if value["done"] as? Bool == true {
                if let onDone = editor.onDone { onDone() } else { editor.model.closePDFReadingNote() }
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
                        editor.model.currentReadingNotes.first { $0.id == editor.note.id }?.citations?.map(\.id)
                        ?? []
                    let html = try await renderer.renderReadingNote(expected, passageIDs: Set(ids))
                    try Task.checkCancellation()
                    guard expected == source, let view else { return }
                    view.callAsyncJavaScript(
                        """
                        if (window.pdfEditor) window.pdfEditor.preview(source, html);
                        else { const body = document.querySelector('.note-content'); body.innerHTML = html; body.style.whiteSpace = 'normal'; }
                        """, arguments: ["source": expected, "html": html],
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
            .note-editor{height:100%}
            .summary-page article.reader-note-card.active{background:transparent}
            .summary-page article.reader-note-card .note-content,.summary-page article.reader-note-card .cm-scroller{box-sizing:border-box;padding:32px max(24px,calc((100vw - 660px)/2)) 64px;font:17px/1.8 system-ui}
            .summary-page .note-content h1{font:600 1.65em/1.35 ui-serif,serif;margin:0 0 1.2em}
            .summary-page .note-content p{margin:0 0 1.15em}</style></head><body><article class="reader-note-card active"><div class="note-editor"></div></article></body></html>
            """
    }
}

#if os(macOS)
    extension StandaloneReadingNoteEditor: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateNSView(_ view: WKWebView, context: Context) {
            context.coordinator.updateCitationRequest(citationRequest, in: view)
        }
        static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#else
    extension StandaloneReadingNoteEditor: UIViewRepresentable {
        func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateUIView(_ view: WKWebView, context: Context) {
            context.coordinator.updateCitationRequest(citationRequest, in: view)
        }
        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#endif
