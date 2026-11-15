import Foundation

/// Ephemeral image presentation; original nodes and persisted reading geometry remain intact.
enum HTMLImagePreviewScript {
    static let source = #"""
        (()=>{
          const style=document.createElement('style');style.textContent=`
            #reader-image-preview{position:fixed;z-index:10000;inset:0;margin:0;padding:0;border:0;width:100vw;height:100dvh;max-width:none;max-height:none;background:transparent;overflow:hidden;color:#faf8f3;overscroll-behavior:contain;contain:layout style}
            #reader-image-preview .preview-backdrop{position:absolute;inset:0;background:rgba(23,21,19,.64);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);opacity:0;will-change:opacity;transform:translateZ(0)}
            #reader-image-preview .preview-image{position:absolute;margin:0;padding:0;border:0;max-width:none;max-height:none;object-fit:contain;background:white;transform-origin:0 0;will-change:transform;box-shadow:0 12px 48px #0004;cursor:zoom-out;user-select:none;-webkit-user-select:none}
            #reader-image-preview .preview-tools{position:absolute;z-index:1;top:max(16px,env(safe-area-inset-top));right:max(20px,env(safe-area-inset-right));display:flex;gap:10px;opacity:0}
            #reader-image-preview button{float:none;border:1px solid #ffffff35;border-radius:10px;background:#faf8f3;color:#544338;padding:9px 15px;font:500 14px/1.3 system-ui;cursor:pointer}
            #reader-image-preview button:hover{background:#e9dfd0}#reader-image-preview button:focus-visible{outline:3px solid #e6b68e;outline-offset:3px}
          `;document.head.append(style);
          let active=null,gesture=null;
          const reduced=()=>matchMedia('(prefers-reduced-motion:reduce)').matches;
          const stop=s=>{for(const animation of s.animations)animation.cancel();s.animations=[];};
          const animate=(s,node,frames,duration)=>{
            const animation=node.animate(frames,{duration,easing:'cubic-bezier(.22,.75,.25,1)',fill:'both'});s.animations.push(animation);
            // WebKit may defer finished while its rendering clock is paused. Never gate dismissal on it alone.
            return new Promise(resolve=>{const timer=setTimeout(resolve,duration+60);animation.finished.then(()=>{clearTimeout(timer);resolve();},()=>{clearTimeout(timer);resolve();});});
          };
          const fit=s=>{
            const ratio=s.source.naturalWidth/s.source.naturalHeight,width=Math.min(innerWidth-40,(innerHeight-112)*ratio);
            const height=width/ratio,box={left:(innerWidth-width)/2,top:72+(innerHeight-88-height)/2,width,height};
            Object.assign(s.large.style,{left:box.left+'px',top:box.top+'px',width:width+'px',height:height+'px'});s.box=box;
            const density=Math.min(devicePixelRatio||1,4096/Math.max(width,height));
            s.large.width=Math.max(1,Math.ceil(width*density));s.large.height=Math.max(1,Math.ceil(height*density));
            const context=s.large.getContext('2d');context.fillStyle='#fff';context.fillRect(0,0,s.large.width,s.large.height);context.drawImage(s.source,0,0,s.large.width,s.large.height);
          };
          const fromRect=(r,b)=>'translate('+(r.left-b.left)+'px,'+(r.top-b.top)+'px) scale('+(r.width/b.width)+','+(r.height/b.height)+')';
          const dispose=s=>{
            if(active!==s)return;active=null;stop(s);s.events.abort();
            s.source.style.visibility=s.visibility;s.dialog.remove();
            if(s.focus?.isConnected)s.focus.focus({preventScroll:true});
          };
          const close=async(quote=false)=>{
            const s=active;if(!s||s.closing)return;s.closing=true;
            const current=getComputedStyle(s.large).transform,opacity=getComputedStyle(s.shade).opacity;
            stop(s);
            const r=s.source.getBoundingClientRect(),canReturn=s.source.isConnected&&r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight;
            if(!reduced()&&s.dialog.isConnected){
              await Promise.all([
                animate(s,s.large,[{transform:current,opacity:1},{transform:canReturn?fromRect(r,s.box):current,opacity:canReturn?1:0}],170),
                animate(s,s.shade,[{opacity},{opacity:0}],170),
                animate(s,s.tools,[{opacity:getComputedStyle(s.tools).opacity},{opacity:0}],110)
              ]);
            }
            if(active!==s)return;dispose(s);
            if(quote&&s.source.isConnected)window.paperSelection?.selectObject(s.source);
          };
          const open=async source=>{
            if(!source.complete||!source.naturalWidth||!source.naturalHeight)return;
            if(active?.source===source)return;
            if(active)dispose(active);
            const started=performance.now();
            const dialog=document.createElement('div');dialog.id='reader-image-preview';dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label','图片预览');dialog.tabIndex=-1;
            const shade=document.createElement('div');shade.className='preview-backdrop';
            const large=document.createElement('canvas');large.className='preview-image';large.setAttribute('role','img');large.setAttribute('aria-label',source.alt||'论文图片');large.imageSource=source;
            const tools=document.createElement('div');tools.className='preview-tools';
            const quote=document.createElement('button');quote.textContent='引用图片';quote.type='button';
            const dismiss=document.createElement('button');dismiss.textContent='关闭';dismiss.type='button';dismiss.setAttribute('aria-label','关闭放大图片');
            tools.append(quote,dismiss);dialog.append(shade,large,tools);
            const s={source,dialog,shade,large,tools,visibility:source.style.visibility,focus:document.activeElement,events:new AbortController(),animations:[],closing:false};active=s;
            // The source is already decoded. Present synchronously using its cached resource.
            const origin=source.getBoundingClientRect();if(origin.width<=0||origin.height<=0){dispose(s);return;}
            fit(s);dialog.dataset.state='open';source.style.visibility='hidden';document.body.append(dialog);
            const options={signal:s.events.signal};
            dismiss.addEventListener('click',()=>close(),options);quote.addEventListener('click',()=>close(true),options);
            dialog.addEventListener('click',event=>{if(event.target===shade||event.target===large||event.target===dialog)close();},options);
            dialog.addEventListener('pointermove',event=>event.stopPropagation(),options);
            dialog.addEventListener('wheel',event=>event.preventDefault(),{...options,passive:false});
            dialog.addEventListener('touchmove',event=>event.preventDefault(),{...options,passive:false});
            window.addEventListener('resize',()=>{if(s.closing){dispose(s);return;}stop(s);fit(s);s.large.style.transform='none';s.shade.style.opacity='1';s.tools.style.opacity='1';},options);
            let prepared=0;const setup=performance.now()-started;requestAnimationFrame(()=>{window.webkit?.messageHandlers?.reader?.postMessage({kind:'imagePreviewTiming',setup,prepared,frame:performance.now()-started});if(active===s&&!s.closing)dismiss.focus({preventScroll:true});});
            if(reduced()){s.shade.style.opacity='1';s.tools.style.opacity='1';return;}
            const opening=Promise.all([
              animate(s,large,[{transform:fromRect(origin,s.box)},{transform:'none'}],230),
              animate(s,shade,[{opacity:0},{opacity:1}],230),
              animate(s,tools,[{opacity:0},{opacity:1}],170)
            ]);prepared=performance.now()-started;await opening;
            if(active===s&&!s.closing){s.large.style.transform='none';s.shade.style.opacity='1';s.tools.style.opacity='1';stop(s);}
          };
          document.addEventListener('pointerdown',event=>{gesture={x:event.clientX,y:event.clientY,moved:false};},true);
          document.addEventListener('pointermove',event=>{if(gesture&&event.buttons&&Math.hypot(event.clientX-gesture.x,event.clientY-gesture.y)>4)gesture.moved=true;},true);
          document.addEventListener('click',event=>{
            const image=event.target.closest?.('#reader img');if(!image||event.button!==0)return;
            if(event.detail&&gesture&&(gesture.moved||Math.hypot(event.clientX-gesture.x,event.clientY-gesture.y)>4))return;
            event.preventDefault();event.stopImmediatePropagation();open(image);
          },true);
          document.addEventListener('keydown',event=>{
            if(!active)return;
            if(event.key==='Escape'){event.preventDefault();event.stopImmediatePropagation();close();}
            else if(event.key==='Tab'){event.preventDefault();const buttons=[...active.tools.querySelectorAll('button')],index=buttons.indexOf(document.activeElement);buttons[(index+(event.shiftKey?-1:1)+buttons.length)%buttons.length].focus({preventScroll:true});}
            else if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End'].includes(event.key)||(event.key===' '&&!active.tools.contains(document.activeElement)))event.preventDefault();
          },true);
          window.paperImagePreview={open,close};
        })();
        """#
}
