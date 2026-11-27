import Foundation

/// Runs only in WKContentWorld.defaultClient; paper HTML cannot invoke or replace this bridge.
enum HTMLReaderScript {
    static let source =
        HTMLNativeNoteEditorScript.source + HTMLSelectionScript.source + HTMLAnnotationMenuScript.source
        + HTMLNoteStyle.source
        + HTMLNoteLiftScript.source + HTMLNoteLayoutScript.source + HTMLNotesScript.source
        + HTMLImagePreviewScript.source + #"""
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
                const link = event.target.closest?.('a[href]');
                if(!link) return;
                event.preventDefault();
                const href = link.getAttribute('href');
                if(href.startsWith('#')) {
                  hideRefPeek();
                  const target = document.getElementById(href.slice(1));
                  if(target) target.scrollIntoView({block:'center',behavior:'instant'});
                  else send({kind:'missingLink'});
                } else send({kind:'externalLink',url:href});
              });
              // Hover peek popover for internal cross-references (figures, tables, equations, citations).
              let refPeek = null, refPeekTimer = null;
              const hideRefPeek = () => {
                clearTimeout(refPeekTimer);
                if (refPeek) { refPeek.remove(); refPeek = null; }
              };
              const showRefPeek = (link, target) => {
                hideRefPeek();
                const container = target.closest?.('figure, table, li, .equation, p, section') || target;
                const clone = container.cloneNode(true);
                clone.querySelectorAll?.('[id]').forEach(el => el.removeAttribute('id'));
                const box = document.createElement('div');
                box.id = 'pr-ref-peek';
                Object.assign(box.style, {
                  position: 'fixed', zIndex: '9999', maxWidth: '420px', maxHeight: '260px',
                  overflow: 'auto', padding: '10px 12px', borderRadius: '10px',
                  background: 'var(--paper-surface, #fffdf8)', color: 'var(--paper-ink, #292822)',
                  border: '1px solid var(--paper-line, #dfddd3)',
                  boxShadow: '0 8px 24px rgba(0,0,0,0.14)', fontSize: '13px', lineHeight: '1.5'
                });
                box.appendChild(clone);
                document.body.appendChild(box);
                const rect = link.getBoundingClientRect();
                const boxRect = box.getBoundingClientRect();
                const top = rect.bottom + 8 + boxRect.height <= window.innerHeight
                  ? rect.bottom + 8 : Math.max(8, rect.top - boxRect.height - 8);
                const left = Math.min(Math.max(8, rect.left), Math.max(8, window.innerWidth - boxRect.width - 8));
                box.style.top = top + 'px';
                box.style.left = left + 'px';
                box.addEventListener('mouseenter', () => clearTimeout(refPeekTimer));
                box.addEventListener('mouseleave', () => { refPeekTimer = setTimeout(hideRefPeek, 180); });
                refPeek = box;
              };
              document.addEventListener('mouseover', event => {
                const link = event.target.closest?.('a[href^="#"]');
                if (!link || (refPeek && refPeek.contains(link))) return;
                const id = link.getAttribute('href')?.slice(1);
                if (!id) return;
                const target = document.getElementById(id);
                if (!target) return;
                clearTimeout(refPeekTimer);
                refPeekTimer = setTimeout(() => showRefPeek(link, target), 240);
              });
              document.addEventListener('mouseout', event => {
                const link = event.target.closest?.('a[href^="#"]');
                if (!link) return;
                clearTimeout(refPeekTimer);
                refPeekTimer = setTimeout(hideRefPeek, 180);
              });
              document.addEventListener('scroll', hideRefPeek, {passive: true});
              document.addEventListener('keydown', event => { if (event.key === 'Escape') hideRefPeek(); });
              window.paperReader = {
                append(html, expectedPaperID) {
              if (document.body.dataset.paperId !== expectedPaperID) return;
                  const parsed = new DOMParser().parseFromString(html,'text/html');
                  for (const element of parsed.body.children) {
                    if (element.tagName !== 'SECTION' || !element.dataset.key) continue;
                    const existing = document.getElementById(element.id);
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
                    return;
                  }
                  const parsed = new DOMParser().parseFromString(html,'text/html');
                  const key = parsed.body.firstElementChild?.dataset.draftKey;
                  if(!key) return;
                  const existing = document.getElementById('block-'+key);
                  if(existing) {
                    draft?.remove();
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
