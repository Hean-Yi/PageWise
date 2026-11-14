import Foundation
import PDFKit
import WebKit

/// Uses only application-owned HTML and CSS; the web view has no persistent cache or network access.
@MainActor
public final class StructuredPageRenderer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?
    private var webView: WKWebView?
    private var rendering = false

    public override init() { super.init() }

    public func render(_ pairs: [BilingualBlock], to directory: URL, originalURL: URL) async throws -> [PageArtifact] {
        guard !rendering else { throw ReaderError.message("当前排版尚未完成，请稍后重试。") }
        rendering = true
        defer { rendering = false }
        let staging = directory.appendingPathComponent(".render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var artifacts: [PageArtifact] = []
        var pendingText: [BilingualBlock] = []
        var pendingRich: [BilingualBlock] = []
        func flushText() throws {
            if !pendingText.isEmpty {
                artifacts += try PageRenderer().render(pendingText, to: staging, prefix: "text")
                pendingText = []
            }
        }
        func flushRich() async throws {
            if !pendingRich.isEmpty {
                artifacts += try await renderHTML(pendingRich, to: staging)
                pendingRich = []
            }
        }
        for pair in pairs {
            try Task.checkCancellation()
            if pair.block.preservesSourcePage == true {
                try flushText()
                try await flushRich()
                guard let source = PDFDocument(url: originalURL), let page = source.page(at: pair.block.sourcePage),
                    let bytes = page.dataRepresentation, let checked = PDFDocument(data: bytes), checked.pageCount == 1,
                    checked.page(at: 0)?.bounds(for: .mediaBox) == page.bounds(for: .mediaBox)
                else { throw ReaderError.message("原始页面无法完整保留，未发布重排页。") }
                let name = "source-\(UUID().uuidString).pdf"
                try bytes.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
                artifacts.append(
                    PageArtifact(blockIDs: [pair.block.id], sourcePage: pair.block.sourcePage, relativePath: name))
            } else if pair.block.richContent != nil {
                try flushText()
                pendingRich.append(pair)
            } else {
                try await flushRich()
                pendingText.append(pair)
            }
        }
        try flushText()
        try await flushRich()
        try Task.checkCancellation()
        var published: [URL] = []
        do {
            for artifact in artifacts {
                let target = directory.appendingPathComponent(artifact.relativePath)
                try FileManager.default.moveItem(at: staging.appendingPathComponent(artifact.relativePath), to: target)
                published.append(target)
            }
        } catch {
            for url in published { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return artifacts
    }

    private func renderHTML(_ pairs: [BilingualBlock], to directory: URL) async throws -> [PageArtifact] {
        let content = try pairs.map { pair -> String in
            guard let rich = pair.block.richContent else { throw ReaderError.message("结构化内容缺失。") }
            var translated = ""
            if let translation = pair.translation {
                try rich.validate(translation)
                translated = HTMLPaperParser.escape(translation).replacingOccurrences(of: "\n", with: "<br>")
                for (marker, math) in rich.mathematics {
                    translated = translated.replacingOccurrences(of: marker, with: math)
                }
                translated = "<div class='translation'>\(translated)</div>"
            }
            return "<section data-block='\(pair.block.id.uuidString)'>\(rich.html)\(translated)</section>"
        }.joined()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
        webView = view
        view.navigationDelegate = self
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
            webView = nil
        }
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
            <style>
            * { box-sizing:border-box } html,body { margin:0; padding:0; background:#fdfbf5; color:#292e2e; }
            #flow { position:absolute; left:56px; top:72px; width:500px; height:648px; column-width:500px; column-gap:112px; column-fill:auto; font:15px/1.6 Georgia,serif; overflow-wrap:break-word; }
            section { break-inside:avoid; margin-bottom:16px; }
            p,div,figure,pre,blockquote { margin:0 0 14px } h1,h2,h3,h4,h5,h6 { font:600 19px/1.4 Georgia,serif; margin:0 0 14px; }
            img { max-width:100%; max-height:500px; object-fit:contain; } figure,table,math[display=block],pre { break-inside:avoid; }
            figure { margin:0 0 14px; } figcaption { font-size:13px; } table { width:100%; border-collapse:collapse; font-size:13px; } td,th { padding:4px; border:1px solid #bbb; }
            pre { white-space:pre-wrap; font:12px/1.5 monospace; } math { font-size:1em; } .translation { color:#305c5c; font-family:'PingFang SC',sans-serif; padding-left:14px; border-left:1px solid #9db5ae; }
            </style></head><body><main id="flow">\(content)</main></body></html>
            """
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, any Error>) in
                continuation = value
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(.failure(ReaderError.message("排版加载超时，已保留原文与完成页面。")))
                }
                view.loadHTMLString(html, baseURL: nil)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
        let script = """
            (() => {
              const flow = document.getElementById('flow');
              if ([...document.images].some(i => !i.complete || i.naturalWidth === 0)) return JSON.stringify({error:1});
              const rects=[]; const walker=document.createTreeWalker(flow,NodeFilter.SHOW_TEXT);
              while(walker.nextNode()) {
                if (!walker.currentNode.textContent.trim()) continue;
                const r=document.createRange(); r.selectNodeContents(walker.currentNode);
                rects.push(...r.getClientRects());
              }
              for (const e of flow.querySelectorAll('img,table,math,pre')) rects.push(...e.getClientRects());
              let count=1;
              for(const r of rects) {
                if(r.width===0 || r.height===0) continue;
                const page=Math.floor((r.left-55)/612); count=Math.max(count,page+1);
                if(page<0 || r.left<56+page*612-1 || r.right>556+page*612+1 || r.top<71 || r.bottom>721) return JSON.stringify({error:2});
              }
              const pages = Array.from({length:count},()=>[]);
              for (const section of flow.children) {
                for (const r of section.getClientRects()) {
                  const page=Math.floor((r.left-55)/612);
                  if(page>=0 && page<count && !pages[page].includes(section.dataset.block)) pages[page].push(section.dataset.block);
                }
              }
              return JSON.stringify({pages:pages});
            })()
            """
        let metrics: String = try await withCheckedThrowingContinuation { value in
            view.evaluateJavaScript(script) { result, error in
                if let error {
                    value.resume(throwing: error)
                } else if let string = result as? String {
                    value.resume(returning: string)
                } else {
                    value.resume(throwing: ReaderError.message("无法校验重排分页。"))
                }
            }
        }
        struct Metrics: Decodable {
            var pages: [[UUID]]?
            var error: Int?
        }
        let measured = try JSONDecoder().decode(Metrics.self, from: Data(metrics.utf8))
        guard measured.error == nil, let pageBlocks = measured.pages, !pageBlocks.isEmpty, pageBlocks.count <= 100,
            pageBlocks.allSatisfy({ !$0.isEmpty }), Set(pageBlocks.flatMap { $0 }) == Set(pairs.map { $0.block.id })
        else { throw ReaderError.message("公式、图表或正文超出版面，未发布可能缺失的内容；可查看原版。") }
        let count = pageBlocks.count
        var artifacts: [PageArtifact] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let pdf = WKPDFConfiguration()
            pdf.rect = CGRect(x: index * 612, y: 0, width: 612, height: 792)
            let bytes = try await view.pdf(configuration: pdf)
            guard let document = PDFDocument(data: bytes), document.pageCount == 1 else {
                throw ReaderError.message("HTML 排版导出不完整，未发布页面。")
            }
            let name = "html-\(UUID().uuidString).pdf"
            try bytes.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            let sourcePages = Set(pairs.filter { pageBlocks[index].contains($0.block.id) }.map { $0.block.sourcePage })
            artifacts.append(
                PageArtifact(
                    blockIDs: pageBlocks[index], sourcePage: sourcePages.count == 1 ? sourcePages.first! : -1,
                    relativePath: name))
        }
        return artifacts
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }
    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) { finish(.failure(error)) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ReaderError.message("排版进程中断，可继续重试。")))
    }
    private func finish(_ result: Result<Void, any Error>) {
        timeout?.cancel()
        timeout = nil
        let value = continuation
        continuation = nil
        value?.resume(with: result)
    }
}
