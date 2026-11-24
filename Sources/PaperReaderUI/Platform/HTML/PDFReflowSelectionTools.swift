extension PDFSentenceTextCanvas {
    static let selectionToolsScript = #"""
        const tools=document.getElementById('selection-tools');
        const noteTool=tools.querySelector('[data-tool="note"]'), highlightTool=tools.querySelector('[data-tool="highlight"]');
        let trackingSelection=false, dismissedSelection='', placementTimer=0;
        let offeredParts=[];
        function annotationParts(pieces) {
          if (!pieces.length || pieces.some(p=>!pairs.get(p.id)?.anchorable)) return [];
          const selection=getSelection(), range=selection.getRangeAt(0);
          // Figures, tables and unpaired source blocks have no sentence offsets. Sending only
          // the adjacent prose would create a note with a different excerpt than the selection.
          for (const block of main.querySelectorAll('figure,.source-text')) if (range.intersectsNode(block)) return [];
          return pieces.map(p=>({id:p.id,language:p.language,start:p.range.startOffset,end:p.range.endOffset,text:p.range.toString()}))
                       .filter(p=>p.text.trim());
        }
        function placeTools() {
          placementTimer=0;
          if (trackingSelection || dismissedSelection===lastSelection) {tools.hidden=true;return;}
          const pieces=selectedPieces(), parts=annotationParts(pieces);
          if (getSelection().isCollapsed && tools.contains(document.activeElement) && offeredParts.length) return;
          if (!parts.length) {tools.hidden=true;return;}
          const visible=[];
          for (const {range} of pieces) {
            for (const rect of range.getClientRects()) {
              if (rect.width && rect.height && rect.right>0 && rect.left<innerWidth &&
                  rect.top<innerHeight && rect.bottom>0) visible.push(rect);
            }
          }
          if (!visible.length) {tools.hidden=true;return;}
          const translated=parts[0].language==='zh';
          noteTool.textContent=translated ? '给对应原句记笔记' : '记笔记';
          highlightTool.textContent=translated ? '高亮对应原句' : '高亮';
          offeredParts=parts;
          tools.hidden=false;
          const selection=getSelection(), range=selection.getRangeAt(0);
          const backward=range.startContainer===selection.focusNode && range.startOffset===selection.focusOffset;
          const edge=backward ? visible[0] : visible[visible.length-1];
          const width=tools.offsetWidth, height=tools.offsetHeight;
          tools.style.left=Math.max(8,Math.min(innerWidth-width-8,edge.left+(edge.width-width)/2))+'px';
          const below=edge.bottom+7;
          const top=matchMedia('(pointer:coarse)').matches && below+height<=innerHeight-6
            ? below : edge.top>=height+14 ? edge.top-height-7 : below;
          tools.style.top=Math.max(6,Math.min(innerHeight-height-6,top))+'px';
        }
        function scheduleTools() {
          if (!placementTimer) placementTimer=setTimeout(placeTools,0);
        }
        function selectionToolsChanged() {
          dismissedSelection='';
          if (!trackingSelection) scheduleTools();
        }
        document.addEventListener('pointerdown',e=>{
          if (tools.contains(e.target)) {e.preventDefault();return;}
          trackingSelection=true;tools.hidden=true;dismissedSelection='';offeredParts=[];
        });
        tools.addEventListener('mousedown',e=>e.preventDefault());
        function endSelectionTracking() {
          trackingSelection=false;scheduleTools();
        }
        document.addEventListener('pointerup',endSelectionTracking,true);
        document.addEventListener('pointercancel',endSelectionTracking,true);
        window.addEventListener('blur',()=>{
          trackingSelection=false;dismissedSelection=lastSelection;clearTimeout(placementTimer);
          placementTimer=0;tools.hidden=true;offeredParts=[];
        });
        window.addEventListener('resize',scheduleTools);
        document.addEventListener('scroll',()=>{
          if (!getSelection().isCollapsed && lastSelection!==dismissedSelection) scheduleTools();
        },{capture:true,passive:true});
        document.addEventListener('keydown',e=>{
          if (tools.hidden) return;
          if (e.key==='Tab' && !e.shiftKey && !tools.contains(document.activeElement)) {
            noteTool.focus({preventScroll:true});e.preventDefault();
          } else if (e.key==='Escape') {
            dismissedSelection=lastSelection;tools.hidden=true;e.preventDefault();
          }
        });
        tools.addEventListener('focusout',e=>{if (!tools.contains(e.relatedTarget)) scheduleTools();});
        tools.addEventListener('click',e=>{
          const tool=e.target.closest('[data-tool]')?.dataset.tool;
          if (!tool || tools.hidden || !offeredParts.length) return;
          post({action:'annotate',tool,pieces:offeredParts});
          dismissedSelection=lastSelection;tools.hidden=true;
          offeredParts=[];
        });
        """#
}
