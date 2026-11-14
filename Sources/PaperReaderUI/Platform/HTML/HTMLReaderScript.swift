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
          document.addEventListener('click', event => {
            const image = event.target.closest?.('#reader img');
            if(image) {
              const dialog=document.createElement('dialog'), close=document.createElement('button');
              close.textContent='关闭'; close.setAttribute('aria-label','关闭放大图片');
              close.onclick=()=>dialog.close();
              const large=document.createElement('img');large.src=image.src;large.alt=image.alt;
              dialog.append(close,large);document.body.append(dialog);
              dialog.addEventListener('close',()=>dialog.remove(),{once:true});dialog.showModal();return;
            }
            const link = event.target.closest?.('a[href]');
            if(!link) return;
            event.preventDefault();
            const href = link.getAttribute('href');
            if(href.startsWith('#')) {
              const target = document.getElementById(href.slice(1));
              if(target) target.scrollIntoView({block:'center',behavior:'instant'});
              else send({kind:'missingLink'});
            } else send({kind:'externalLink',url:href});
          });
          window.paperReader = {
            append(html, expectedPaperID) {
          if (document.body.dataset.paperId !== expectedPaperID) return;
              const parsed = new DOMParser().parseFromString(html,'text/html');
              for (const element of parsed.body.children) {
                if (element.tagName !== 'SECTION' || !element.dataset.key) continue;
                const existing = document.getElementById(element.id);
                if(existing?.dataset.pending === 'true' && element.dataset.pending === 'false') {
                  existing.querySelector(':scope > .translation.pending')?.remove();
                  const translated = element.querySelector(':scope > .translation');
                  if(translated) existing.appendChild(document.importNode(translated,true));
                  existing.dataset.pending = 'false';
                }
                if (!existing) {
                  root.insertBefore(document.importNode(element,true), document.getElementById('translation-draft'));
                  const draft = document.getElementById('translation-draft');
                  if(draft?.firstElementChild?.dataset.draftKey === element.dataset.key) draft.remove();
                }
              }
              observe();
            },
            draft(html, expectedPaperID) {
              if(document.body.dataset.paperId !== expectedPaperID) return;
              let draft = document.getElementById('translation-draft');
              if(!html) {
                draft?.remove();
                for(const pending of root.querySelectorAll('.translation.pending.streaming')) {
                  pending.textContent='译文待加载…';pending.classList.remove('streaming');
                }
                return;
              }
              const parsed = new DOMParser().parseFromString(html,'text/html');
              const key = parsed.body.firstElementChild?.dataset.draftKey;
              if(!key) return;
              const existing = document.getElementById('block-'+key);
              if(existing) {
                draft?.remove();
                if(existing.dataset.pending !== 'true') return;
                const pending = existing.querySelector(':scope > .translation.pending');
                const translation = parsed.body.firstElementChild?.querySelector('.translation');
                if(pending && translation) {
                  pending.classList.add('streaming');
                  pending.replaceChildren(...[...translation.childNodes].map(e=>document.importNode(e,true)));
                }
                return;
              }
              if(!draft) { draft = document.createElement('div'); draft.id='translation-draft'; root.appendChild(draft); }
              draft.replaceChildren(...[...parsed.body.children].map(e=>document.importNode(e,true)));
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
