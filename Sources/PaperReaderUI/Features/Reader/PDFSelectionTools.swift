import PaperReaderKit
import SwiftUI
import WebKit

/// The same annotation palette runs in the HTML reader and beside a PDFKit selection.
struct PDFSelectionTools: View {
    let model: ReaderModel
    let selection: PDFSelectionToolsAnchor?
    let dismiss: () -> Void
    @State private var height: CGFloat = 175

    var body: some View {
        PDFSelectionToolsLayout(anchor: selection?.bounds ?? .zero) {
            PDFPaletteHost(
                model: model, selection: selection, marks: model.currentHighlights, height: $height, dismiss: dismiss
            )
            .frame(maxWidth: 272).frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .opacity(selection == nil ? 0 : 1)
        .allowsHitTesting(selection != nil)
        .accessibilityHidden(selection == nil)
    }
}

@MainActor private struct PDFPaletteHost {
    let model: ReaderModel
    let selection: PDFSelectionToolsAnchor?
    let marks: [Highlight]
    @Binding var height: CGFloat
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler {
        private var host: PDFPaletteHost
        private weak var view: WKWebView?
        private var ready = false
        private var generation = 0
        private var refreshTask: Task<Void, Never>?
        private var actionTask: Task<Void, Never>?

        init(_ host: PDFPaletteHost) { self.host = host }

        func makeView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            let controller = config.userContentController
            controller.add(self, contentWorld: .defaultClient, name: "pdfPalette")
            controller.addUserScript(
                WKUserScript(
                    source: PDFPaletteHost.script, injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true, in: .defaultClient))
            let web = WKWebView(frame: .zero, configuration: config)
            web.underPageBackgroundColor = .clear
            #if os(iOS)
                web.isOpaque = false
                web.backgroundColor = .clear
                web.scrollView.isScrollEnabled = false
            #endif
            view = web
            web.loadHTMLString(
                """
                <!DOCTYPE html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'">
                <style>html,body{margin:0;overflow:hidden;color-scheme:light dark;background:transparent}</style><body></body>
                """, baseURL: nil)
            return web
        }

        func update(_ next: PDFPaletteHost) {
            let changed = host.selection != next.selection
            let needsRefresh = changed || host.marks != next.marks
            host = next
            if changed { generation &+= 1 }
            if needsRefresh { refresh() }
        }

        private func refresh() {
            refreshTask?.cancel()
            guard ready else { return }
            guard let selection = host.selection, selection.matches(host.model) else {
                view?.callAsyncJavaScript(
                    "window.hidePDFPalette()", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
                return
            }
            let token = generation
            refreshTask = Task { [weak self] in
                guard let self else { return }
                let appearance = await host.model.pdfSelectionAppearance()
                guard !Task.isCancelled, generation == token, selection.matches(host.model) else { return }
                let state: [String: Any] = [
                    "enabled": true, "covered": appearance.covered,
                    "color": appearance.color?.rawValue as Any? ?? NSNull(),
                    "style": appearance.style?.rawValue as Any? ?? NSNull(),
                ]
                view?.callAsyncJavaScript(
                    "window.updatePDFPalette(token,state)", arguments: ["token": token, "state": state],
                    in: nil, in: .defaultClient, completionHandler: nil)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any] else { return }
            if let newHeight = data["height"] as? Double, newHeight.isFinite, newHeight > 0 {
                let height = ceil(newHeight)
                if host.height != height { host.height = height }
                return
            }
            if data["ready"] as? Bool == true {
                ready = true
                refresh()
                return
            }
            guard let selection = host.selection, selection.matches(host.model), data["token"] as? Int == generation,
                let tool = data["action"] as? String
            else { return }
            let action: PDFReflowSelectionAction
            switch tool {
            case "note": action = .note
            case "bookmark": action = .bookmark
            case "mark":
                guard let rawColor = data["color"] as? String, let color = AnnotationColor(rawValue: rawColor),
                    let rawStyle = data["style"] as? String, let style = AnnotationStyle(rawValue: rawStyle),
                    let removing = data["removing"] as? Bool
                else { return }
                action = .mark(color: color, style: style, removing: removing)
            case "dismiss":
                host.dismiss()
                return
            default: return
            }
            let previous = actionTask
            actionTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, let self, host.selection == selection, selection.matches(host.model) else {
                    return
                }
                await host.model.performPDFSelectionAction(action)
                if tool == "note", host.selection == selection { host.dismiss() }
            }
        }

        func stop() {
            view?.configuration.userContentController.removeScriptMessageHandler(
                forName: "pdfPalette", contentWorld: .defaultClient)
            refreshTask?.cancel()
            actionTask?.cancel()
            ready = false
        }
    }

    static let script = #"""
        (()=>{
          \#(HTMLAnnotationMenuScript.install)
          let token=-1,state={enabled:false,covered:false};
          const send=value=>window.webkit.messageHandlers.pdfPalette.postMessage({...value,token});
          const menu=installAnnotationMenu({
            embedded:true,appearance:()=>state,
            apply:(color,style,removing)=>send({action:'mark',color,style,removing}),
            addBookmark:()=>send({action:'bookmark'}),addNote:()=>send({action:'note'})
          });
          const panel=document.getElementById('annotation-menu');
          // Mouse activation should leave the original PDF's selection and keyboard focus intact.
          panel.addEventListener('mousedown',event=>event.preventDefault());
          new ResizeObserver(()=>{if (!panel.hidden) send({height:panel.getBoundingClientRect().height});}).observe(panel);
          window.hidePDFPalette=()=>{token=-1;menu.hide();};
          window.updatePDFPalette=(next,value)=>{
            if(token!==next)panel.querySelector('.bookmark').textContent='添加书签';
            token=next;state=value;menu.show();
          };
          document.addEventListener('keydown',event=>{if(event.key==='Escape')send({action:'dismiss'});});
          send({ready:true});
        })();
        """#
}

#if os(macOS)
    extension PDFPaletteHost: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
        static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#else
    extension PDFPaletteHost: UIViewRepresentable {
        func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
    }
#endif

struct PDFSelectionToolsLayout: Layout {
    let anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let toolbar = subviews.first else { return }
        let size = toolbar.sizeThatFits(ProposedViewSize(width: min(272, max(1, bounds.width - 16)), height: nil))
        let region = anchor.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let point = Self.origin(for: size, near: region, in: bounds)
        toolbar.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(size))
    }

    static func origin(for size: CGSize, near anchor: CGRect, in bounds: CGRect) -> CGPoint {
        let edge: CGFloat = 8
        let gap: CGFloat = 10
        let usable = bounds.insetBy(dx: edge, dy: edge)
        let above = anchor.minY - gap - size.height
        let below = anchor.maxY + gap
        let y = below + size.height <= usable.maxY ? below : above
        return CGPoint(
            x: max(usable.minX, min(anchor.midX - size.width / 2, usable.maxX - size.width)),
            y: max(usable.minY, min(y, usable.maxY - size.height)))
    }
}
