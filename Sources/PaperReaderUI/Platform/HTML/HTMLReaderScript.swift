import Foundation

/// Runs only in WKContentWorld.defaultClient; paper HTML cannot invoke or replace this bridge.
enum HTMLReaderScript {
    static let source = #"""
        (() => {
          const send = value => window.webkit.messageHandlers.reader.postMessage(value);
          const root = document.getElementById('reader');
          if (!root) return;
          let lastKey = null, queued = false;
          const visible = new Set();
          const report = () => {
            queued = false;
            const candidates = [...visible].filter(e => e.getBoundingClientRect().bottom > 0);
            candidates.sort((a,b) => Math.abs(a.getBoundingClientRect().top) - Math.abs(b.getBoundingClientRect().top));
            const key = candidates[0]?.dataset.key;
            if (key && key !== lastKey) { lastKey = key; send({kind:'position',key}); }
          };
          const observer = new IntersectionObserver(entries => {
            for (const entry of entries) entry.isIntersecting ? visible.add(entry.target) : visible.delete(entry.target);
            if (!queued) { queued = true; requestAnimationFrame(report); }
          });
          const observe = () => root.querySelectorAll(':scope > section').forEach(e => observer.observe(e));
          observe();
          document.addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(report); } }, {passive:true});
          const section = node => (node.nodeType === 1 ? node : node.parentElement)?.closest('section[data-key]');
          document.addEventListener('selectionchange', () => {
            const selection = window.getSelection();
            if (!selection || selection.isCollapsed || !selection.rangeCount) { send({kind:'selection',text:''}); return; }
            const range = selection.getRangeAt(0), first = section(range.startContainer), last = section(range.endContainer);
            if (!first || first !== last) { send({kind:'crossSelection'}); return; }
            const prefix = document.createRange(); prefix.selectNodeContents(first); prefix.setEnd(range.startContainer,range.startOffset);
            const start = prefix.toString().length, text = range.toString();
            send({kind:'selection',key:first.dataset.key,text,start,end:start+text.length});
          });
          document.addEventListener('error', event => { if(event.target.tagName === 'IMG') send({kind:'imageError'}); }, true);
          window.paperReader = {
            append(html, expectedPaperID) {
          if (document.body.dataset.paperId !== expectedPaperID) return;
              const parsed = new DOMParser().parseFromString(html,'text/html');
              for (const element of parsed.body.children) {
                if (element.tagName === 'SECTION' && element.dataset.key && !document.getElementById(element.id)) root.appendChild(document.importNode(element,true));
              }
              observe();
            },
            jump(key) { document.getElementById('block-'+key)?.scrollIntoView({block:'start',behavior:'instant'}); },
            highlights(marks) {
              if (!CSS.highlights) return;
              const ranges = [];
              for (const mark of marks) {
                const block = document.getElementById('block-'+mark.key);
                if (!block || !Array.isArray(mark.range) || mark.range.length !== 2) continue;
                const [start,end] = mark.range, walker = document.createTreeWalker(block,NodeFilter.SHOW_TEXT);
                let offset=0, first=null, last=null, node;
                while(node=walker.nextNode()) {
                  const next=offset+node.textContent.length;
                  if (!first && start >= offset && start < next) first=[node,start-offset];
                  if (end > offset && end <= next) { last=[node,end-offset]; break; }
                  offset=next;
                }
                if (first && last) {
                  const range=document.createRange(); range.setStart(...first); range.setEnd(...last);
                  if (range.toString() === mark.text) ranges.push(range);
                }
              }
              CSS.highlights.set('saved',new Highlight(...ranges));
            }
          };
        })();
        """#
}
