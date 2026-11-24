import WebKit

/// Keeps at most one empty browser engine warm. No paper bytes or website cache are persisted.
@MainActor
enum HTMLWebViewPool {
    private static var idle: WKWebView?

    static func prewarm() {
        guard idle == nil else { return }
        let view = make()
        idle = view
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 600)
        if let url = Bundle.module.url(forResource: "ReaderWarmup", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    static func take() -> WKWebView {
        let view = idle ?? make()
        idle = nil
        view.stopLoading()
        return view
    }

    static func recycle(_ view: WKWebView) {
        view.configuration.userContentController.removeAllUserScripts()
        view.loadHTMLString("<!doctype html><title>PageWise</title>", baseURL: nil)
        idle = view
    }

    private static func make() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: config)
    }
}
