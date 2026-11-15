import Foundation

/// Transfers only the active text paint into one moving layer; document geometry stays immutable.
enum HTMLNoteLiftScript {
    static let source = #"""
        (()=>{
          const selection=window.paperSelection,ns='http://www.w3.org/2000/svg';
          const host=document.createElement('div');host.id='reader-note-lift';host.setAttribute('aria-hidden','true');document.body.append(host);
          let current=null,timer=null;
          const clear=()=>{clearTimeout(timer);timer=null;current?.animation?.cancel();current=null;host.replaceChildren();CSS.highlights?.delete('note-lift');selection.liftRanges([]);document.querySelectorAll('.note-wave').forEach(p=>p.removeAttribute('mask'));document.getElementById('note-wave-cutouts')?.remove();};
          const boxes=range=>[...range.getClientRects()].filter(r=>r.width>.01&&r.height>0);
          const paintBox=(rect,kind,color)=>{
            const e=document.createElement('i');e.className=kind;
            Object.assign(e.style,{left:rect.left+'px',top:(rect.top+scrollY)+'px',width:rect.width+'px',height:rect.height+'px',background:color});return e;
          };
          const waves=svg=>{
            if(!current)return;
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
            for(const p of svg.querySelectorAll('.note-wave')){const copy=p.cloneNode(true);copy.removeAttribute('mask');clipped.append(copy);p.setAttribute('mask','url(#note-wave-stationary)');}
            current.group.append(moving);
          };
          const update=(active,svg)=>{
            const reduced=matchMedia('(prefers-reduced-motion:reduce)').matches;
            if(!active){
              if(!current)return;
              if(reduced){clear();return;}
              waves(svg);
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
              const node=range.startContainer,css=getComputedStyle(node.parentElement),inks=paints.filter(p=>!p.selected&&p.kind==='highlight'&&p.range.startContainer===node);let offset=range.startOffset,run=null;
              const flush=()=>{if(!run)return;const span=document.createElement('span');span.className='note-lift-text';span.textContent=run.text;Object.assign(span.style,{left:run.left+'px',top:run.top+'px',fontFamily:css.fontFamily,fontSize:css.fontSize,fontWeight:css.fontWeight,fontStyle:css.fontStyle,fontVariant:css.fontVariant,lineHeight:run.height+'px',color:run.color,letterSpacing:css.letterSpacing,wordSpacing:css.wordSpacing});group.append(span);run=null;};
              for(const char of range.toString()){
                const start=offset,r=document.createRange();r.setStart(node,start);offset+=char.length;r.setEnd(node,offset);const box=boxes(r).at(-1);if(!box)continue;
                const color=inks.some(p=>start<p.range.endOffset&&offset>p.range.startOffset)?'#292e2e':css.color;
                if(!run||Math.abs(run.top-(box.top+scrollY))>2||Math.abs(run.right-box.left)>1||run.color!==color){flush();run={left:box.left,right:box.left,top:box.top+scrollY,height:box.height,text:'',color};}
                run.text+=/\s/.test(char)?' ':char;run.right=box.right;
              }flush();
            }
            for(const p of paints)if(p.kind==='underline')for(const r of boxes(p.range)){const line=paintBox(r,'note-lift-underline',p.color);line.style.top=(r.bottom+scrollY-2)+'px';line.style.height='2px';group.append(line);}
            selection.liftRanges(ranges);const hidden=new Highlight(...ranges);hidden.priority=200;CSS.highlights.set('note-lift',hidden);waves(svg);
            if(!same&&!reduced)current.animation=group.animate([{transform:'translateY(0)'},{transform:'translateY('+dy+'px)'}],{duration:180,easing:'cubic-bezier(.2,.7,.2,1)'});
          };
          window.paperNoteLift={update,clear};
        })();
        """#
}
