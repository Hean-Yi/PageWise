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
          let parts=[],savedMarks=[];
          const colors={yellow:'#ead078',red:'#e69a96',green:'#a9c995',blue:'#9dbfe2',purple:'#bda7d7',pink:'#dba7c3',orange:'#e6b184',gray:'#bdc0c4'};
          const style=document.createElement('style');
          style.textContent='#reader::selection,#reader ::selection{background:transparent;color:inherit}::highlight(reader-selection){background:rgba(35,42,50,.22);color:inherit}[data-reader-selected]{outline:2px solid #424953!important;outline-offset:2px}[data-reader-saved]{outline:2px solid #c9a331;outline-offset:2px}';
          for(const [color,hex] of Object.entries(colors)) for(const kind of ['highlight','underline']) {
            const name=color==='yellow' && kind==='highlight' ? 'saved' : 'saved-'+color+'-'+kind;
            style.textContent+='::highlight('+name+'){'+(kind==='highlight' ? 'background:'+hex+';color:#292e2e' : 'background:transparent')+'}';
            style.textContent+='[data-reader-saved="'+color+'-'+kind+'"]{'+(kind==='highlight' ? 'outline:2px solid '+hex : 'outline:none;box-shadow:0 3px 0 '+hex)+'}';
          }
          if(CSS.highlights) document.head.append(style);
          const underlineLayer=document.createElement('div');underlineLayer.id='reader-annotation-lines';
          underlineLayer.setAttribute('aria-hidden','true');
          underlineLayer.style.cssText='position:absolute;left:0;top:0;width:100%;height:0;pointer-events:none;z-index:1';
          document.body.append(underlineLayer);
          const underline=(ranges,color)=>{
            for(const range of ranges) for(const rect of range.getClientRects()) {
              if(!rect.width || !rect.height)continue;
              const line=document.createElement('span');line.style.cssText='position:absolute;pointer-events:none;border-bottom:2px solid '+colors[color]+';left:'+(rect.left+scrollX)+'px;top:'+(rect.bottom+scrollY-2)+'px;width:'+rect.width+'px';
              underlineLayer.append(line);
            }
          };
          const render = (marks,name,attribute) => {
            if(name==='saved')underlineLayer.replaceChildren();
            root.querySelectorAll('['+attribute+']').forEach(e=>e.removeAttribute(attribute));
            if(!CSS.highlights) return;
            const groups=new Map();
            for(const mark of marks) {
              const block=document.getElementById('block-'+mark.key);
              if(!block) continue;
              const color=colors[mark.color] ? mark.color : 'yellow',kind=mark.style==='underline' ? 'underline' : 'highlight';
              const group=name==='saved' && !(color==='yellow' && kind==='highlight') ? 'saved-'+color+'-'+kind : name;
              if(!groups.has(group)) groups.set(group,[]);
              const ranges=groups.get(group);
              if(mark.target?.startsWith('object:')) {
                const index=Number(mark.target.slice(7)),element=objects(block)[index];
                if(element && label(element,index)===mark.text) element.setAttribute(attribute,color+'-'+kind);
                continue;
              }
              const target=mark.target || (mark.sourceOnly ? 'legacy-source' : 'legacy');
              const source=nodes(block,target),text=source.map(n=>n.data).join('');
              const [start,end]=mark.range || [mark.start,mark.end];
              if(text.slice(start,end)!==mark.text) continue;
              const selected=slices(source,start,end);
              ranges.push(...selected);
              if(name==='saved' && kind==='underline')underline(selected,color);
              if(!mark.target && mark.sourceOnly) {
                const translated=block.querySelector(':scope > .translation:not(.pending)');
                if(translated) {const linked=slices(nodes(translated),0,translated.textContent.length);ranges.push(...linked);if(kind==='underline')underline(linked,color);}
              }
            }
            if(name==='saved') for(const key of [...CSS.highlights.keys()]) if(key==='saved' || key.startsWith('saved-')) CSS.highlights.delete(key);
            if(!groups.has(name)) groups.set(name,[]);
            for(const [group,ranges] of groups) {
              const highlight=new Highlight(...ranges);
              // Composite the translucent selection above every saved annotation, regardless of insertion order.
              highlight.priority=name==='reader-selection' ? 100 : 0;
              CSS.highlights.set(group,highlight);
            }
          };
          const paint = () => render(parts,'reader-selection','data-reader-selected');
          const publish = () => {paint();send({kind:'selection',parts});window.paperAnnotationMenu?.selectionChanged();};
          const update = () => {
            const selection=getSelection();
            if(selection?.isCollapsed && window.paperAnnotationMenu?.preservingSelection())return;
            parts=[];
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
                  parts.push({key:block.dataset.key,target:entry.target,start:entry.start,end:entry.end,text:entry.text,
                    highlightStart:entry.start,highlightEnd:entry.end});
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
          const projected = mark => {
            if(mark.target) return [{target:mark.target,range:mark.range,text:mark.text}];
            const block=document.getElementById('block-'+mark.key);
            if(!block) return [];
            const legacy=nodes(block,mark.sourceOnly ? 'legacy-source' : 'legacy');
            if(legacy.map(n=>n.data).join('').slice(...mark.range)!==mark.text) return [];
            const ranges=slices(legacy,...mark.range);
            if(mark.sourceOnly) {
              const translation=block.querySelector(':scope > .translation:not(.pending)');
              if(translation) {const range=document.createRange();range.selectNodeContents(translation);ranges.push(range);}
            }
            const result=[];
            for(const target of ['source','translation']) {
              let offset=0;
              for(const node of nodes(block,target)) {
                for(const range of ranges) {
                  const clipped=intersection(range,node);
                  if(!clipped || !clipped.toString().trim()) continue;
                  const start=offset+(clipped.startContainer===node ? clipped.startOffset : 0);
                  const end=offset+(clipped.endContainer===node ? clipped.endOffset : node.length);
                  const last=result[result.length-1];
                  if(last && last.target===target && last.range[1]===start) {last.range[1]=end;last.text+=clipped.toString();}
                  else result.push({target,range:[start,end],text:clipped.toString()});
                }
                offset+=node.length;
              }
            }
            objects(block).forEach((element,index)=>{
              if(ranges.some(r=>r.intersectsNode(element))) {const text=label(element,index);result.push({target:'object:'+index,range:[0,text.length],text});}
            });
            return result;
          };
          window.addEventListener('resize',()=>render(savedMarks,'saved','data-reader-saved'));
          const layoutObserver=new ResizeObserver(()=>render(savedMarks,'saved','data-reader-saved'));
          layoutObserver.observe(root);
          document.fonts?.ready.then(()=>render(savedMarks,'saved','data-reader-saved'));
          window.paperSelection={
            highlights(marks){savedMarks=marks;render(marks,'saved','data-reader-saved');window.paperAnnotationMenu?.refresh();},
            refresh(){render(savedMarks,'saved','data-reader-saved');paint();},
            clear(){getSelection()?.removeAllRanges();parts=[];paint();window.paperAnnotationMenu?.hide();},
            selectObject(element){const range=document.createRange();range.selectNode(element);const s=getSelection();s.removeAllRanges();s.addRange(range);update();},
            copyText,
            parts:()=>parts,
            projectedMarks:()=>savedMarks.map(mark=>({...mark,parts:projected(mark)})),
            selectionBounds(){const rectangles=[];for(const part of parts){const block=document.getElementById('block-'+part.key);if(!block)continue;if(part.target.startsWith('object:')){const e=objects(block)[Number(part.target.slice(7))];if(e)rectangles.push(e.getBoundingClientRect());}else for(const r of slices(nodes(block,part.target),part.start,part.end))rectangles.push(...r.getClientRects());}return rectangles.filter(r=>r.bottom>0 && r.top<innerHeight);}
          };
        })();
        """#
}
