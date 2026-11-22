import PaperReaderKit
import SwiftUI
import WebKit

/// Both reading layouts share the same DOM nodes and native text selection.
@MainActor struct PDFSentenceTextCanvas {
    let sentences: [PDFSourceSentence]
    let translations: [String: String]
    let stacked: Bool
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var latest: PDFSentenceTextCanvas
        private var renderedIDs: [String] = []
        private var translated: [String: String] = [:]
        private var displayedStacked: Bool?
        private var displayedFontSize: Int?
        private var active: String?
        private var focused: String?
        private var revision = -1
        private var follow: Bool?
        private var lastScrollRevision = -1
        private var lastPDFSelection: [String] = []
        private var ready = false

        init(_ parent: PDFSentenceTextCanvas) { latest = parent }

        func makeView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let controller = config.userContentController
            controller.add(self, contentWorld: .defaultClient, name: "sentence")
            controller.addUserScript(
                WKUserScript(
                    source: PDFSentenceTextCanvas.script, injectionTime: .atDocumentEnd,
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
            let ids = parent.sentences.map(\.id)
            let changed = ids != renderedIDs || translated != parent.translations
            let layoutChanged = displayedStacked != parent.stacked
            if changed {
                let rows = parent.sentences.compactMap { sentence -> [String: String]? in
                    guard let zh = parent.translations[sentence.id] else { return nil }
                    return ["id": sentence.id, "paragraph": sentence.paragraphID, "en": sentence.text, "zh": zh]
                }
                view.callAsyncJavaScript(
                    "window.sentenceReader.render(rows)", arguments: ["rows": rows],
                    in: nil, in: .defaultClient, completionHandler: nil)
                renderedIDs = ids
                translated = parent.translations
            }
            if changed || layoutChanged || displayedFontSize != parent.fontSize || active != parent.activeID
                || focused != parent.focusedID
                || revision != parent.focusRevision
            {
                let scroll =
                    parent.focusedID != nil
                    && (focused != parent.focusedID || layoutChanged || revision != parent.focusRevision)
                view.callAsyncJavaScript(
                    "window.sentenceReader.show(stacked, fontSize, active, focused, scroll)",
                    arguments: [
                        "stacked": parent.stacked, "fontSize": parent.fontSize, "active": parent.activeID ?? "",
                        "focused": parent.focusedID ?? "", "scroll": scroll,
                    ],
                    in: nil, in: .defaultClient, completionHandler: nil)
                active = parent.activeID
                focused = parent.focusedID
                revision = parent.focusRevision
                displayedStacked = parent.stacked
                displayedFontSize = parent.fontSize
            }
            if changed || layoutChanged || follow != parent.followsScroll
                || lastScrollRevision != parent.sourceScrollRevision
                || lastPDFSelection != parent.pdfSelectedIDs
            {
                let track = parent.followsScroll && !parent.stacked
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

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready, message.frameInfo.isMainFrame, let event = message.body as? [String: Any] else { return }
            if event["action"] as? String == "selection", let ids = event["ids"] as? [String],
                ids.allSatisfy({ latest.translations[$0] != nil })
            {
                latest.onSelection(ids)
                return
            }
            guard let raw = event["id"] as? String, raw.isEmpty || latest.translations[raw] != nil else { return }
            let id = raw.isEmpty ? nil : raw
            switch event["action"] as? String {
            case "focus": latest.onFocus(id)
            case "hover": latest.onHover(id)
            case "scroll":
                if latest.followsScroll, !latest.stacked, let id { latest.onScroll(id) }
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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'">
        <style>
        :root{color-scheme:light dark;--paper:#fffefa;--ink:#282724;--en:#605e59;--active:#f5e4d7;--focus:#af6247}
        @media(prefers-color-scheme:dark){:root{--paper:#2e2b28;--ink:#f1eee7;--en:#c4beb4;--active:#654634;--focus:#e8a082}}
        *{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:var(--zh-size,16px)/1.7 -apple-system,"PingFang SC",sans-serif}
        main{max-width:45rem;margin:auto;padding:19px clamp(18px,4vw,38px) 60px;overflow-wrap:anywhere}
        p{margin:0 0 1em} .pair{border-radius:3px;box-decoration-break:clone;-webkit-box-decoration-break:clone}
        .pair.active,.pair.related{background:var(--active)}.pair:focus-visible{outline:2px solid var(--focus);outline-offset:2px}
        .en{display:none}.stacked .pair{display:block;padding:4px 6px;margin:0 -6px 12px}
        .stacked .en{display:block;font:16px/1.55 Georgia,"Times New Roman",serif;color:var(--en);margin-bottom:3px}
        .stacked p{margin-bottom:1.5em}.stacked .zh{line-height:1.7}
        [data-selecting="zh"] .en,[data-selecting="en"] .zh{-webkit-user-select:none;user-select:none}
        ::selection{background:rgba(160,125,89,.30)}
        </style></head><body><main aria-label="本页逐句译文"></main></body></html>
        """

    fileprivate static let script = """
        (() => {
          const main=document.querySelector('main'), pairs=new Map();
          let hot='', active='', focused='', track=false, userScroll=false, scrollTimer=0, lastScroll='';
          let lastSelection=[], related=[];
          const send=(action,id)=>window.webkit.messageHandlers.sentence.postMessage({action,id});
          const pairAt=node=>node?.closest?.('.pair');
          function hover(id) { if (id!==hot) {hot=id; send('hover',id);} }
          function focus(id) { send('focus', id===focused ? '' : id); }
          function reveal(id) {
            const target=pairs.get(id);
            if (!target) return;
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
          function selectedPieces() {
            const selection = getSelection();
            if (!selection.rangeCount || selection.isCollapsed) return [];
            const anchor = selection.anchorNode;
            const start = anchor.nodeType === Node.TEXT_NODE ? anchor.parentElement : anchor;
            const language = main.dataset.selecting || (start.closest('.en') ? 'en' : 'zh');
            const range = selection.getRangeAt(0);
            const pieces = [];
            for (const text of main.querySelectorAll('.' + language)) {
              if (!range.intersectsNode(text)) continue;
              const content = document.createRange();
              content.selectNodeContents(text);
              const overlap = range.cloneRange();
              if (overlap.compareBoundaryPoints(Range.START_TO_START, content) < 0) {
                overlap.setStart(text, 0);
              }
              if (overlap.compareBoundaryPoints(Range.END_TO_END, content) > 0) {
                overlap.setEnd(text, text.childNodes.length);
              }
              const value = overlap.toString();
              if (value.length) pieces.push({id: text.parentElement.id, text: value, language});
            }
            return pieces;
          }
          main.addEventListener('pointerdown', event => {
            const text = event.target.closest('.en,.zh');
            if (text) main.dataset.selecting = text.className;
            else delete main.dataset.selecting;
          });
          document.addEventListener('selectionchange', () => {
            const ids = selectedPieces().map(piece => piece.id);
            if (ids.join('|') !== lastSelection.join('|')) {
              lastSelection = ids;
              window.webkit.messageHandlers.sentence.postMessage({action: 'selection', ids});
            }
          });
          document.addEventListener('copy', event => {
            const pieces = selectedPieces();
            if (!pieces.length || !event.clipboardData) return;
            let plain = '';
            let paragraph;
            for (const piece of pieces) {
              const next = pairs.get(piece.id).parentElement;
              if (paragraph && paragraph !== next) plain += '\\n\\n';
              else if (plain && piece.language === 'en') plain += ' ';
              plain += piece.text;
              paragraph = next;
            }
            event.clipboardData.setData('text/plain', plain);
            event.preventDefault();
          });
          main.addEventListener('pointerover',e=>{if(e.pointerType==='mouse') hover(pairAt(e.target)?.id||'');});
          main.addEventListener('pointerleave',()=>hover(''));
          main.addEventListener('click',e=>{
            const el=pairAt(e.target);
            if (el && window.getSelection().isCollapsed) focus(el.id);
          });
          main.addEventListener('keydown',e=>{
            const el=pairAt(e.target);
            if (e.key==='Escape') {send('focus','');return;}
            if (!el || e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) return;
            if (e.key==='Enter' || e.key===' ') {e.preventDefault();focus(el.id);}
            if (e.key==='ArrowDown' || e.key==='ArrowUp') {
              e.preventDefault(); const ids=[...main.querySelectorAll('.pair')].map(s=>s.id), target=pairs.get(ids[ids.indexOf(el.id)+(e.key==='ArrowDown'?1:-1)]);
              if (target) {target.focus();send('focus',target.id);}
            }
          });
          window.sentenceReader={
            render(rows) {
              // Keep existing elements during progressive translation to retain the reader's selection.
              const incoming=new Set(rows.map(row=>row.id));
              for (const [id,node] of pairs) if (!incoming.has(id)) {node.remove();pairs.delete(id);}
              const paragraphs=new Map([...main.children].map(p=>[p.dataset.group,p]));
              let previous=null, groupIndex=-1, sentenceIndex=0, paragraph;
              for (const row of rows) {
                if (previous!==row.paragraph) {
                  paragraph=paragraphs.get(row.paragraph);
                  if (!paragraph) {paragraph=document.createElement('p');paragraph.dataset.group=row.paragraph;}
                  groupIndex++;
                  if (main.children[groupIndex]!==paragraph) main.insertBefore(paragraph,main.children[groupIndex]||null);
                  sentenceIndex=0; previous=row.paragraph;
                }
                let s=pairs.get(row.id);
                if (!s) {
                  s=document.createElement('span'); s.className='pair'; s.id=row.id; s.tabIndex=0;
                  s.setAttribute('role','button'); s.setAttribute('aria-pressed','false');
                  const en=document.createElement('span'), zh=document.createElement('span');
                  en.className='en'; en.lang='en'; zh.className='zh'; s.append(en,zh);
                  pairs.set(row.id,s);
                }
                if (s.firstChild.textContent!==row.en) s.firstChild.textContent=row.en;
                if (s.lastChild.textContent!==row.zh) s.lastChild.textContent=row.zh;
                if (paragraph.children[sentenceIndex]!==s) paragraph.insertBefore(s,paragraph.children[sentenceIndex]||null);
                sentenceIndex++;
              }
              for (const p of [...main.children]) if (!p.childElementCount) p.remove();
            },
            show(stacked,fontSize,id,pinned,scroll) {
              document.documentElement.style.setProperty('--zh-size',fontSize+'px');
              document.body.classList.toggle('stacked',stacked);
              pairs.get(active)?.classList.remove('active');
              pairs.get(focused)?.setAttribute('aria-pressed','false');
              active=id; focused=pinned;
              pairs.get(focused)?.setAttribute('aria-pressed','true');
              pairs.get(active)?.classList.add('active');
              if (scroll) reveal(focused);
            },
            sync(enabled,scrollID,selected) {
              track=enabled;
              for (const id of related) pairs.get(id)?.classList.remove('related');
              related=selected;
              for (const id of related) pairs.get(id)?.classList.add('related');
              if (scrollID) {lastScroll=scrollID; reveal(scrollID);}
            }
          };
        })();
        """
}
