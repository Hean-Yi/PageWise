import Foundation

/// Runs only in WKContentWorld.defaultClient; paper HTML cannot invoke or replace this bridge.
enum HTMLReaderScript {
    static let source =
        HTMLSelectionScript.source + #"""
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
              document.addEventListener('error', event => { if(event.target.tagName === 'IMG') send({kind:'imageError'}); }, true);
              document.addEventListener('click', event => {
                const image = event.target.closest?.('#reader img');
                if(image) {
                  const dialog=document.createElement('dialog'), close=document.createElement('button');
                  close.textContent='关闭'; close.setAttribute('aria-label','关闭放大图片');
                  close.onclick=()=>dialog.close();
                  const large=document.createElement('img');large.src=image.src;large.alt=image.alt;
                  const quote=document.createElement('button');quote.textContent='引用图片';
                  quote.onclick=()=>{dialog.close();window.paperSelection.selectObject(image);};
                  dialog.append(close,quote,large);document.body.append(dialog);
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
                  window.paperSelection.refresh();
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
                highlights(marks) { window.paperSelection.highlights(marks); },
                clearSelection() { window.paperSelection.clear(); }
              };
            })();
            """#
}
