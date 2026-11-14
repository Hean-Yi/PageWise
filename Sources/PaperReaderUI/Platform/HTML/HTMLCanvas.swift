import PaperReaderKit
import SwiftUI
import WebKit

struct HTMLCanvas: View {
    let model: ReaderModel
    var body: some View { PlatformHTML(model: model) }
}

#if os(macOS)
    private struct PlatformHTML: NSViewRepresentable {
        let model: ReaderModel
        func makeCoordinator() -> HTMLCoordinator { HTMLCoordinator(model: model) }
        func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(view) }
        static func dismantleNSView(_ view: WKWebView, coordinator: HTMLCoordinator) { coordinator.stop(view) }
    }
#else
    private struct PlatformHTML: UIViewRepresentable {
        let model: ReaderModel
        func makeCoordinator() -> HTMLCoordinator { HTMLCoordinator(model: model) }
        func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(view) }
        static func dismantleUIView(_ view: WKWebView, coordinator: HTMLCoordinator) { coordinator.stop(view) }
    }
#endif

@MainActor
final class HTMLCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let model: ReaderModel
    private var paperID: UUID?
    private var loadedPath: String?
    private var requestedURL: URL?
    private var keys: [String] = []
    private var publishedCount = 0
    private var ready = false
    private var stopped = false
    private var appendTask: Task<Void, Never>?
    private var highlightIDs: [UUID] = []
    private var draftHTML = ""
    private var leasedURL: URL?

    init(model: ReaderModel) { self.model = model }

    func makeView() -> WKWebView {
        let view = HTMLWebViewPool.take()
        let config = view.configuration
        config.userContentController.add(self, contentWorld: .defaultClient, name: "reader")
        config.userContentController.addUserScript(
            WKUserScript(
                source: HTMLReaderScript.source,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func stop(_ view: WKWebView) {
        stopped = true
        ready = false
        appendTask?.cancel()
        view.stopLoading()
        releaseDocument()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: "reader", contentWorld: .defaultClient)
        HTMLWebViewPool.recycle(view)
    }

    func update(_ view: WKWebView) {
        guard !stopped, model.usesHTMLReading, let paper = model.paper, let artifact = paper.htmlReading else { return }
        if paperID != paper.id || loadedPath == nil || !artifact.sections.map({ $0.id.uuidString }).starts(with: keys) {
            appendTask?.cancel()
            view.stopLoading()
            releaseDocument()
            paperID = paper.id
            loadedPath = artifact.relativePath
            keys = artifact.sections.map { $0.id.uuidString }
            publishedCount = paper.translatedBlockCount
            highlightIDs = []
            draftHTML = ""
            ready = false
            view.isHidden = true
            let url = model.root.appendingPathComponent(artifact.relativePath).standardizedFileURL
            requestedURL = url
            HTMLReadingStore.retainOpenDocument(url)
            leasedURL = url
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        guard ready else { return }
        if loadedPath != artifact.relativePath, appendTask == nil {
            let changed = Set(
                paper.blocks.dropFirst(publishedCount).prefix(max(0, paper.translatedBlockCount - publishedCount)).map {
                    $0.id.uuidString
                })
            let oldKeys = Set(keys).subtracting(changed)
            let expectedID = paper.id
            let url = model.root.appendingPathComponent(artifact.relativePath).standardizedFileURL
            appendTask = Task { [weak self, weak view] in
                guard let self, let view else { return }
                defer {
                    self.appendTask = nil
                    if self.model.paper?.htmlReading?.relativePath != artifact.relativePath { self.update(view) }
                }
                do {
                    let html = try await HTMLReadingStore().appendedContent(at: url, excluding: oldKeys)
                    try Task.checkCancellation()
                    guard self.paperID == expectedID else { return }
                    _ = try await view.callAsyncJavaScript(
                        "window.paperReader.append(html, paperID)",
                        arguments: ["html": html, "paperID": expectedID.uuidString],
                        in: nil, contentWorld: .defaultClient)
                    guard self.paperID == expectedID, !Task.isCancelled else { return }
                    self.loadedPath = artifact.relativePath
                    self.keys = artifact.sections.map { $0.id.uuidString }
                    self.publishedCount = paper.translatedBlockCount
                    self.highlightIDs = []
                    self.updateState(view)
                } catch is CancellationError {} catch {
                    if self.model.paper?.htmlReading?.relativePath == artifact.relativePath {
                        self.model.message = "新增阅读内容未能显示，已保存的内容仍保留；请重新打开论文。"
                    }
                }
            }
        }
        updateState(view)
    }

    private func releaseDocument() {
        if let leasedURL {
            HTMLReadingStore.releaseOpenDocument(leasedURL)
            if let paper = model.state.papers.first(where: { $0.id == paperID }) {
                try? HTMLReadingStore.cleanup(root: model.root, paper: paper)
            }
            self.leasedURL = nil
        }
    }

    private func updateState(_ view: WKWebView) {
        guard ready, model.selectedPaperID == paperID else { return }
        let draft = model.translationDraft.flatMap { $0.paperID == paperID ? $0.html : nil } ?? ""
        if draftHTML != draft {
            draftHTML = draft
            view.callAsyncJavaScript(
                "window.paperReader.draft(html, paperID)", arguments: ["html": draft, "paperID": paperID!.uuidString],
                in: nil, in: .defaultClient, completionHandler: nil)
        }
        let marks = model.currentHighlights.filter { $0.textRange != nil }
        if highlightIDs != marks.map(\.id) {
            highlightIDs = marks.map(\.id)
            let values: [[String: Any]] = marks.map {
                ["key": $0.pageKey, "text": $0.text, "range": $0.textRange ?? []]
            }
            view.callAsyncJavaScript(
                "window.paperReader.highlights(marks)", arguments: ["marks": values], in: nil,
                in: .defaultClient, completionHandler: nil)
        }
        if let index = model.jumpPage, keys.indices.contains(index) {
            view.callAsyncJavaScript(
                "window.paperReader.jump(key)", arguments: ["key": keys[index]], in: nil,
                in: .defaultClient, completionHandler: nil)
            Task { @MainActor [weak self] in
                guard let self, self.model.selectedPaperID == self.paperID, self.model.jumpPage == index else { return }
                self.model.recordVisiblePage(index)
                self.model.jumpPage = nil
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.standardizedFileURL == requestedURL, paperID == model.selectedPaperID else { return }
        ready = true
        webView.isHidden = false
        if keys.indices.contains(model.visiblePage) {
            webView.callAsyncJavaScript(
                "window.paperReader.jump(key)", arguments: ["key": keys[model.visiblePage]],
                in: nil, in: .defaultClient, completionHandler: nil)
        }
        update(webView)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(
            action.navigationType == .other && action.request.url?.standardizedFileURL == requestedURL
                ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        if loadedPath != model.paper?.htmlReading?.relativePath {
            loadedPath = nil
            update(webView)
        } else {
            model.message = "阅读内容加载失败：\(error.localizedDescription)"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        model.message = "阅读进程已结束，请重新打开论文。已保存的阅读内容和批注仍保留。"
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, model.selectedPaperID == paperID, model.usesHTMLReading,
            let value = message.body as? [String: Any], let kind = value["kind"] as? String
        else { return }
        let index = (value["key"] as? String).flatMap { keys.firstIndex(of: $0) }
        switch kind {
        case "position":
            if ready, let index { model.recordVisiblePage(index) }
        case "selection":
            guard let text = value["text"] as? String, !text.isEmpty, let index,
                let start = value["start"] as? Int, let end = value["end"] as? Int, start >= 0, end > start
            else {
                model.captureSelection(text: "", rects: [], page: model.visiblePage)
                return
            }
            model.captureSelection(text: text, rects: [], page: index)
            model.selectionHTMLRange = [start, end]
        case "crossSelection":
            model.captureSelection(text: "", rects: [], page: model.visiblePage)
            model.status = "跨段文字可以复制；高亮或解释请在一个内容段内选择，以保留准确来源。"
        case "imageError": model.message = "部分图片未能显示，请切换原版查看完整内容。"
        case "missingLink": model.message = "引用目标尚未生成，完成对应段落后即可跳转；也可以切换原版查看。"
        case "externalLink":
            guard let value = value["url"] as? String, let url = URL(string: value),
                ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil
            else { return }
            #if os(macOS)
                NSWorkspace.shared.open(url)
            #else
                UIApplication.shared.open(url)
            #endif
        default: break
        }
    }
}
