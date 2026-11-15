import Foundation

enum HTMLNoteLayoutScript {
    static let source = #"""
        (()=>{
          const root=document.getElementById('reader'),selection=window.paperSelection;
          const ns='http://www.w3.org/2000/svg';
          const svg=document.createElementNS(ns,'svg');svg.id='reader-note-decoration';svg.setAttribute('width','100%');svg.setAttribute('height','100%');svg.setAttribute('aria-hidden','true');document.body.append(svg);
          const lift=document.createElement('div');lift.id='reader-note-lift';lift.setAttribute('aria-hidden','true');document.body.append(lift);
          const hitCache=new WeakMap();
          const rects=anchors=>{const result=anchors.flatMap(a=>selection.rangesFor(a).flatMap(r=>a.target.startsWith('object:') ? [r.getBoundingClientRect()] : [...r.getClientRects()])).filter(r=>r.width>0&&r.height>0);hitCache.set(anchors,result.map(r=>({left:r.left,right:r.right,top:r.top+scrollY,bottom:r.bottom+scrollY})));return result;};
          const hitRects=anchors=>{if(!hitCache.has(anchors))rects(anchors);return hitCache.get(anchors).map(r=>({...r,top:r.top-scrollY,bottom:r.bottom-scrollY}));};
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
            const {a,b,from,edge,reverse,line,mask,reveal,startDot,endDot}=connection;
            const visibility=(a.bottom-scrollY>8&&a.top-scrollY<innerHeight-8)?'visible':'hidden';line.style.visibility=visibility;startDot.style.visibility=visibility;endDot.style.visibility=visibility;
            const cardTop=b.top+(b.fixed?scrollY:0),floating=b.side==='floating';
            const to=floating?{x:Math.max(b.left+16,Math.min(b.left+b.width-16,from.x)),y:connection.below?cardTop:cardTop+b.height}:{x:b.side==='right'?b.left:b.left+b.width,y:Math.max(cardTop+16,Math.min(cardTop+b.height-16,from.y))},mid=(edge.x+to.x)/2;
            connection.end={x:to.x,y:to.y-scrollY};
            const forward='M '+from.x+' '+from.y+' L '+edge.x+' '+edge.y+' C '+mid+' '+edge.y+', '+mid+' '+to.y+', '+to.x+' '+to.y;
            const backward='M '+to.x+' '+to.y+' C '+mid+' '+to.y+', '+mid+' '+edge.y+', '+edge.x+' '+edge.y+' L '+from.x+' '+from.y;
            const d=floating?'M '+from.x+' '+from.y+' C '+from.x+' '+((from.y+to.y)/2)+', '+to.x+' '+((from.y+to.y)/2)+', '+to.x+' '+to.y:reverse?backward:forward;line.setAttribute('d',d);reveal.setAttribute('d',d);
            startDot.setAttribute('cx',from.x);startDot.setAttribute('cy',from.y);endDot.setAttribute('cx',to.x);endDot.setAttribute('cy',to.y);
            mask.setAttribute('x',Math.min(from.x,to.x)-5);mask.setAttribute('y',Math.min(from.y,to.y)-5);mask.setAttribute('width',Math.abs(to.x-from.x)+10);mask.setAttribute('height',Math.abs(to.y-from.y)+10);
          };
          const decorate=(notes,active,card,reverse,entrance=false)=>{
            connection=null;svg.replaceChildren();clearTimeout(liftTimer);
            if(!active&&lift.childElementCount&&!matchMedia('(prefers-reduced-motion:reduce)').matches){
              for(const span of lift.children)span.animate([{transform:'translateY(-1.5px)'},{transform:'translateY(0)'}],{duration:160,fill:'forwards',easing:'ease-out'});
              liftTimer=setTimeout(()=>{lift.replaceChildren();CSS.highlights?.delete('note-lift');},170);
            }else{lift.replaceChildren();CSS.highlights?.delete('note-lift');}
            const seen=new Set();
            for(const note of notes){if(!note.markdown.trim())continue;for(const rect of rects(note.anchors)){const r={left:rect.left,right:rect.right,width:rect.width,top:rect.top+scrollY,bottom:rect.bottom+scrollY};
              const key=[r.left,r.top,r.width].join(':');if(seen.has(key))continue;seen.add(key);
              let seed=2166136261;for(const c of note.id+':'+key.split(':').slice(2).join(':'))seed=Math.imul(seed^c.charCodeAt(0),16777619);
              const random=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return (seed>>>0)/4294967296;};
              const pts=[{x:r.left,y:r.bottom+4}];let x=r.left,sign=1;
              while(x<r.right){x=Math.min(r.right,x+4+random()*3);const taper=Math.min(1,(r.right-x)/8,(x-r.left)/8);pts.push({x,y:r.bottom+4+sign*(.8+random()*1.4)*taper+(random()-.5)*.5});sign*=-1;}
              let d='M '+pts[0].x+' '+pts[0].y;
              for(let i=0;i<pts.length-1;i++){const a=pts[Math.max(0,i-1)],b=pts[i],c=pts[i+1],e=pts[Math.min(pts.length-1,i+2)];d+=' C '+(b.x+(c.x-a.x)/6)+' '+(b.y+(c.y-a.y)/6)+', '+(c.x-(e.x-b.x)/6)+' '+(c.y-(e.y-b.y)/6)+', '+c.x+' '+c.y;}
              path(d,'note-wave');
            }}
            if(!active)return;
            const ranges=active.anchors.filter(a=>!a.target.startsWith('object:')).flatMap(a=>selection.rangesFor(a));
            const hidden=[];let remaining=2000;
            // Clone only the active glyph runs into a non-interactive overlay. Published nodes never move.
            for(const range of ranges){
              if(range.startContainer!==range.endContainer||range.startContainer.nodeType!==3||range.toString().length>remaining)continue;remaining-=range.toString().length;
              const node=range.startContainer,css=getComputedStyle(node.parentElement);let offset=range.startOffset,run=null;
              const flush=()=>{if(!run)return;const span=document.createElement('span');span.textContent=run.text;Object.assign(span.style,{left:run.left+'px',top:run.top+'px',fontFamily:css.fontFamily,fontSize:css.fontSize,fontWeight:css.fontWeight,fontStyle:css.fontStyle,fontVariant:css.fontVariant,lineHeight:run.height+'px',color:css.color,letterSpacing:css.letterSpacing,wordSpacing:css.wordSpacing});lift.append(span);run=null;};
              for(const char of range.toString()){
                const r=document.createRange();r.setStart(node,offset);offset+=char.length;r.setEnd(node,offset);const box=[...r.getClientRects()].filter(b=>b.width>.01&&b.height>0).at(-1);
                // A wrap boundary may expose a zero-width rectangle on the preceding line. Never union both lines.
                if(!box)continue;
                // Collapsed indentation/newlines have no painted glyph. Copying them with white-space:pre creates phantom lines.
                if(box.width<=.01||box.height<=0)continue;
                if(!run||Math.abs(run.top-(box.top+scrollY))>2||Math.abs(run.right-box.left)>1){flush();run={left:box.left,right:box.left,top:box.top+scrollY,height:box.height,text:''};}
                run.text+=/\s/.test(char)?' ':char;run.right=box.right;
              }flush();hidden.push(range);
            }
            if(CSS.highlights){const h=new Highlight(...hidden);h.priority=200;CSS.highlights.set('note-lift',h);}
            const rs=rects(active.anchors).filter(visible);if(!rs.length||!card||(card.side==='floating'&&!entrance))return;
            const rect=rs[0],a={left:rect.left,right:rect.right,top:rect.top+scrollY,bottom:rect.bottom+scrollY},b={...card,top:card.top+(card.fixed?0:scrollY)},content=root.querySelector('section')?.getBoundingClientRect()||root.getBoundingClientRect();
            // Geometry is cached on activation. Native scrolling moves cards and glyph overlays together.
            const below=card.top>=rect.bottom;
            const from=b.side==='floating'?{x:Math.max(a.left,Math.min(a.right,card.left+card.width/2)),y:below?a.bottom+4:a.top-4}:{x:b.side==='right'?a.right+2:a.left-2,y:a.bottom+7};
            const edge={x:b.side==='right'?content.right+6:content.left-6,y:from.y};
            const mask=document.createElementNS(ns,'mask');mask.id='note-link-mask';mask.setAttribute('maskUnits','userSpaceOnUse');
            const reveal=document.createElementNS(ns,'path');reveal.setAttribute('class','note-link-reveal');if(entrance)reveal.style.animationDuration='120ms';reveal.setAttribute('pathLength','1');mask.append(reveal);svg.append(mask);
            const line=path('','note-link');line.setAttribute('mask','url(#note-link-mask)');
            const dot=(kind,r)=>{const c=document.createElementNS(ns,'circle');c.setAttribute('class',kind);c.setAttribute('r',r);svg.append(c);return c;};
            connection={id:active.id,below,a,b,from,edge,reverse,line,mask,reveal,startDot:dot('note-link-start',2),endDot:dot('note-link-end',3)};updateConnection();
          };
          const inBridge=(anchors,card,x,y,previous)=>{
            if(!previous||card.hidden)return false;const box=card.getBoundingClientRect(),rs=hitRects(anchors).filter(visible);if(!rs.length)return false;
            const a=rs[0],right=box.left>a.right,start=right?a.right:a.left,end=right?box.left:box.right;
            const t=(x-start)/(end-start);if(t<0||t>1)return false;
            const low=(a.top-8)*(1-t)+(box.top-8)*t,high=(a.bottom+8)*(1-t)+(box.bottom+8)*t;
            const towardCard=Math.abs(x-end)<Math.abs(previous.x-end),towardText=Math.abs(x-start)<Math.abs(previous.x-start);
            return y>=low&&y<=high&&(towardCard||towardText);
          };
          window.paperNoteLayout={connectionEnd:()=>connection?.end,endEntrance(id){if(connection?.id===id&&connection.b.side==='floating'){for(const n of [connection.line,connection.mask,connection.startDot,connection.endDot])n.remove();connection=null;}},rects,visible,place,decorate,inBridge,scrolled:updateConnection,hit(anchors,x,y,precise=false){const margin=precise?0:3,bottom=precise?0:8;return hitRects(anchors).some(r=>x>=r.left-margin&&x<=r.right+margin&&y>=r.top-margin&&y<=r.bottom+bottom);}};
        })();
        """#
}
