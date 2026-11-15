import Foundation

enum HTMLNoteLayoutScript {
    static let source = #"""
        (()=>{
          const root=document.getElementById('reader'),selection=window.paperSelection;
          const ns='http://www.w3.org/2000/svg';
          const svg=document.createElementNS(ns,'svg');svg.id='reader-note-decoration';svg.setAttribute('width','100%');svg.setAttribute('height','100%');svg.setAttribute('aria-hidden','true');document.body.append(svg);
          const lift=document.createElement('div');lift.id='reader-note-lift';lift.setAttribute('aria-hidden','true');document.body.append(lift);
          const rects=anchors=>anchors.flatMap(a=>selection.rangesFor(a).flatMap(r=>a.target.startsWith('object:') ? [r.getBoundingClientRect()] : [...r.getClientRects()])).filter(r=>r.width>0&&r.height>0);
          const visible=r=>r.bottom>8&&r.top<innerHeight-8;
          const intersects=(a,b)=>a.left<b.right+12&&a.right+12>b.left&&a.top<b.bottom+12&&a.bottom+12>b.top;
          const place=(anchors,height,sidebar,occupied,offscreen=false)=>{
            const all=rects(anchors),rs=offscreen?all:all.filter(visible);if(!rs.length)return null;
            const anchor=rs[0],content=root.querySelector('section')?.getBoundingClientRect()||root.getBoundingClientRect();
            const cap=Math.max(80,Math.min(420,innerHeight-32));height=Math.min(height,cap);
            if(!sidebar){
              for(const side of ['right','left']){
                const available=side==='right' ? innerWidth-content.right-28 : content.left-28;if(available<220)continue;
                const width=Math.min(240,available),left=side==='right'?content.right+12:content.left-width-12;
                const minTop=offscreen?16-scrollY:16,maxBottom=offscreen?document.documentElement.scrollHeight-scrollY-16:innerHeight-16;
                const candidates=[Math.max(minTop,Math.min(anchor.top,maxBottom-height)),minTop,...occupied.flatMap(o=>[o.bottom+12,o.top-height-12])];
                const options=candidates.map(top=>({left,top,width,height,right:left+width,bottom:top+height,side,anchor})).filter(r=>r.top>=minTop&&r.bottom<=maxBottom&&!occupied.some(o=>intersects(r,o))).sort((a,b)=>Math.abs(a.top-anchor.top)-Math.abs(b.top-anchor.top));
                if(options.length)return options[0];
              }
            }
            if(offscreen)return null;
            const width=Math.min(350,innerWidth-32),last=rs[rs.length-1];
            // Never cover the chosen text line: use the larger contiguous vertical gap.
            const below=innerHeight-last.bottom-28,above=anchor.top-28;
            let top;
            if(below>=height){top=last.bottom+12;}
            else if(above>=height){top=anchor.top-height-12;}
            else if(below>=above){height=Math.max(0,below);top=last.bottom+12;}
            else{height=Math.max(0,above);top=16;}
            if(height<120){
              // Anchor fills the viewport: keep the first selected line visible and scroll the editor below it.
              height=Math.min(cap,Math.max(120,innerHeight-anchor.bottom-28));top=anchor.bottom+12;
              if(top+height>innerHeight-16){height=Math.max(100,anchor.top-28);top=16;}
            }
            return {left:Math.max(16,Math.min(innerWidth-width-16,(anchor.left+anchor.right-width)/2)),top,width,height,side:'floating',anchor};
          };
          const path=(d,kind)=>{const p=document.createElementNS(ns,'path');p.setAttribute('d',d);p.setAttribute('class',kind);svg.append(p);return p;};
          let connection=null,liftTimer=null;
          const updateConnection=()=>{
            if(!connection)return;
            const {a,b,from,edge,reverse,line,mask,reveal}=connection;
            line.style.visibility=(a.bottom-scrollY>8&&a.top-scrollY<innerHeight-8)?'visible':'hidden';
            const cardTop=b.top+(b.fixed?scrollY:0),to={x:b.side==='right'?b.left:b.left+b.width,y:Math.max(cardTop+16,Math.min(cardTop+b.height-16,from.y))},mid=(edge.x+to.x)/2;
            const forward='M '+from.x+' '+from.y+' L '+edge.x+' '+edge.y+' C '+mid+' '+edge.y+', '+mid+' '+to.y+', '+to.x+' '+to.y;
            const backward='M '+to.x+' '+to.y+' C '+mid+' '+to.y+', '+mid+' '+edge.y+', '+edge.x+' '+edge.y+' L '+from.x+' '+from.y;
            const d=reverse?backward:forward;line.setAttribute('d',d);reveal.setAttribute('d',d);
            mask.setAttribute('x',Math.min(from.x,to.x)-5);mask.setAttribute('y',Math.min(from.y,to.y)-5);mask.setAttribute('width',Math.abs(to.x-from.x)+10);mask.setAttribute('height',Math.abs(to.y-from.y)+10);
          };
          const decorate=(notes,active,card,reverse)=>{
            connection=null;svg.replaceChildren();clearTimeout(liftTimer);
            if(!active&&lift.childElementCount&&!matchMedia('(prefers-reduced-motion:reduce)').matches){
              for(const span of lift.children)span.animate([{transform:'translateY(-1.5px)'},{transform:'translateY(0)'}],{duration:160,fill:'forwards',easing:'ease-out'});
              liftTimer=setTimeout(()=>{lift.replaceChildren();CSS.highlights?.delete('note-lift');},170);
            }else{lift.replaceChildren();CSS.highlights?.delete('note-lift');}
            const seen=new Set();
            for(const note of notes){if(!note.markdown.trim())continue;for(const rect of rects(note.anchors)){const r={left:rect.left,right:rect.right,width:rect.width,top:rect.top+scrollY,bottom:rect.bottom+scrollY};
              const key=[r.left,r.top,r.width].join(':');if(seen.has(key))continue;seen.add(key);
              let d='M '+r.left+' '+(r.bottom+3);for(let x=r.left;x<r.right;x+=8){const end=Math.min(x+8,r.right);d+=' Q '+(x+2)+' '+(r.bottom+1)+' '+(x+4)+' '+(r.bottom+3)+' Q '+(x+6)+' '+(r.bottom+5)+' '+end+' '+(r.bottom+3);}path(d,'note-wave');
            }}
            if(!active)return;
            const ranges=active.anchors.filter(a=>!a.target.startsWith('object:')).flatMap(a=>selection.rangesFor(a));
            const hidden=[];let remaining=2000;
            // Clone only the active glyph runs into a non-interactive overlay. Published nodes never move.
            for(const range of ranges){
              if(range.startContainer!==range.endContainer||range.startContainer.nodeType!==3||range.toString().length>remaining)continue;remaining-=range.toString().length;
              const node=range.startContainer,css=getComputedStyle(node.parentElement);let offset=range.startOffset,run=null;
              const flush=()=>{if(!run)return;const span=document.createElement('span');span.textContent=run.text;span.style.cssText='left:'+run.left+'px;top:'+run.top+'px;font:'+css.font+';line-height:'+run.height+'px;color:'+css.color+';letter-spacing:'+css.letterSpacing;lift.append(span);run=null;};
              for(const char of range.toString()){
                const r=document.createRange();r.setStart(node,offset);offset+=char.length;r.setEnd(node,offset);const box=r.getBoundingClientRect();
                if(!run||Math.abs(run.top-(box.top+scrollY))>2){flush();run={left:box.left,top:box.top+scrollY,height:box.height,text:''};}run.text+=char;
              }flush();hidden.push(range);
            }
            if(CSS.highlights){const h=new Highlight(...hidden);h.priority=200;CSS.highlights.set('note-lift',h);}
            const rs=rects(active.anchors).filter(visible);if(!rs.length||!card||card.side==='floating')return;
            const rect=rs[0],a={left:rect.left,right:rect.right,top:rect.top+scrollY,bottom:rect.bottom+scrollY},b={...card,top:card.top+(card.fixed?0:scrollY)},content=root.querySelector('section')?.getBoundingClientRect()||root.getBoundingClientRect();
            // Geometry is cached on activation. Native scrolling moves cards and glyph overlays together.
            const from={x:b.side==='right'?a.right+2:a.left-2,y:a.bottom+7};
            const edge={x:b.side==='right'?content.right+6:content.left-6,y:from.y};
            const mask=document.createElementNS(ns,'mask');mask.id='note-link-mask';mask.setAttribute('maskUnits','userSpaceOnUse');
            const reveal=document.createElementNS(ns,'path');reveal.setAttribute('class','note-link-reveal');reveal.setAttribute('pathLength','1');mask.append(reveal);svg.append(mask);
            const line=path('','note-link');line.setAttribute('mask','url(#note-link-mask)');
            connection={a,b,from,edge,reverse,line,mask,reveal};updateConnection();
          };
          window.paperNoteLayout={rects,visible,place,decorate,scrolled:updateConnection,hit(anchors,x,y){return rects(anchors).some(r=>x>=r.left-2&&x<=r.right+2&&y>=r.top-3&&y<=r.bottom+6);}};
        })();
        """#
}
