import PaperReaderKit
import SwiftUI
import WebKit

/// Both sidebar conversations use the same local Markdown and MathML compiler as reading notes.
struct AssistantMarkdownText: View {
    let markdown: String
    var citationIDs: Set<String> = []
    var onCitations: ([String]) -> Void = { _ in }
    var onCitation: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
        @ScaledMetric(relativeTo: .callout) private var fontSize: CGFloat = 13
    #else
        @ScaledMetric(relativeTo: .callout) private var fontSize: CGFloat = 16
    #endif
    @State private var height: CGFloat?

    var body: some View {
        if AssistantAnswerPresentation.usesNativeText(markdown) {
            plainText.lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear { onCitations([]) }
        } else {
            let request = AssistantMarkdownCanvas.Request(markdown: markdown, ids: citationIDs)
            AssistantAnswerLayout(
                height: height,
                restored: height == nil ? AssistantPageCache.snapshot(for: request)?.measurement : nil,
                fontSize: fontSize
            ) {
                if height == nil { plainText }
                AssistantMarkdownCanvas(
                    request: request, fontSize: fontSize, dark: colorScheme == .dark,
                    onHeight: { if height != $0 { height = $0 } }, onCitations: onCitations, onCitation: onCitation
                )
                .opacity(height == nil ? 0 : 1)
            }
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var plainText: some View {
        Text(verbatim: markdown).font(.system(size: fontSize)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor struct AssistantMarkdownCanvas {
    struct Request: Equatable {
        let markdown: String
        let ids: Set<String>
    }
    let request: Request
    let fontSize: CGFloat
    let dark: Bool
    let onHeight: (CGFloat) -> Void
    let onCitations: ([String]) -> Void
    let onCitation: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private static let renderer = NoteMarkdownRenderer()
        private static let dataStore = WKWebsiteDataStore.nonPersistent()
        private var parent: AssistantMarkdownCanvas
        private weak var view: WKWebView?
        private var ready = false
        private var task: Task<Void, Never>?
        private var displayed: Request?
        private var answer: RenderedAssistantAnswer?
        private var measurement: AssistantAnswerMeasurement?
        private var installing = false
        private var reloaded = false
        private var resetSelection = false

        init(_ parent: AssistantMarkdownCanvas) { self.parent = parent }

        func makeView() -> WKWebView {
            if let page = AssistantPageCache.take(for: parent.request) {
                let view = page.view
                self.view = view
                view.navigationDelegate = self
                view.configuration.userContentController.add(self, contentWorld: .defaultClient, name: "answer")
                ready = true
                // A reused view can contain another conversation until the next DOM update.
                setVisible(false, in: view)
                if page.displayed == parent.request, let cached = AssistantPageCache.snapshot(for: page.displayed) {
                    displayed = page.displayed
                    answer = cached.answer
                    measurement = page.measurement
                } else {
                    resetSelection = true
                }
                Task { @MainActor [weak self] in
                    guard let self, ready else { return }
                    applyStyle()
                    if displayed == parent.request, let answer {
                        do {
                            _ = try await view.callAsyncJavaScript(
                                "window.reportAnswerSize(true);", arguments: [:],
                                in: nil, contentWorld: .defaultClient)
                        } catch {
                            if ready { reloadDocument(view) }
                            return
                        }
                        guard ready, displayed == parent.request else { return }
                        parent.onCitations(answer.citations)
                        setVisible(true, in: view)
                    }
                    renderPending()
                }
                return view
            }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = Self.dataStore
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            config.userContentController.add(self, contentWorld: .defaultClient, name: "answer")
            config.userContentController.addUserScript(
                WKUserScript(
                    source: AssistantMarkdownCanvas.script, injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true, in: .defaultClient))
            #if os(macOS)
                let view = SidebarAnswerWebView(frame: .zero, configuration: config)
            #else
                let view = WKWebView(frame: .zero, configuration: config)
                view.isOpaque = false
                view.scrollView.isScrollEnabled = false
            #endif
            self.view = view
            view.navigationDelegate = self
            view.underPageBackgroundColor = .clear
            view.loadHTMLString(AssistantMarkdownCanvas.document, baseURL: nil)
            return view
        }

        func update(_ parent: AssistantMarkdownCanvas) {
            let restyle = self.parent.dark != parent.dark || self.parent.fontSize != parent.fontSize
            self.parent = parent
            if ready && restyle { applyStyle() }
            renderPending()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            applyStyle()
            renderPending()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reloadDocument(webView)
        }

        private func reloadDocument(_ webView: WKWebView) {
            ready = false
            task?.cancel()
            task = nil
            displayed = nil
            answer = nil
            installing = false
            webView.loadHTMLString(AssistantMarkdownCanvas.document, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank"
                ? .allow : .cancel
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard ready, message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            if displayed != nil || installing, let height = body["height"] as? Double, height.isFinite, height > 0,
                let width = body["width"] as? Double, width.isFinite, width > 0,
                let size = body["fontSize"] as? Double, abs(size - parent.fontSize) < 0.02
            {
                measurement = .init(width: width, height: ceil(height), fontSize: parent.fontSize)
                parent.onHeight(ceil(height))
            } else if displayed == parent.request, let id = body["citation"] as? String, parent.request.ids.contains(id)
            {
                parent.onCitation(id)
            }
        }

        private func setVisible(_ visible: Bool, in view: WKWebView) {
            #if os(macOS)
                view.alphaValue = visible ? 1 : 0
            #else
                view.alpha = visible ? 1 : 0
            #endif
        }

        private func applyStyle() {
            view?.callAsyncJavaScript(
                "document.documentElement.style.colorScheme=scheme;document.body.style.fontSize=size+'px';",
                arguments: ["scheme": parent.dark ? "dark" : "light", "size": parent.fontSize],
                in: nil, in: .defaultClient, completionHandler: nil)
        }

        private func renderPending() {
            guard ready, task == nil, displayed != parent.request else { return }
            task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, ready, displayed != parent.request, let view {
                    let request = parent.request
                    let result: RenderedAssistantAnswer?
                    if let cached = AssistantPageCache.snapshot(for: request) {
                        result = cached.answer
                    } else {
                        result = try? await Self.renderer.renderAssistant(request.markdown, citationIDs: request.ids)
                    }
                    guard !Task.isCancelled else { return }
                    installing = true
                    do {
                        _ = try await view.callAsyncJavaScript(
                            "window.replaceAnswer(html, plain, reset);",
                            arguments: [
                                "html": result?.html ?? "", "plain": result == nil ? request.markdown : "",
                                "reset": resetSelection,
                            ],
                            in: nil, contentWorld: .defaultClient)
                    } catch {
                        installing = false
                        if !Task.isCancelled, !reloaded {
                            reloaded = true
                            reloadDocument(view)
                        }
                        break
                    }
                    if Task.isCancelled { return }
                    installing = false
                    displayed = request
                    reloaded = false
                    resetSelection = false
                    answer = result
                    setVisible(true, in: view)
                    parent.onCitations(result?.citations ?? [])
                    // Keep output visible during long streams. Coalesce intervening token updates.
                    try? await Task.sleep(for: .milliseconds(125))
                }
                if !Task.isCancelled { task = nil }
            }
        }

        func stop() {
            let mayRetire = ready && !installing
            ready = false
            task?.cancel()
            task = nil
            view?.configuration.userContentController.removeScriptMessageHandler(
                forName: "answer", contentWorld: .defaultClient)
            view?.navigationDelegate = nil
            if mayRetire, let view, let displayed, let answer {
                AssistantPageCache.retire(
                    view, snapshot: .init(request: displayed, answer: answer, measurement: measurement))
            }
            self.view = nil
        }
    }

    private static let document = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none';style-src 'unsafe-inline';base-uri 'none';form-action 'none'">
        <style>
        :root{color-scheme:light dark}*{box-sizing:border-box}
        body{margin:0;background:light-dark(#f9f8f3,#23221e);color:light-dark(#292822,#f0eee7);
        font:13px/1.55 -apple-system,system-ui,sans-serif;overflow-wrap:anywhere}
        main{display:flow-root;min-width:0}main>:first-child{margin-top:0}main>:last-child{margin-bottom:0}
        p,ul,ol,blockquote,pre,table,hr{margin:.65em 0}h1,h2,h3,h4,h5,h6{line-height:1.3;margin:.85em 0 .4em}
        h1{font-size:1.4em}h2{font-size:1.24em}h3{font-size:1.1em}h4,h5,h6{font-size:1em}
        li>p{margin:.2em 0}ul,ol{padding-inline-start:1.6em}li+li{margin-top:.22em}
        code{font: .93em ui-monospace,monospace;background:light-dark(#ede8dd,#35322b);border-radius:.2em;padding:0 .2em}
        pre{background:light-dark(#ede8dd,#35322b);border-radius:6px;padding:.65em;overflow:auto}pre code{padding:0;background:none}
        table{border-collapse:collapse;display:block;max-width:100%;overflow-x:auto}th,td{padding:.3em .55em;border:1px solid light-dark(#dfddd3,#44413a);text-align:left}
        th{background:light-dark(#ede8dd,#35322b)}blockquote{padding-left:.8em;border-left:2px solid light-dark(#b89e8e,#80695a)}
        hr{border:0;border-top:1px solid light-dark(#dfddd3,#44413a)}
        a[data-citation]{color:light-dark(#9f503a,#e8a086);text-decoration:underline;text-underline-offset:2px}
        .note-math:has(math[display=block]){display:block;max-width:100%;overflow-x:auto;padding:.2em 0}
        .note-math math{font-size:1.05em}.note-math:has(math:not([display=block])){display:inline-block;max-width:100%;vertical-align:middle;overflow-x:auto}
        </style></head><body><main></main></body></html>
        """

    private static let script = """
        const content=document.querySelector('main');
        let lastSize='';
        const report=window.reportAnswerSize=(force=false)=>{
          const {width,height}=content.getBoundingClientRect(),fontSize=parseFloat(getComputedStyle(document.body).fontSize);
          const key=width+'|'+height+'|'+fontSize;
          if(width<=0 || height<=0 || (!force && key===lastSize))return;
          lastSize=key;window.webkit.messageHandlers.answer?.postMessage({width,height,fontSize});
        };
        new ResizeObserver(()=>report()).observe(content);
        content.addEventListener('click',e=>{
          const a=e.target.closest('a[data-citation]');if(!a)return;
          e.preventDefault();window.webkit.messageHandlers.answer.postMessage({citation:a.dataset.citation});
        });
        window.replaceAnswer=(html,plain,reset)=>{
          if(reset){getSelection()?.removeAllRanges();content.replaceChildren();}
          const template=document.createElement('template');
          if(plain){const p=document.createElement('p');p.style.whiteSpace='pre-wrap';p.textContent=plain;template.content.append(p);}
          else template.innerHTML=html;
          const next=Array.from(template.content.childNodes);
          let i=0;while(i<next.length&&content.childNodes[i]?.isEqualNode(next[i]))i++;
          while(content.childNodes.length>i)content.lastChild.remove();
          for(;i<next.length;i++)content.append(next[i]);
          // A new owner also needs the current size when the old and new heights match.
          report(reset);
        };
        """
}

#if os(macOS)
    private final class SidebarAnswerWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                nextResponder?.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    extension AssistantMarkdownCanvas: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
        static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#else
    extension AssistantMarkdownCanvas: UIViewRepresentable {
        func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#endif
