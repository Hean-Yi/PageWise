import PaperReaderKit
import SwiftUI
import WebKit

/// All three layouts use the source sentence IDs for interaction and native text selection.
@MainActor struct PDFSentenceTextCanvas {
    enum Layout: String { case split, stacked, paragraph }
    let sentences: [PDFSourceSentence]
    let translations: [String: String]
    let layout: Layout
    let fontSize: Int
    let activeID: String?
    let focusedID: String?
    let focusRevision: Int
    let followsScroll: Bool
    let sourceScrollID: String?
    let sourceScrollRevision: Int
    let pdfSelectedIDs: [String]
    let onScroll: (String) -> Void
    let onSelection: ([String]) -> Void
    let onFocus: (String?) -> Void
    let onHover: (String?) -> Void
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

    struct Continuous {
        let paperID: UUID
        let pageCount: Int
        let pages: [Int: PDFParagraphPage]
        let targetPage: Int
        let jumpRevision: Int
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
        private var active: String?
        private var focused: String?
        private var revision = -1
        private var follow: Bool?
        private var lastScrollRevision = -1
        private var lastPDFSelection: [String] = []
        private var ready = false
        private var paragraphWindow = PDFParagraphWindowBridge()

        init(_ parent: PDFSentenceTextCanvas) { latest = parent }

        func makeView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let controller = config.userContentController
            controller.add(self, contentWorld: .defaultClient, name: "sentence")
            controller.addUserScript(
                WKUserScript(
                    source: HTMLImagePreviewScript.source + "\n" + PDFSentenceTextCanvas.script,
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
            if changed || windowChanged || layoutChanged || displayedFontSize != parent.fontSize
                || active != parent.activeID
                || focused != parent.focusedID
                || revision != parent.focusRevision
            {
                let scroll =
                    parent.focusedID != nil
                    && (focused != parent.focusedID || layoutChanged || revision != parent.focusRevision)
                view.callAsyncJavaScript(
                    "window.sentenceReader.show(fontSize, active, focused, scroll)",
                    arguments: [
                        "fontSize": parent.fontSize, "active": parent.activeID ?? "",
                        "focused": parent.focusedID ?? "", "scroll": scroll,
                    ],
                    in: nil, in: .defaultClient, completionHandler: nil)
                active = parent.activeID
                focused = parent.focusedID
                revision = parent.focusRevision
                displayedLayout = parent.layout
                displayedFontSize = parent.fontSize
            }
            if changed || layoutChanged || follow != parent.followsScroll
                || lastScrollRevision != parent.sourceScrollRevision
                || lastPDFSelection != parent.pdfSelectedIDs
            {
                let track = parent.followsScroll && parent.layout == .split
                let reveal = track && lastScrollRevision != parent.sourceScrollRevision
                view.callAsyncJavaScript(
                    "window.sentenceReader.sync(track, reveal, ids)",
                    arguments: [
                        "track": track, "reveal": reveal ? parent.sourceScrollID ?? "" : "",
                        "ids": parent.pdfSelectedIDs,
                    ], in: nil, in: .defaultClient, completionHandler: nil)
                follow = parent.followsScroll
                lastScrollRevision = parent.sourceScrollRevision
                lastPDFSelection = parent.pdfSelectedIDs
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
                ]
            }
        }

