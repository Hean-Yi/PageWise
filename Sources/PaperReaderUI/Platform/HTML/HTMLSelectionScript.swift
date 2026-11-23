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
          let parts=[],savedMarks=[],lifted=[];
          const entriesByLayer=new Map();
          // WebKit fills inter-line gaps for one multiline Highlight range, but DOM rectangles do not.
          // Give both native paint and the lifted copy the same line fragments, including partial last lines.
          const lineRanges=range=>{
            if(range.startContainer!==range.endContainer||range.startContainer.nodeType!==3)return [range];
            const measured=[...range.getClientRects()].filter(b=>b.width>.01&&b.height>0);if(measured.length<=1)return measured.length?[range]:[];
            const node=range.startContainer,end=range.endOffset,result=[];
            const boxAt=offset=>{const r=document.createRange();r.setStart(node,offset);r.setEnd(node,Math.min(end,offset+1));return [...r.getClientRects()].filter(b=>b.width>.01&&b.height>0).at(-1);};
            let start=range.startOffset;
            while(start<end){
              const first=boxAt(start);if(!first){start++;continue;}
              let low=start+1,high=end;
              while(low<high){const mid=Math.floor((low+high)/2),box=boxAt(mid);if(box&&box.top>first.top+2)high=mid;else low=mid+1;}
              const fragment=document.createRange();fragment.setStart(node,start);fragment.setEnd(node,low);result.push(fragment);start=low;
            }
            return result;
          };
          // Temporary paint exclusions never change the saved anchors or published text.
          const visibleRanges=ranges=>!lifted.length?ranges:ranges.flatMap(range=>{
            if(range.startContainer!==range.endContainer)return [range];
            let spans=[[range.startOffset,range.endOffset]];
            for(const cut of lifted){if(cut.startContainer!==range.startContainer)continue;
              spans=spans.flatMap(([a,b])=>cut.endOffset<=a||cut.startOffset>=b?[[a,b]]:[[a,Math.max(a,cut.startOffset)],[Math.min(b,cut.endOffset),b]].filter(([s,e])=>e>s));
            }
            return spans.map(([a,b])=>{const r=document.createRange();r.setStart(range.startContainer,a);r.setEnd(range.endContainer,b);return r;});
          });
          const colors={yellow:'#f2d36b',red:'#f5aaa6',green:'#b7db9e',blue:'#b5d5f8',purple:'#cbb7ed',pink:'#edbdd8',orange:'#f5c28f',gray:'#d1d4d7'};
          const style=document.createElement('style');
          style.textContent='#reader{position:relative;z-index:1}#reader::selection,#reader ::selection{background:transparent;color:inherit}::highlight(reader-selection){background:transparent;color:inherit}[data-reader-selected]{outline:2px solid #424953!important;outline-offset:2px}[data-reader-saved]{outline:2px solid #c9a331;outline-offset:2px}';
          for(const [color,hex] of Object.entries(colors)) for(const kind of ['highlight','underline']) {
            const name=color==='yellow' && kind==='highlight' ? 'saved' : 'saved-'+color+'-'+kind;
            style.textContent+='::highlight('+name+'){background:transparent;'+(kind==='highlight' ? 'color:#292e2e' : '')+'}';
            style.textContent+='[data-reader-saved="'+color+'-'+kind+'"]{'+(kind==='highlight' ? 'outline:2px solid '+hex : 'outline:none;box-shadow:0 3px 0 '+hex)+'}';
          }
          if(CSS.highlights) document.head.append(style);
          // WebKit can coalesce adjacent highlight fragments and refill line gaps. Paint backgrounds
          // explicitly beneath the unchanged reader; native Highlight still supplies text foreground colors.
          const backgrounds=new Map();
          for(const name of ['saved','reader-selection']){
            const layer=document.createElement('div');layer.id=name==='saved'?'reader-annotation-backgrounds':'reader-selection-backgrounds';
            layer.setAttribute('aria-hidden','true');layer.style.cssText='position:absolute;left:0;top:0;width:100%;height:0;pointer-events:none;z-index:0';document.body.append(layer);backgrounds.set(name,layer);
          }
          const underlineLayer=document.createElement('div');underlineLayer.id='reader-annotation-lines';
          underlineLayer.setAttribute('aria-hidden','true');
          underlineLayer.style.cssText='position:absolute;left:0;top:0;width:100%;height:0;pointer-events:none;z-index:1';
          document.body.append(underlineLayer);

          // Each text slice owns its paint in a stable stacking position. Hover can clip
          // and restore a slice without measuring or replacing highlights in other paragraphs.
          const paintEntry=entry=>{
            const {range,highlight,container,color,kind}=entry,visible=visibleRanges([range]);
            for(const fragment of entry.fragments)highlight.delete(fragment);
            entry.fragments=visible.flatMap(lineRanges);
            for(const fragment of entry.fragments)highlight.add(fragment);
            const pixels=document.createDocumentFragment(),isLine=kind==='underline';
            for(const fragment of isLine?visible:entry.fragments)for(const rect of fragment.getClientRects()){
              if(rect.width<=.01||rect.height<=0)continue;
              const pixel=document.createElement('span');
              Object.assign(pixel.style,{position:'absolute',left:(rect.left+scrollX)+'px',width:rect.width+'px',
                top:((isLine?rect.bottom-2:rect.top)+scrollY)+'px'});
              if(isLine)pixel.style.borderBottom='2px solid '+color;
              else{pixel.style.height=rect.height+'px';pixel.style.background=color;}
              pixels.append(pixel);
            }
            container.replaceChildren(pixels);
          };
          const visitOverlaps=(ranges,visit)=>{
            for(const index of entriesByLayer.values())for(const cut of ranges){
              for(const entry of index.get(cut.startContainer)||[]){
                const mark=entry.range,start=Math.max(cut.startOffset,mark.startOffset),end=Math.min(cut.endOffset,mark.endOffset);
                if(start<end)visit(entry,start,end);
              }
            }
          };
          const liftRanges=ranges=>{
            const changed=new Set();
            visitOverlaps([...lifted,...ranges],entry=>changed.add(entry));
            lifted=ranges;
            for(const entry of changed)paintEntry(entry);
          };
          const render = (marks,name,attribute) => {
            backgrounds.get(name)?.replaceChildren();
            if(name==='saved')underlineLayer.replaceChildren();
            root.querySelectorAll('['+attribute+']').forEach(e=>e.removeAttribute(attribute));
            const index=new Map();entriesByLayer.set(name,index);
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
              if(!mark.target && mark.sourceOnly) {
                const translated=block.querySelector(':scope > .translation:not(.pending)');
                if(translated)ranges.push(...slices(nodes(translated),0,translated.textContent.length));
              }
            }
            if(name==='saved') for(const key of [...CSS.highlights.keys()]) if(key==='saved' || key.startsWith('saved-')) CSS.highlights.delete(key);
            if(!groups.has(name)) groups.set(name,[]);
            for(const [group,ranges] of groups) {
              const selected=name==='reader-selection',kind=group.endsWith('-underline')?'underline':'highlight';
              const color=selected?'rgba(35,42,50,.22)':colors[group==='saved'?'yellow':group.split('-')[1]];
              const layer=kind==='underline'?underlineLayer:backgrounds.get(name),batch=document.createDocumentFragment();
              const highlight=new Highlight();highlight.priority=selected?100:0;
              for(const range of ranges){
                const container=document.createElement('div'),entry={range,container,highlight,fragments:[],kind,color,selected};
                const node=range.startContainer;
                if(!index.has(node))index.set(node,[]);
                index.get(node).push(entry);paintEntry(entry);batch.append(container);
              }
              layer.append(batch);
              CSS.highlights.set(group,highlight);
            }
          };
          const paint = () => render(parts,'reader-selection','data-reader-selected');
          const publish = () => {paint();send({kind:'selection',parts});window.paperAnnotationMenu?.selectionChanged();};
          const update = () => {
            const selection=getSelection();
            if(window.paperNotes?.preservingSelection() || (selection?.isCollapsed && window.paperAnnotationMenu?.preservingSelection()))return;
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
            if(document.activeElement?.closest('.reader-note-card'))return;
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
          const repaint=()=>{render(savedMarks,'saved','data-reader-saved');paint();};
          window.addEventListener('resize',repaint);
          const layoutObserver=new ResizeObserver(repaint);
          layoutObserver.observe(root);
          document.fonts?.ready.then(repaint);
          const rangesFor=part=>{
            const block=document.getElementById('block-'+part.key);if(!block)return [];
            if(part.target?.startsWith('object:')) {
              const index=Number(part.target.slice(7)),e=objects(block)[index];
              if(!e || label(e,index)!==part.text)return [];
              const r=document.createRange();r.selectNode(e);return [r];
            }
            const source=nodes(block,part.target),text=source.map(n=>n.data).join('');
            return text.slice(part.start,part.end)===part.text ? slices(source,part.start,part.end) : [];
          };
          window.paperSelection={
            liftPaint(ranges){
              const result=[];
              visitOverlaps(ranges,({range:mark,color,kind,selected},start,end)=>{
                const range=document.createRange();range.setStart(mark.startContainer,start);range.setEnd(mark.startContainer,end);
                result.push({range,color,kind,selected});
              });
              return result.sort((a,b)=>Number(a.selected)-Number(b.selected));
            },
            liftRanges,
            highlights(marks){savedMarks=marks;render(marks,'saved','data-reader-saved');window.paperAnnotationMenu?.refresh();window.paperNotes?.layout();},
            refresh(){render(savedMarks,'saved','data-reader-saved');paint();},
            clear(){getSelection()?.removeAllRanges();parts=[];paint();window.paperAnnotationMenu?.hide();},
            selectObject(element){const range=document.createRange();range.selectNode(element);const s=getSelection();s.removeAllRanges();s.addRange(range);update();},
            copyText,
            lineRanges,
            rangesFor,
            restore(anchors){parts=anchors.filter(a=>rangesFor(a).length).map(a=>({...a,highlightStart:a.start,highlightEnd:a.end}));publish();},
            parts:()=>parts,
            projectedMarks:()=>savedMarks.map(mark=>({...mark,parts:projected(mark)})),
            selectionBounds(){const rectangles=[];for(const part of parts){const block=document.getElementById('block-'+part.key);if(!block)continue;if(part.target.startsWith('object:')){const e=objects(block)[Number(part.target.slice(7))];if(e)rectangles.push(e.getBoundingClientRect());}else for(const r of slices(nodes(block,part.target),part.start,part.end))rectangles.push(...r.getClientRects());}return rectangles.filter(r=>r.bottom>0 && r.top<innerHeight);}
          };
        })();
        """#
}
