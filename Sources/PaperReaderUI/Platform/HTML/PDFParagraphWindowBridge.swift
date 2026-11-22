import PaperReaderKit
import WebKit

/// Send only page deltas to the shared reading surface. In particular, new translations do not resend PNGs.
@MainActor struct PDFParagraphWindowBridge {
    private(set) var paperID: UUID?
    private var pages: [Int: PDFParagraphPage] = [:]
    private var jumpRevision: Int?
    private var fontSize: Int?
    private var pageCount = 0

    mutating func update(_ window: PDFSentenceTextCanvas.Continuous, fontSize: Int, view: WKWebView) -> Bool {
        let reset = paperID != window.paperID || pageCount != window.pageCount
        if reset { pages.removeAll() }
        let removed = pages.keys.filter { window.pages[$0] == nil }
        var updates: [[String: Any]] = []
        for (index, page) in window.pages where page != pages[index] {
            var entry: [String: Any] = [
                "index": index, "notice": page.notice ?? "",
                "rows": PDFSentenceTextCanvas.Coordinator.rows(
                    page.sentences, translations: page.translations, paragraph: true),
            ]
            if page.illustrations != pages[index]?.illustrations {
                entry["figures"] = page.illustrations.map(PDFSentenceTextCanvas.Coordinator.figure)
            }
            updates.append(entry)
        }
        guard
            reset || !removed.isEmpty || !updates.isEmpty || jumpRevision != window.jumpRevision
                || self.fontSize != fontSize
        else { return false }
        view.callAsyncJavaScript(
            "window.sentenceReader.pageWindow(paper, count, updates, removed, target, revision, size)",
            arguments: [
                "paper": window.paperID.uuidString, "count": window.pageCount, "updates": updates, "removed": removed,
                "target": window.targetPage, "revision": window.jumpRevision, "size": fontSize,
            ], in: nil, in: .defaultClient, completionHandler: nil)
        pages = window.pages
        paperID = window.paperID
        pageCount = window.pageCount
        jumpRevision = window.jumpRevision
        self.fontSize = fontSize
        return true
    }
}

