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
            let changed = renderedSentences != parent.sentences || translated != parent.translations
            let layoutChanged = displayedLayout != parent.layout
            let paragraph = parent.layout == .paragraph
            let illustrations = paragraph ? parent.illustrations : []
            let illustrationsChanged = renderedIllustrations != illustrations
            if changed || layoutChanged || illustrationsChanged {
                let rows = parent.sentences.compactMap { sentence -> [String: String]? in
                    let translation = parent.translations[sentence.id]
                    guard paragraph || translation != nil else { return nil }
                    return [
                        "id": sentence.id, "paragraph": paragraph ? sentence.readingParagraphID : sentence.paragraphID,
                        "en": sentence.text, "zh": translation ?? "",
                    ]
                }
                var arguments: [String: Any] = ["rows": rows, "layout": parent.layout.rawValue, "figures": NSNull()]
                if illustrationsChanged {
                    arguments["figures"] = illustrations.map { item in
                        [
                            "id": item.id, "label": item.label, "before": item.insertBeforeSentenceID ?? "",
                            "png": item.imagePNG?.base64EncodedString() ?? "",
                        ]
                    }
                    renderedIllustrations = illustrations
                }
                view.callAsyncJavaScript(
                    "window.sentenceReader.render(rows, layout, figures)", arguments: arguments,
                    in: nil, in: .defaultClient, completionHandler: nil)
                renderedSentences = parent.sentences
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

        private func isDisplayed(_ id: String) -> Bool {
            latest.translations[id] != nil || (latest.layout == .paragraph && latest.sentences.contains { $0.id == id })
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready, message.frameInfo.isMainFrame, let event = message.body as? [String: Any] else { return }
            if event["action"] as? String == "illustration" {
                if latest.layout == .paragraph, let id = event["id"] as? String,
                    let item = latest.illustrations.first(where: { $0.id == id })
                {
                    latest.onRevealIllustration?(item)
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
        ::selection{background:rgba(160,125,89,.30)}
        </style></head><body><main aria-label="本页逐句译文"></main></body></html>
        """

    fileprivate static let script = """
        (() => {
          const main=document.querySelector('main'), pairs=new Map();
          let figures=[];
          let hot='', active='', focused='', track=false, userScroll=false, scrollTimer=0, lastScroll='';
          let lastSelection=[], related=[], order=[], paragraphMode=false, revealLanguage='en';
          const send=(action,id)=>window.webkit.messageHandlers.sentence.postMessage({action,id});
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
            const language = main.dataset.selecting || sideOf(start);
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
              window.webkit.messageHandlers.sentence.postMessage({action: 'selection', ids});
            }
          });
          document.addEventListener('copy', event => {
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
            const figure=e.target.closest('[data-illustration]');
            if (figure && (e.detail===0 || getSelection().isCollapsed)) {
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
            const action='在原页查看'+item.label;
            button.setAttribute('aria-label',action);
            if (item.png) {
              const image=document.createElement('img');
              image.alt=item.label; image.draggable=false;
              image.addEventListener('error',()=>{button.textContent=action;},{once:true});
              image.src='data:image/png;base64,'+item.png;
              button.append(image); button.title=action;
            } else {
              button.textContent=action;
            }
            node.append(button);
            return {before:item.before,node};
          }
          window.sentenceReader={
            render(rows,layout,items) {
              const changingStructure=paragraphMode!==(layout==='paragraph');
              const selection=getSelection();
              const {anchorNode,anchorOffset,focusNode,focusOffset}=selection;
              paragraphMode=layout==='paragraph';
              document.body.className=layout;
              main.setAttribute('aria-label',paragraphMode ? '本页段落对照' : '本页逐句译文');
              if (items) figures=items.map(makeFigure);
              const previous=changingStructure ? new Map() : new Map([...main.querySelectorAll('[data-group]')].map(p=>[p.dataset.group,p]));
              const groups=new Map();
              order=rows.map(row=>row.id);
              const incoming=new Set(order);
              for (const id of pairs.keys()) if (!incoming.has(id)) pairs.delete(id);
              for (const row of rows) {
                if (!groups.has(row.paragraph)) groups.set(row.paragraph,[]);
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
                groups.get(row.paragraph).push(pair);
              }
              const blocks=[], beforeGroup=new Map();
              for (const item of figures) {
                const group=pairs.get(item.before)?.group;
                if (!beforeGroup.has(group)) beforeGroup.set(group,[]);
                beforeGroup.get(group).push(item.node);
              }
              for (const [id,members] of groups) {
                if (beforeGroup.has(id)) blocks.push(...beforeGroup.get(id));
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
              if (beforeGroup.has(undefined)) blocks.push(...beforeGroup.get(undefined));
              setChildren(main,blocks);
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
