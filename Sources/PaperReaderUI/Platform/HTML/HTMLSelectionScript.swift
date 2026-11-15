import Foundation

/// Language-scoped text ranges and shared objects, without rewriting published text.
enum HTMLSelectionScript {
    static let source = #"""
        (() => {
          const root = document.getElementById('reader');
          if (!root) return;
          const send = value => window.webkit.messageHandlers.reader.postMessage(value);
          const objects = block => [...block.querySelectorAll('img,svg,table,math,.paper-equation')]
            .filter(e=>!e.parentElement.closest('svg,table,math,.paper-equation') && !e.closest('.pending'))
            .filter(e=>!e.matches('table') || e.textContent.trim() || e.querySelector('img,svg,math'));
          const objectFor = (element, block) => objects(block).find(e=>e===element || e.contains(element));
          const language = node => {
            const e=node?.nodeType===1 ? node : node?.parentElement;
            if(!e || !root.contains(e) || e.closest('.pending')) return null;
            const block=e.closest('section[data-key]');
            if(!block) return null;
            const object=objectFor(e,block);
            if(object && !object.closest('p,figcaption,.translation')) return null;
            return e.closest('.translation') ? 'translation' : 'source';
          };
          const nodes = (element, target = 'legacy') => {
            const result=[], shared=objects(element), walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);
            let node;
            while(node=walker.nextNode()) {
              const parent=node.parentElement;
              if(target==='legacy' || (target==='legacy-source' && !parent.closest('.translation'))) {
                result.push(node); continue;
              }
              if(parent.closest('.pending') || shared.some(e=>e===parent || e.contains(parent))) continue;
              if((parent.closest('.translation') ? 'translation' : 'source')===target) result.push(node);
            }
            return result;
          };
          const slices = (textNodes,start,end) => {
            let offset=0; const ranges=[];
            for(const node of textNodes) {
              const next=offset+node.length;
              if(end>offset && start<next) {
                const range=document.createRange();
                range.setStart(node,Math.max(0,start-offset));
                range.setEnd(node,Math.min(node.length,end-offset));
                if(range.toString().trim()) ranges.push(range);
              }
              offset=next;
            }
            return ranges;
          };
          const intersection = (range,node) => {
            if(!range.intersectsNode(node)) return null;
            const clipped=document.createRange();clipped.selectNodeContents(node);
            if(range.compareBoundaryPoints(Range.START_TO_START,clipped)>0)
              clipped.setStart(range.startContainer,range.startOffset);
            if(range.compareBoundaryPoints(Range.END_TO_END,clipped)<0)
              clipped.setEnd(range.endContainer,range.endOffset);
            return clipped.collapsed ? null : clipped;
          };
          const label = (element,index) => {
            if(element.matches('img,svg')) return '[图片 '+(index+1)+']';
            if(element.matches('table:not(.paper-equation)')) {
              const rows=[...element.rows].map(row=>[...row.cells].map(cell=>(cell.textContent.replace(/\s+/g,' ').trim() || (cell.querySelector('img,svg') ? '[图片]' : ''))).join('\t'));
              return '[表格] '+(element.caption ? element.caption.textContent.trim()+'\n' : '')+rows.join('\n');
            }
            const tex=element.querySelector('annotation[encoding="application/x-tex"]');
            const text=element.getAttribute('alttext') || tex?.textContent || nodes(element).map(n=>n.data.trim()).join('');
            return '[公式] '+text;
          };
          const wordBounds = (text,start,end) => {
            const originalStart=start;
            // ASCII/Latin scientific terms, including apostrophes and internal hyphens.
            const words=/[\p{L}\p{N}\p{M}]+(?:['’\-‐‑][\p{L}\p{N}\p{M}]+)*/gu;
            for(const match of text.matchAll(words)) {
              const a=match.index,b=a+match[0].length;
              if(a<start && start<b) start=b;
              if(a<end && end<b) end=a;
            }
            while(start<end && /\s/.test(text[start])) start++;
            while(end>start && /\s/.test(text[end-1])) end--;
            return start<end ? [start,end] : [originalStart,originalStart];
          };
          let parts=[],savedMarks=[];
          const style=document.createElement('style');
          style.textContent='#reader::selection,#reader ::selection{background:transparent;color:inherit}::highlight(reader-selection){background:#b5d5f8;color:inherit}[data-reader-selected]{outline:2px solid #83b3ed;outline-offset:2px}[data-reader-saved]{outline:2px solid #c9a331;outline-offset:2px}';
          if(CSS.highlights) document.head.append(style);
          const render = (marks,name,attribute) => {
            root.querySelectorAll('['+attribute+']').forEach(e=>e.removeAttribute(attribute));
            if(!CSS.highlights) return;
            const ranges=[];
            for(const mark of marks) {
              const block=document.getElementById('block-'+mark.key);
              if(!block) continue;
              if(mark.target?.startsWith('object:')) {
                const index=Number(mark.target.slice(7)),element=objects(block)[index];
                if(element && label(element,index)===mark.text) element.setAttribute(attribute,'');
                continue;
              }
              const target=mark.target || (mark.sourceOnly ? 'legacy-source' : 'legacy');
              const source=nodes(block,target),text=source.map(n=>n.data).join('');
              const [start,end]=mark.range || [mark.start,mark.end];
              if(text.slice(start,end)!==mark.text) continue;
              ranges.push(...slices(source,start,end));
              if(!mark.target && mark.sourceOnly) {
                const translated=block.querySelector(':scope > .translation:not(.pending)');
                if(translated) ranges.push(...slices(nodes(translated),0,translated.textContent.length));
              }
            }
            CSS.highlights.set(name,new Highlight(...ranges));
          };
          const paint = () => render(parts,'reader-selection','data-reader-selected');
          const publish = () => {paint();send({kind:'selection',parts});};
          const update = () => {
            const selection=getSelection();parts=[];
            if(selection && !selection.isCollapsed && selection.rangeCount) {
              const range=selection.getRangeAt(0);
              const chosen=language(selection.anchorNode) || language(selection.focusNode) || 'source';
              for(const block of root.querySelectorAll(':scope > section[data-key]')) {
                if(!range.intersectsNode(block)) continue;
                const textNodes=nodes(block,chosen),text=textNodes.map(n=>n.data).join('');
                const entries=[];let offset=0;
                for(const node of textNodes) {
                  const clipped=intersection(range,node);
                  if(clipped) {
                    const start=offset+(clipped.startContainer===node ? clipped.startOffset : 0);
                    const end=offset+(clipped.endContainer===node ? clipped.endOffset : node.length);
                    if(end>start) entries.push({node,target:chosen,start,end,text:text.slice(start,end)});
                  }
                  offset+=node.length;
                }
                objects(block).forEach((element,index)=>{
                  const inline=element.matches('math') && element.getAttribute('display')!=='block' && !!element.closest('p,figcaption,.translation') && !element.closest('.paper-equation');
                  const owner=element.closest('.translation') ? 'translation' : 'source';
                  const extent=document.createRange();extent.selectNode(element);
                  const overlaps=range.compareBoundaryPoints(Range.END_TO_START,extent)<0 && range.compareBoundaryPoints(Range.START_TO_END,extent)>0;
                  if((inline && owner!==chosen) || !overlaps) return;
                  const value=label(element,index);
                  entries.push({node:element,target:'object:'+index,start:0,end:value.length,text:value});
                });
                entries.sort((a,b)=>a.node.compareDocumentPosition(b.node)&Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
                const merged=[];
                for(const entry of entries) {
                  const last=merged[merged.length-1];
                  if(last && last.target===entry.target && last.end===entry.start) {
                    last.end=entry.end;last.text+=entry.text;
                  } else merged.push({...entry});
                }
                for(const entry of merged) {
                  if(!entry.text.trim()) continue;
                  const bounds=entry.target==='source' ? wordBounds(text,entry.start,entry.end) : [entry.start,entry.end];
                  parts.push({key:block.dataset.key,target:entry.target,start:entry.start,end:entry.end,text:entry.text,
                    highlightStart:bounds[0],highlightEnd:bounds[1]});
                }
              }
            }
            publish();
          };
          const copyText = () => {
            let result='',key=null;
            for(const part of parts) {
              if(key!==null && key!==part.key) result+='\n\n';
              if(part.target.startsWith('object:')) result+=' '+part.text+' ';
              else result+=part.text;
              key=part.key;
            }
            return result.trim();
          };
          document.addEventListener('selectionchange',update);
          document.addEventListener('dragstart',event=>{if(event.target.closest?.('#reader img')) event.preventDefault();});
          document.addEventListener('copy',event=>{
            if(!parts.length || !event.clipboardData) return;
            event.clipboardData.setData('text/plain',copyText());event.preventDefault();
          });
          window.paperSelection={
            highlights(marks){savedMarks=marks;render(marks,'saved','data-reader-saved');},
            refresh(){render(savedMarks,'saved','data-reader-saved');paint();},
            clear(){getSelection()?.removeAllRanges();parts=[];paint();},
            selectObject(element){const range=document.createRange();range.selectNode(element);const s=getSelection();s.removeAllRanges();s.addRange(range);update();},
            copyText
          };
        })();
        """#
}