extension PDFSentenceTextCanvas {
    static let continuousScript = """
        // Each original page keeps a small locator in the DOM. Only the nearby pages own text and image nodes.
        function newFlow(paper,count) {
          const articles=[];
          const fragment=document.createDocumentFragment();
          for (let index=0; index<count; index++) {
            const section=document.createElement('article');
            section.className='source-page';
            section.dataset.page=index;
            const title=document.createElement('h2');
            title.className='page-marker';
            title.textContent='原页 '+(index+1);
            const body=document.createElement('div');
            body.className='page-body';
            section.append(title,body);
            fragment.append(section);
            articles.push({section,body,figures:[],ids:[]});
          }
          main.replaceChildren(fragment);
          main.setAttribute('aria-label','全文英汉段落对照');
          document.body.className='paragraph continuous';
          return {paper,articles,revision:null,loaded:new Set(),frame:0,previousPage:-1,previousSentence:'',ignoredY:null};
        }
        function shell(page) {
          if (page.loaded) {
            const measured=page.section.getBoundingClientRect().height;
            if (measured>0) page.height=measured;
          }
          if (page.section.classList.contains('untranslated')) {
            page.section.classList.remove('untranslated');
            page.section.firstChild.textContent='原页 '+(Number(page.section.dataset.page)+1);
          }
          page.section.style.minHeight=page.height ? page.height+'px' : 'max(48rem,100vh)';
          const pending=document.createElement('p');
          pending.className='page-loading';
          pending.textContent='正在读取本页…';
          page.body.replaceChildren(pending);
          for (const id of page.ids) pairs.delete(id);
          page.ids=[];page.figures=[];page.note=null;page.loaded=false;
        }
        function fillPage(page,update) {
          if (update.figures) page.figures=update.figures.map(makeFigure);
          page.section.style.removeProperty('min-height');
          const ids=update.rows.map(row=>row.id);
          const untranslated=ids.length>0 && !update.rows.some(row=>row.zh);
          page.section.classList.toggle('untranslated',untranslated);
          const marker='原页 '+(update.index+1)+(untranslated ? ' · 暂无译文' : '');
          if (page.section.firstChild.textContent!==marker) page.section.firstChild.textContent=marker;
          const keep=new Set(ids);
          for (const id of page.ids) if (!keep.has(id)) pairs.delete(id);
          page.ids=ids;
          if (update.notice || (!ids.length && !page.figures.length)) {
            const fallback=!ids.length && !page.figures.length;
            const note=page.note || document.createElement('p');
            const message=update.notice || '本页暂无可重排的文字。';
            if (note.dataset.message!==message || !!note.querySelector('button')!==fallback) {
              note.className='page-note';
              note.dataset.message=message;
              note.textContent=message;
              if (fallback) {
                const button=document.createElement('button');
                button.className='page-source';
                button.type='button';
                button.textContent='查看原页';
                button.dataset.original=update.index;
                button.setAttribute('aria-label','查看原页 '+(update.index+1));
                note.append(' ',button);
              }
            }
            page.note=note;
          } else page.note=null;
          renderRows(page.body,update.rows,page.figures,false,page.note);
          page.loaded=true;
        }
        function readingPage() {
          if (!flow?.articles.length) return null;
          const line=Math.min(innerHeight*.2,112);
          const pages=flow.articles;
          let low=0,high=pages.length-1;
          while (low<high) {
            const middle=(low+high+1)>>1;
            if (pages[middle].section.getBoundingClientRect().top<=line) low=middle;
            else high=middle-1;
          }
          // A short final page may never reach the reading line.
          if (scrollY>0 && scrollY+innerHeight>=document.documentElement.scrollHeight-2) return pages[pages.length-1];
          return pages[low];
        }
        function anchorAt(page) {
          const line=Math.min(innerHeight*.2,112);
          // Inline sentence boxes may wrap. Their leading edge remains stable even if the preceding page grows.
          for (const element of page.section.querySelectorAll('.page-marker,.page-note,figure,.en,.zh')) {
            const rect=element.getBoundingClientRect();
            if (rect.height && rect.bottom>line && rect.top<innerHeight) return {element,top:rect.top};
          }
          const rect=page.section.getBoundingClientRect();
          const fraction=(line-rect.top)/Math.max(1,rect.height);
          return {page,fraction:Math.max(0,Math.min(1,fraction)),line};
        }
        function restorePlace(anchor) {
          if (!anchor) return;
          if (anchor.element?.isConnected) {
            window.scrollBy(0,anchor.element.getBoundingClientRect().top-anchor.top);
          } else if (anchor.page) {
            const rect=anchor.page.section.getBoundingClientRect();
            window.scrollBy(0,rect.top+rect.height*anchor.fraction-anchor.line);
          }
        }
        function reportViewport() {
          if (!flow) return;
          flow.frame=0;
          if (flow.ignoredY!==null && Math.abs(flow.ignoredY-scrollY)<1) return;
          flow.ignoredY=null;
          const page=readingPage();
          if (!page) return;
          const index=Number(page.section.dataset.page);
          const sentence=anchorAt(page).element?.dataset.sentence || '';
          if (index!==flow.previousPage || sentence!==flow.previousSentence) {
            flow.previousPage=index;flow.previousSentence=sentence;
            post({action:'viewport',page:index,id:sentence});
          }
        }
        function scheduleViewport() {
          if (flow && !flow.frame) flow.frame=setTimeout(reportViewport,45);
        }
        function pageWindow(paper,count,updates,removed,target,revision,size) {
          const reset=!flow || flow.paper!==paper || flow.articles.length!==count;
          if (reset) {
            if (flow) clearTimeout(flow.frame);
            pairs.clear();figures=[];order=[];paragraphMode=true;
            flow=newFlow(paper,count);
            for (const page of flow.articles) shell(page);
          }
          const jump=reset || revision!==flow.revision;
          const oldPage=readingPage();
          const anchor=(!jump && oldPage) ? anchorAt(oldPage) : null;
          const startY=scrollY;
          const pendingWheel=!jump && flow.frame && (flow.ignoredY===null || Math.abs(flow.ignoredY-startY)>=1);
          flow.revision=revision;
          document.documentElement.style.setProperty('--zh-size',size+'px');
          for (const index of removed) {
            if (flow.articles[index]) shell(flow.articles[index]);
            flow.loaded.delete(index);
          }
          for (const update of updates) {
            const page=flow.articles[update.index];
            if (!page) continue;
            fillPage(page,update);
            flow.loaded.add(update.index);
          }
          order=[...flow.loaded].sort((a,b)=>a-b).flatMap(i=>flow.articles[i].ids);
          if (jump) {
            const page=flow.articles[target];
            if (page) page.section.scrollIntoView({block:'start',inline:'nearest'});
            flow.previousPage=target;
            flow.previousSentence='';
            flow.ignoredY=scrollY;
          } else {
            restorePlace(anchor);
            if (!pendingWheel && startY!==scrollY) flow.ignoredY=scrollY;
          }
        }
        """
}
