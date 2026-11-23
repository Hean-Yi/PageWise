import Foundation

/// Transfers only the active text paint into one moving layer; document geometry stays immutable.
enum HTMLNoteLiftScript {
    static let source = #"""
        (()=>{
          const selection=window.paperSelection,ns='http://www.w3.org/2000/svg';
          const host=document.createElement('div');host.id='reader-note-lift';host.setAttribute('aria-hidden','true');document.body.append(host);
          let current=null,timer=null,masked=[];
          const clearWaves=()=>{for(const wave of masked)wave.removeAttribute('mask');masked=[];document.getElementById('note-wave-cutouts')?.remove();};
          const clear=()=>{clearTimeout(timer);timer=null;if(!current)return;current.animation?.cancel();current=null;host.replaceChildren();CSS.highlights?.delete('note-lift');selection.liftRanges([]);clearWaves();};
          const boxes=range=>selection.lineRanges(range).flatMap(r=>[...r.getClientRects()]).filter(r=>r.width>.01&&r.height>0);
          const paintBox=(rect,kind,color)=>{
            const e=document.createElement('i');e.className=kind;
            Object.assign(e.style,{left:rect.left+'px',top:(rect.top+scrollY)+'px',width:rect.width+'px',height:rect.height+'px',background:color});return e;
          };
          const waves=(svg,wavesNear)=>{
            if(!current)return;
            clearWaves();
            // Clip both copies to the same text rectangles, including partial overlaps with other notes.
            const defs=document.createElementNS(ns,'defs');defs.id='note-wave-cutouts';
            const mask=document.createElementNS(ns,'mask');mask.id='note-wave-stationary';mask.setAttribute('maskUnits','userSpaceOnUse');
            mask.setAttribute('x','0');mask.setAttribute('y','0');mask.setAttribute('width','100%');mask.setAttribute('height',document.documentElement.scrollHeight+20);
            const white=document.createElementNS(ns,'rect');white.setAttribute('width','100%');white.setAttribute('height',document.documentElement.scrollHeight+20);white.setAttribute('fill','white');mask.append(white);
            const clip=document.createElementNS(ns,'clipPath');clip.id='note-wave-moving';clip.setAttribute('clipPathUnits','userSpaceOnUse');
            for(const r of current.rects){const cut=document.createElementNS(ns,'rect');cut.setAttribute('x',r.left);cut.setAttribute('y',r.top);cut.setAttribute('width',r.width);cut.setAttribute('height',r.height+10);clip.append(cut.cloneNode());cut.setAttribute('fill','black');mask.append(cut);}
            defs.append(mask,clip);svg.append(defs);
            current.group.querySelector('svg')?.remove();const moving=document.createElementNS(ns,'svg');moving.classList.add('note-lift-waves');
            const clipped=document.createElementNS(ns,'g');clipped.setAttribute('clip-path','url(#note-wave-moving)');moving.append(clipped);
            for(const p of wavesNear(current.rects)){
              clipped.append(p.cloneNode(true));p.setAttribute('mask','url(#note-wave-stationary)');masked.push(p);
            }
            current.group.append(moving);
          };
          const update=(active,svg,wavesNear)=>{
            const reduced=matchMedia('(prefers-reduced-motion:reduce)').matches;
            if(!active){
              if(!current)return;
              if(reduced){clear();return;}
              if(masked.some(p=>!p.isConnected))waves(svg,wavesNear);
              if(timer)return;
              current.group.querySelectorAll('.note-lift-selection').forEach(e=>e.remove());
              const from=getComputedStyle(current.group).transform;current.animation?.cancel();
              current.animation=current.group.animate([{transform:from},{transform:'translateY(0)'}],{duration:160,fill:'forwards',easing:'ease-out'});
              timer=setTimeout(clear,170);return;
            }
            const ranges=active.anchors.filter(a=>!a.target.startsWith('object:')).flatMap(a=>selection.rangesFor(a));
            // Keep very large and complex content in place instead of lifting a partial sentence.
            if(!CSS.highlights||!ranges.length||ranges.some(r=>r.startContainer!==r.endContainer||r.startContainer.nodeType!==3)||ranges.reduce((n,r)=>n+r.toString().length,0)>2000){clear();return;}
            const key=JSON.stringify(active.anchors),same=current?.key===key&&!timer;
            if(!same)clear();
            const paints=selection.liftPaint(ranges),rects=ranges.flatMap(boxes).map(r=>({left:r.left,top:r.top+scrollY,width:r.width,height:r.height}));
            const lines=new Set(rects.map(r=>Math.round(r.top/2))),dy=lines.size>1?-1:-2;
            if(!same){const group=document.createElement('div');group.className='note-lift-group';host.append(group);current={key,group,rects,dy};}
            const group=current.group;current.rects=rects;current.dy=dy;group.replaceChildren();group.style.transform='translateY('+(reduced?0:dy)+'px)';
            for(const p of paints)if(p.kind==='highlight')for(const r of boxes(p.range))group.append(paintBox(r,p.selected?'note-lift-selection':'note-lift-highlight',p.color));
            for(const range of ranges){
              const node=range.startContainer,css=getComputedStyle(node.parentElement),inks=paints.filter(p=>!p.selected&&p.kind==='highlight'&&p.range.startContainer===node);
              for(const line of selection.lineRanges(range)){
                const cuts=new Set([line.startOffset,line.endOffset]);
                for(const {range:ink} of inks)for(const offset of [ink.startOffset,ink.endOffset])if(offset>line.startOffset&&offset<line.endOffset)cuts.add(offset);
                // Collapsed whitespace and justification can introduce gaps inside a run.
                const spaces=css.textAlign==='justify'?/[\t\r\n\f ]+/g:/[\t\r\n\f]+| {2,}/g;
                for(const gap of line.toString().matchAll(spaces)){
                  const start=line.startOffset+gap.index;cuts.add(start);cuts.add(start+gap[0].length);
                }
                const offsets=[...cuts].sort((a,b)=>a-b);
                for(let i=1;i<offsets.length;i++){
                  const start=offsets[i-1],end=offsets[i],run=document.createRange();run.setStart(node,start);run.setEnd(node,end);
                  // WebKit may report a zero-width fragment on the preceding wrapped line.
                  const box=[...run.getClientRects()].find(r=>r.width>.01&&r.height>0);if(!box)continue;
                  const color=inks.some(p=>start<p.range.endOffset&&end>p.range.startOffset)?'#292e2e':css.color;
                  const span=document.createElement('span');span.className='note-lift-text';
                  span.textContent=css.whiteSpace.startsWith('pre')?run.toString():run.toString().replace(/[\t\r\n\f ]+/g,' ');
                  Object.assign(span.style,{left:box.left+'px',top:(box.top+scrollY)+'px',fontFamily:css.fontFamily,fontSize:css.fontSize,fontWeight:css.fontWeight,fontStyle:css.fontStyle,fontVariant:css.fontVariant,lineHeight:box.height+'px',color,letterSpacing:css.letterSpacing,wordSpacing:css.wordSpacing});group.append(span);
                }
              }
            }
            for(const p of paints)if(p.kind==='underline')for(const r of boxes(p.range)){const line=paintBox(r,'note-lift-underline',p.color);line.style.top=(r.bottom+scrollY-2)+'px';line.style.height='2px';group.append(line);}
            selection.liftRanges(ranges);const hidden=new Highlight(...ranges);hidden.priority=200;CSS.highlights.set('note-lift',hidden);waves(svg,wavesNear);
            if(!same&&!reduced)current.animation=group.animate([{transform:'translateY(0)'},{transform:'translateY('+dy+'px)'}],{duration:180,easing:'cubic-bezier(.2,.7,.2,1)'});
          };
          window.paperNoteLift={update,clear};
        })();
        """#
}
