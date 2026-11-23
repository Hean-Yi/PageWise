import Foundation

enum HTMLNoteLayoutScript {
    static let source = #"""
        (()=>{
          const root=document.getElementById('reader'),selection=window.paperSelection;
          const ns='http://www.w3.org/2000/svg';
          const svg=document.createElementNS(ns,'svg');svg.id='reader-note-decoration';svg.setAttribute('width','100%');svg.setAttribute('height','100%');svg.setAttribute('aria-hidden','true');document.body.append(svg);
          let hitCache=new WeakMap();
          const hitRects=anchors=>{
            if(!hitCache.has(anchors)){
              const lines=anchors.flatMap(a=>selection.rangesFor(a).flatMap(r=>a.target.startsWith('object:')?[r.getBoundingClientRect()]:[...r.getClientRects()]));
              hitCache.set(anchors,lines.filter(r=>r.width>0&&r.height>0).map(r=>({left:r.left,right:r.right,width:r.width,height:r.height,top:r.top+scrollY,bottom:r.bottom+scrollY})));
            }
            return hitCache.get(anchors);
          };
          const rects=anchors=>hitRects(anchors).map(r=>({...r,top:r.top-scrollY,bottom:r.bottom-scrollY}));
          const visible=r=>r.bottom>0&&r.top<innerHeight;
          const intersects=(a,b)=>a.left<b.right+12&&a.right+12>b.left&&a.top<b.bottom+12&&a.bottom+12>b.top;
          const place=(anchors,requestedHeight,sidebar,occupied,offscreen=false)=>{
            const all=rects(anchors),rs=offscreen?all:all.filter(visible);if(!rs.length)return null;
            const anchor=rs[0],content=root.querySelector('section')?.getBoundingClientRect()||root.getBoundingClientRect();
            const cap=Math.max(80,Math.min(420,innerHeight-32));
            const heightFor=width=>Math.min(typeof requestedHeight==='function'?requestedHeight(width):requestedHeight,cap);
            if(!sidebar){
              for(const side of ['right','left']){
                const available=side==='right' ? innerWidth-content.right-28 : content.left-28;if(available<220)continue;
                const width=Math.min(320,available),left=side==='right'?content.right+12:content.left-width-12;
                const minTop=offscreen?16-scrollY:16,maxBottom=offscreen?document.documentElement.scrollHeight-scrollY-16:innerHeight-16;
                const height=heightFor(width),origin=anchor.top;
                const candidates=[Math.max(minTop,Math.min(origin,maxBottom-height)),minTop,...occupied.flatMap(o=>[o.bottom+12,o.top-height-12])];
                const options=candidates.map(top=>({left,top,width,height,right:left+width,bottom:top+height,side,anchor})).filter(r=>r.top>=minTop&&r.bottom<=maxBottom&&!occupied.some(o=>intersects(r,o))).sort((a,b)=>Math.abs(a.top-origin)-Math.abs(b.top-origin));
                if(options.length)return options[0];
              }
            }
            if(offscreen)return null;
            const width=Math.min(440,innerWidth-32),last=rs[rs.length-1];let height=heightFor(width);
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
          const stationary=document.createElementNS(ns,'g'),links=document.createElementNS(ns,'g');svg.append(stationary,links);
          const path=(d,kind,parent)=>{const p=document.createElementNS(ns,'path');p.setAttribute('d',d);p.setAttribute('class',kind);parent.append(p);return p;};
          let connection=null;
          const updateConnection=()=>{
            if(!connection)return;
            const {a,b,from,reverse,line,mask,reveal,startDot,endDot}=connection;
            const visibility=visible({top:a.top-scrollY,bottom:a.bottom-scrollY})?'visible':'hidden';line.style.visibility=visibility;startDot.style.visibility=visibility;endDot.style.visibility=visibility;
            const cardTop=b.top+(b.fixed?scrollY:0),floating=b.side==='floating';
            const to=floating?{x:Math.max(b.left+16,Math.min(b.left+b.width-16,from.x)),y:connection.below?cardTop:cardTop+b.height}:{x:b.side==='right'?b.left:b.left+b.width,y:cardTop+b.height/2-b.liftOffset},mid=(from.x+to.x)/2;
            connection.end={x:to.x,y:to.y-scrollY};
            const forward='M '+from.x+' '+from.y+' C '+mid+' '+from.y+', '+mid+' '+to.y+', '+to.x+' '+to.y;
            const backward='M '+to.x+' '+to.y+' C '+mid+' '+to.y+', '+mid+' '+from.y+', '+from.x+' '+from.y;
            const d=floating?'M '+from.x+' '+from.y+' C '+from.x+' '+((from.y+to.y)/2)+', '+to.x+' '+((from.y+to.y)/2)+', '+to.x+' '+to.y:reverse?backward:forward;line.setAttribute('d',d);reveal.setAttribute('d',d);
            startDot.setAttribute('cx',from.x);startDot.setAttribute('cy',from.y);endDot.setAttribute('cx',to.x);endDot.setAttribute('cy',to.y);
            mask.setAttribute('x',Math.min(from.x,to.x)-5);mask.setAttribute('y',Math.min(from.y,to.y)-5);mask.setAttribute('width',Math.abs(to.x-from.x)+10);mask.setAttribute('height',Math.abs(to.y-from.y)+10);
          };
          let waveLines=[];
          const rebuildWaves=notes=>{
            stationary.replaceChildren();waveLines=[];
            const seen=new Set();
            for(const note of notes){if(!note.markdown.trim())continue;for(const r of hitRects(note.anchors)){
              const key=[r.left,r.top,r.width].join(':');if(seen.has(key))continue;seen.add(key);
              let seed=2166136261;for(const c of note.id+':'+key.split(':').slice(2).join(':'))seed=Math.imul(seed^c.charCodeAt(0),16777619);
              const random=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return (seed>>>0)/4294967296;};
              const pts=[{x:r.left,y:r.bottom+4}];let x=r.left,sign=1;
              while(x<r.right){x=Math.min(r.right,x+4+random()*3);const taper=Math.min(1,(r.right-x)/8,(x-r.left)/8);pts.push({x,y:r.bottom+4+sign*(.8+random()*1.4)*taper+(random()-.5)*.5});sign*=-1;}
              let d='M '+pts[0].x+' '+pts[0].y;
              for(let i=0;i<pts.length-1;i++){const a=pts[Math.max(0,i-1)],b=pts[i],c=pts[i+1],e=pts[Math.min(pts.length-1,i+2)];d+=' C '+(b.x+(c.x-a.x)/6)+' '+(b.y+(c.y-a.y)/6)+', '+(c.x-(e.x-b.x)/6)+' '+(c.y-(e.y-b.y)/6)+', '+c.x+' '+c.y;}
              const wave=path(d,'note-wave',stationary);waveLines.push({r,wave});
            }}
            waveLines.sort((a,b)=>a.r.bottom-b.r.bottom);
          };
          const wavesNear=rects=>{
            const found=new Set();
            for(const r of rects){
              let low=0,high=waveLines.length;
              while(low<high){const mid=(low+high)>>>1;if(waveLines[mid].r.bottom+6<r.top)low=mid+1;else high=mid;}
              for(let i=low;i<waveLines.length;i++){
                const {r:b,wave}=waveLines[i];if(b.bottom+2>r.top+r.height+10)break;
                if(b.right>r.left&&b.left<r.left+r.width)found.add(wave);
              }
            }
            return found;
          };
          const decorate=(active,card,reverse,entrance=false)=>{
            connection=null;links.replaceChildren();
            window.paperNoteLift.update(active,svg,wavesNear);
            if(!active)return;
            const rs=rects(active.anchors).filter(visible);if(!rs.length||!card||(card.side==='floating'&&!entrance))return;
            const rect=rs[0],a={left:rect.left,right:rect.right,top:rect.top+scrollY,bottom:rect.bottom+scrollY},b={...card,top:card.top+(card.fixed?0:scrollY),liftOffset:card.fixed&&!matchMedia('(prefers-reduced-motion:reduce)').matches?2:0};
            // Geometry is cached on activation. Native scrolling moves cards and glyph overlays together.
            const below=card.top>=rect.bottom;
            const from=b.side==='floating'?{x:Math.max(a.left,Math.min(a.right,card.left+card.width/2)),y:below?a.bottom+4:a.top-4}:{x:b.side==='right'?a.right+2:a.left-2,y:(a.top+a.bottom)/2};
            const mask=document.createElementNS(ns,'mask');mask.id='note-link-mask';mask.setAttribute('maskUnits','userSpaceOnUse');
            const reveal=document.createElementNS(ns,'path');reveal.setAttribute('class','note-link-reveal');if(entrance)reveal.style.animationDuration='120ms';reveal.setAttribute('pathLength','1');mask.append(reveal);links.append(mask);
            const line=path('','note-link',links);line.setAttribute('mask','url(#note-link-mask)');
            const dot=(kind,r)=>{const c=document.createElementNS(ns,'circle');c.setAttribute('class',kind);c.setAttribute('r',r);links.append(c);return c;};
            connection={id:active.id,below,a,b,from,reverse,line,mask,reveal,startDot:dot('note-link-start',2),endDot:dot('note-link-end',3)};updateConnection();
          };
          // The corridor is the convex hull of a text line and the preview. Track document
          // coordinates so scrolling keeps it aligned without measuring the DOM on pointer moves.
          const inBridge=(anchors,box,x,y)=>{
            if(!box)return false;
            y+=scrollY;
            return hitRects(anchors).some(a=>{
              if(a.bottom<scrollY||a.top>scrollY+innerHeight)return false;
              let low=0,high=1;
              // Is there a rectangle interpolated between the endpoints containing this point?
              const clip=(start,end)=>{
                if(start<0&&end<0)return false;
                if(start<0)low=Math.max(low,-start/(end-start));
                if(end<0)high=Math.min(high,start/(start-end));
                return low<=high;
              };
              const pad=6;
              return clip(x-a.left+pad,x-box.left+pad)&&clip(a.right-x+pad,box.right-x+pad)
                &&clip(y-a.top+pad,y-box.top+pad)&&clip(a.bottom-y+pad,box.bottom-y+pad);
            });
          };
          window.paperNoteLayout={invalidate(){hitCache=new WeakMap();},reverse(value){if(connection&&connection.reverse!==value){connection.reverse=value;updateConnection();}},connectionEnd:()=>connection?.end,endEntrance(id){if(connection?.id===id&&connection.b.side==='floating'){links.replaceChildren();connection=null;}},rects,visible,place,rebuildWaves,decorate,inBridge,scrolled:updateConnection,hit(anchors,x,y,precise=false){y+=scrollY;return hitRects(anchors).some(r=>x>=r.left&&x<=r.right&&(y>=r.top&&y<=r.bottom||!precise&&y>=r.bottom+2&&y<=r.bottom+6));}};
        })();
        """#
}