        static func figure(_ item: PDFReadingIllustration) -> [String: Any] {
            var result: [String: Any] = [
                "id": item.id, "label": item.label, "before": item.insertBeforeSentenceID ?? "",
                "presentation": item.presentation.rawValue,
            ]
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

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready, message.frameInfo.isMainFrame, let event = message.body as? [String: Any] else { return }
            if let stamp = event["paper"] as? String {
                guard let window = latest.continuous, stamp == window.paperID.uuidString,
                    event["revision"] as? Int == window.jumpRevision
                else { return }
                if let index = event["page"] as? Int, (0..<window.pageCount).contains(index) {
                    switch event["action"] as? String {
                    case "viewport":
                        window.onVisiblePage(index)
                        if let sentence = event["id"] as? String, isDisplayed(sentence) { latest.onScroll(sentence) }
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
                return
            }
            guard let raw = event["id"] as? String, raw.isEmpty || isDisplayed(raw) else { return }
            let id = raw.isEmpty ? nil : raw
            switch event["action"] as? String {
            case "focus": latest.onFocus(id)
            case "hover": latest.onHover(id)
            case "scroll":
                if latest.followsScroll, latest.layout == .split, let id { latest.onScroll(id) }
            default: break
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
        :root{color-scheme:light dark;--paper:#fffefa;--ink:#282724;--en:#605e59;--active:#f5e4d7;--focus:#af6247}
        @media(prefers-color-scheme:dark){:root{--paper:#2e2b28;--ink:#f1eee7;--en:#c4beb4;--active:#654634;--focus:#e8a082}}
        *{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:var(--zh-size,16px)/1.7 -apple-system,"PingFang SC",sans-serif}
        main{max-width:45rem;margin:auto;padding:19px clamp(18px,4vw,38px) 60px;overflow-wrap:anywhere}
        p{margin:0 0 1em}
        [role="button"]{border-radius:3px;box-decoration-break:clone;-webkit-box-decoration-break:clone}
        .active,.related,.counterpart{background:var(--active)}
        [role="button"]:focus-visible{outline:2px solid var(--focus);outline-offset:2px}
        .en{display:none}.stacked .pair{display:block;padding:4px 6px;margin:0 -6px 12px}
        .stacked .en{display:block;font:16px/1.55 Georgia,"Times New Roman",serif;color:var(--en);margin-bottom:3px}
        .stacked p{margin-bottom:1.5em}.stacked .zh{line-height:1.7}
        .paragraph main{max-width:48rem;padding:clamp(22px,4vw,44px) clamp(20px,6vw,56px) 60px}
        .paragraph main>*+*{margin-top:1.7em}
        figure{margin:0}.paragraph figure+section{margin-top:.8em}
        figure button{display:block;max-width:100%;padding:0;border:0;background:none;color:var(--focus);cursor:pointer;font:inherit}
        figure button:focus-visible{outline:2px solid var(--focus);outline-offset:3px}
        figure img{display:block;max-width:100%;height:auto;margin:auto}
        figure button:has(img){width:100%;cursor:zoom-in}
        figure button:not(:has(img)){font-size:.9em;text-decoration:underline;text-underline-offset:.2em}
        .paragraph p{margin:0}.paragraph p[lang="en"]{font:1.06em/1.55 Georgia,"Times New Roman",serif;color:var(--en)}
        .paragraph .en{display:inline}.paragraph p[lang="zh-Hans"]{margin-top:.45em;line-height:1.8}
        .pending{color:var(--en);font:.8em/1.6 -apple-system,sans-serif;margin-inline:.2em;-webkit-user-select:none;user-select:none}
        [data-selecting="zh"] .en,[data-selecting="en"] .zh{-webkit-user-select:none;user-select:none}
        .paragraph.continuous main{padding-top:0}
        .continuous main>.source-page{display:flow-root;margin:0;overflow-anchor:none}
        .page-body>*+*{margin-top:1.7em}
        .untranslated .page-body section>p[lang="zh-Hans"]{display:none}
        .page-marker{display:flex;align-items:center;gap:.8em;margin:2.4em 0 1.4em;color:var(--en);font:500 .75em/1.5 -apple-system,sans-serif}
        .page-marker:after{content:"";height:1px;background:currentColor;opacity:.2;flex:1}
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
        </style></head><body><main aria-label="本页逐句译文"></main></body></html>
        """

    fileprivate static let script = """
        (() => {
          const main=document.querySelector('main'), pairs=new Map();
          let figures=[];
          let hot='', active='', focused='', track=false, userScroll=false, scrollTimer=0, lastScroll='';
          let lastSelection=[], related=[], order=[], paragraphMode=false, revealLanguage='en';
          let flow=null;
          function post(event) {
            if (flow) { event.paper=flow.paper;event.revision=flow.revision; }
            window.webkit.messageHandlers.sentence.postMessage(event);
          }
          const send=(action,id)=>post({action,id});
          const pairAt=node=>node?.closest?.('[data-sentence]');
          const sideOf=node=>node?.closest('.en') ? 'en' : 'zh';
          function hover(id) { if (id!==hot) {hot=id; send('hover',id);} }
          function focus(node) {
            revealLanguage=sideOf(node)==='en' ? 'zh' : 'en';
            const id=node.dataset.sentence;
            send('focus',id===focused ? '' : id);
          }
          function targets(id) {
            const pair=pairs.get(id);
            return pair ? (paragraphMode ? [pair.en,pair.zh] : [pair.button]) : [];
          }
          function reveal(id) {
            const pair=pairs.get(id);
            if (!pair) return;
            const target=paragraphMode ? (pair[revealLanguage].isConnected ? pair[revealLanguage] : pair.en) : pair.button;
            const bounds=target.getBoundingClientRect();
            if (bounds.bottom<=0 || bounds.top>=innerHeight) {
              clearTimeout(scrollTimer); scrollTimer=0; userScroll=false;
              target.scrollIntoView({block:'center',inline:'nearest'});
            }
          }
          for (const event of ['wheel','touchmove','pointerdown','keydown']) {
            document.addEventListener(event,()=>{userScroll=true;},{passive:true});
          }
          window.addEventListener('scroll',()=>{
            if (flow) { scheduleViewport();return; }
            if (!userScroll || !track || scrollTimer) return;
            scrollTimer=setTimeout(()=>{
              scrollTimer=0;
              if (!userScroll || !track || !getSelection().isCollapsed) return;
              const edge=innerHeight*0.23;
              const visible=[...main.querySelectorAll('.pair')].find(s=>{
                const box=s.getBoundingClientRect(); return box.bottom>=edge && box.top<innerHeight;
              });
              if (visible && lastScroll!==visible.id) {lastScroll=visible.id;send('scroll',visible.id);}
            },70);
          },{passive:true});
          \(tableScript)
          function selectedText(range, text) {
            const content = document.createRange();
            content.selectNodeContents(text);
            const overlap = range.cloneRange();
            if (overlap.compareBoundaryPoints(Range.START_TO_START, content) < 0) {
              overlap.setStart(text, 0);
            }
            if (overlap.compareBoundaryPoints(Range.END_TO_END, content) > 0) {
              overlap.setEnd(text, text.childNodes.length);
            }
            return overlap.toString();
          }
          function selectedPieces() {
            const selection = getSelection();
            if (!selection.rangeCount || selection.isCollapsed) return [];
            const anchor = selection.anchorNode;
            const start = anchor.nodeType === Node.TEXT_NODE ? anchor.parentElement : anchor;
            const language = main.dataset.selecting || sideOf(start);
            const range = selection.getRangeAt(0);
            const pieces = [];
            for (const text of main.querySelectorAll('.' + language)) {
              if (!range.intersectsNode(text)) continue;
              const value = selectedText(range,text);
              if (value.length) pieces.push({id: text.dataset.sentence, text: value, language});
            }
            return pieces;
          }
          main.addEventListener('pointerdown', event => {
            const text = event.target.closest('.en,.zh');
            if (text) main.dataset.selecting = sideOf(text);
            else delete main.dataset.selecting;
          });
          document.addEventListener('selectionchange', () => {
            const pieces = selectedPieces();
            if (paragraphMode) {
              for (const el of main.querySelectorAll('.counterpart')) el.classList.remove('counterpart');
              for (const piece of pieces) {
                const opposite=piece.language==='en' ? 'zh' : 'en';
                pairs.get(piece.id)?.[opposite].classList.add('counterpart');
              }
            }
            const ids = pieces.map(piece => piece.id);
            if (ids.join('|') !== lastSelection.join('|')) {
              lastSelection = ids;
              post({action:'selection',ids});
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
              const next = pairs.get(piece.id).group;
              if (paragraph && paragraph !== next) plain += '\\n\\n';
              else if (plain && piece.language === 'en') plain += ' ';
              plain += piece.text;
              paragraph = next;
            }
            event.clipboardData.setData('text/plain', plain);
            event.preventDefault();
          });
          main.addEventListener('pointerover',e=>{if(e.pointerType==='mouse') hover(pairAt(e.target)?.dataset.sentence||'');});
          main.addEventListener('pointerleave',()=>hover(''));
          main.addEventListener('click',e=>{
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
            const el=pairAt(e.target);
            if (el && window.getSelection().isCollapsed) focus(el);
          });
          main.addEventListener('keydown',e=>{
            const el=pairAt(e.target);
            if (e.key==='Escape') {send('focus','');return;}
            if (!el || e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) return;
            if (e.key==='Enter' || e.key===' ') {e.preventDefault();focus(el);}
            if (e.key==='ArrowDown' || e.key==='ArrowUp') {
              e.preventDefault();
              const id=order[order.indexOf(el.dataset.sentence)+(e.key==='ArrowDown'?1:-1)];
              const pair=pairs.get(id);
              if (pair) {
                const side=sideOf(el);
                const target=paragraphMode ? (pair[side].isConnected ? pair[side] : pair.en) : pair.button;
                target.focus();send('focus',id);
              }
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
            const button=span('pair'), en=span('en'), zh=span('zh');
            button.id=id; en.lang='en'; zh.lang='zh-Hans';
            const pending=document.createElement('span');
            pending.className='pending'; pending.textContent='待译';
            return {button,en,zh,pending,space:document.createTextNode(' ')};
          }
          function setButton(node,enabled) {
            if (enabled) {
              node.tabIndex=0; node.setAttribute('role','button'); node.setAttribute('aria-pressed','false');
            } else {
              node.removeAttribute('role');node.removeAttribute('tabindex');node.removeAttribute('aria-pressed');
            }
          }
          function makeGroup(id) {
            const group=document.createElement(paragraphMode ? 'section' : 'p');
            group.dataset.group=id;
            if (paragraphMode) {
              for (const language of ['en','zh-Hans']) {
                const p=document.createElement('p'); p.lang=language; group.append(p);
              }
            }
            return group;
          }
          function makeFigure(item) {
            const node=document.createElement('figure'), button=document.createElement('button');
            button.type='button';
            button.dataset.illustration=item.id;
            const action=item.presentation==='originalPage' || item.presentation==='supplement' ? '打开原 PDF' : '在原页查看'+item.label;
            button.setAttribute('aria-label',action);
            if (item.table) {
              try {
                node.className='reading-table';
                showReadingTable(node,item,button);
                return {before:item.before,node};
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
            return {before:item.before,node};
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
                setButton(pair.button,!paragraphMode);
                setButton(pair.en,paragraphMode);setButton(pair.zh,paragraphMode);
                pairs.set(row.id,pair);
              }
              pair.group=row.paragraph;
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
                for (const pair of members) setChildren(pair.button,[pair.en,pair.zh]);
                setChildren(group,members.map(pair=>pair.button));
              }
              blocks.push(group);
            }
            for (const remaining of beforeSentence.values()) blocks.push(...remaining);
            setChildren(root,blocks);
          }
          \(continuousScript)
          window.sentenceReader={
            pageWindow,tableCopied,
            render(rows,layout,items) {
              const changingStructure=paragraphMode!==(layout==='paragraph');
              if (flow) {flow=null;figures=[];main.replaceChildren();}
              const selection=getSelection();
              const {anchorNode,anchorOffset,focusNode,focusOffset}=selection;
              paragraphMode=layout==='paragraph';
              document.body.className=layout;
              main.setAttribute('aria-label',paragraphMode ? '本页段落对照' : '本页逐句译文');
              if (items) figures=items.map(makeFigure);
              order=rows.map(row=>row.id);
              const incoming=new Set(order);
              for (const id of pairs.keys()) if (!incoming.has(id)) pairs.delete(id);
              renderRows(main,rows,figures,changingStructure);
              if (changingStructure) {
                revealLanguage='en';
                for (const pair of pairs.values()) {
                  for (const node of [pair.en,pair.zh,pair.button]) node.classList.remove('active','related','counterpart');
                }
                if (anchorNode?.nodeType===Node.TEXT_NODE && focusNode?.nodeType===Node.TEXT_NODE
                    && anchorNode.isConnected && focusNode.isConnected
                    && anchorNode.parentElement.getClientRects().length && focusNode.parentElement.getClientRects().length) {
                  selection.setBaseAndExtent(anchorNode,anchorOffset,focusNode,focusOffset);
                }
              }
            },
            show(fontSize,id,pinned,scroll) {
              document.documentElement.style.setProperty('--zh-size',fontSize+'px');
              updateTableWidths();
              for (const el of targets(active)) el.classList.remove('active');
              for (const el of targets(focused)) el.setAttribute('aria-pressed','false');
              active=id; focused=pinned;
              for (const el of targets(focused)) el.setAttribute('aria-pressed','true');
              for (const el of targets(active)) el.classList.add('active');
              if (scroll) reveal(focused);
            },
            sync(enabled,scrollID,selected) {
              track=enabled;
              for (const id of related) for (const el of targets(id)) el.classList.remove('related');
              related=selected;
              for (const id of related) for (const el of targets(id)) el.classList.add('related');
              if (scrollID) {lastScroll=scrollID; reveal(scrollID);}
            }
          };
        })();
        """
}
