import Foundation

/// Normalizes bilingual selections to source text without changing published DOM or layout.
enum HTMLSelectionScript {
    static let source = #"""
        (() => {
          const root = document.getElementById('reader');
          if (!root) return;
          const send = value => window.webkit.messageHandlers.reader.postMessage(value);
          const nodes = (element, sourceOnly = false) => {
            const result = [], walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
            let node;
            while (node = walker.nextNode()) {
              if (sourceOnly && node.parentElement.closest('.translation')) continue;
              result.push(node);
            }
            return result;
          };
          const slices = (textNodes, start, end) => {
            let offset = 0; const ranges = [];
            for (const node of textNodes) {
              const next = offset + node.length;
              if (end > offset && start < next) {
                const range = document.createRange();
                range.setStart(node, Math.max(0, start-offset));
                range.setEnd(node, Math.min(node.length, end-offset));
                if (range.toString().trim()) ranges.push(range);
              }
              offset = next;
            }
            return ranges;
          };
          const intersection = (range, node) => {
            if (!range.intersectsNode(node)) return null;
            const clipped = document.createRange(); clipped.selectNodeContents(node);
            if (range.compareBoundaryPoints(Range.START_TO_START, clipped) > 0)
              clipped.setStart(range.startContainer, range.startOffset);
            if (range.compareBoundaryPoints(Range.END_TO_END, clipped) < 0)
              clipped.setEnd(range.endContainer, range.endOffset);
            return clipped.collapsed ? null : clipped;
          };
          let parts = [], savedMarks = [];
          if (CSS.highlights) {
            const style = document.createElement('style');
            style.textContent = '#reader::selection,#reader ::selection{background:transparent;color:inherit}::highlight(reader-selection){background:#b5d5f8;color:inherit}';
            document.head.append(style);
          }
          const paint = () => {
            if (!CSS.highlights) return;
            const ranges = [];
            for (const part of parts) {
              const block = document.getElementById('block-'+part.key);
              if (block) ranges.push(...slices(nodes(block,true),part.start,part.end));
            }
            CSS.highlights.set('reader-selection',new Highlight(...ranges));
          };
          const update = () => {
            const selection = getSelection();
            parts = [];
            if (selection && !selection.isCollapsed && selection.rangeCount) {
              const range = selection.getRangeAt(0);
              for (const block of root.querySelectorAll(':scope > section[data-key]')) {
                if (!range.intersectsNode(block)) continue;
                const source = nodes(block,true), text = source.map(n=>n.data).join('');
                let offset = 0, start = null, end = null;
                for (const node of source) {
                  const clipped = intersection(range,node);
                  if (clipped && clipped.toString().trim()) {
                    const from = clipped.startContainer === node ? clipped.startOffset : 0;
                    const to = clipped.endContainer === node ? clipped.endOffset : node.length;
                    if (start === null) start = offset + from;
                    end = offset + to;
                  }
                  offset += node.length;
                }
                // Translations share a paragraph anchor; no speculative word alignment.
                if (start === null) {
                  const translated = block.querySelector(':scope > .translation:not(.pending)');
                  if (translated && nodes(translated).some(n=>intersection(range,n)?.toString().trim())) {
                    start = 0; end = text.length;
                  }
                }
                if (start !== null && text.slice(start,end).trim())
                  parts.push({key:block.dataset.key,start,end,text:text.slice(start,end)});
              }
            }
            paint();
            send({kind:'selection',parts});
          };
          document.addEventListener('selectionchange',update);
          document.addEventListener('copy',event => {
            if (!parts.length || !event.clipboardData) return;
            event.clipboardData.setData('text/plain',parts.map(p=>p.text.trim()).join('\n\n'));
            event.preventDefault();
          });
          const highlights = marks => {
            savedMarks = marks;
            if (!CSS.highlights) return;
            const ranges = [];
            for (const mark of marks) {
              const block = document.getElementById('block-'+mark.key);
              if (!block || !Array.isArray(mark.range) || mark.range.length !== 2) continue;
              const source = nodes(block,mark.sourceOnly === true), text = source.map(n=>n.data).join('');
              const [start,end] = mark.range;
              if (text.slice(start,end) !== mark.text) continue;
              ranges.push(...slices(source,start,end));
              if (mark.sourceOnly) {
                const translated = block.querySelector(':scope > .translation:not(.pending)');
                if (translated) ranges.push(...slices(nodes(translated),0,translated.textContent.length));
              }
            }
            CSS.highlights.set('saved',new Highlight(...ranges));
          };
          window.paperSelection = {
            highlights,
            refresh() { highlights(savedMarks); paint(); },
            clear() { getSelection()?.removeAllRanges(); parts=[]; paint(); },
            copyText() { return parts.map(p=>p.text.trim()).join('\n\n'); }
          };
        })();
        """#
}
