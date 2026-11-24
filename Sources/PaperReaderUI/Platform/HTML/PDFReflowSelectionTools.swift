extension PDFSentenceTextCanvas {
    static let selectionToolsScript = #"""
        \#(HTMLAnnotationMenuScript.install)
        \#(HTMLAnnotationMenuScript.appearance)
        let offeredParts=[],projectedInk=[];
        function annotationParts(pieces) {
          if (!pieces.length || pieces.some(p=>!pairs.get(p.id)?.anchorable)) return [];
          const range=getSelection().getRangeAt(0);
          // Figures and unpaired source blocks have no reliable character offsets.
          for (const block of main.querySelectorAll('figure,.source-text')) if (range.intersectsNode(block)) return [];
          return pieces.map(p=>({id:p.id,language:p.language,start:p.range.startOffset,end:p.range.endOffset,text:p.range.toString()}))
                       .filter(p=>p.text.trim());
        }
        let offeredBounds=[];
        function rememberSelection(parts,pieces) {
          offeredParts=parts;
          offeredBounds=pieces.map(p=>p.range.cloneRange());
        }
        function selectionBounds() {
          const visible=offeredBounds.flatMap(range=>[...range.getClientRects()]).filter(rect=>
            rect.width && rect.height && rect.right>0 && rect.left<innerWidth && rect.bottom>0 && rect.top<innerHeight);
          const selection=getSelection(), range=selection.rangeCount && selection.getRangeAt(0);
          return range && range.startContainer===selection.focusNode && range.startOffset===selection.focusOffset
            ? visible.reverse() : visible;
        }
        function act(tool,options={}) {
          if (!offeredParts.length) return;
          post({action:'annotate',tool,pieces:offeredParts,...options});
        }
        const tools=installAnnotationMenu({
          appearance:()=>annotationAppearance(offeredParts.map(p=>({key:p.id,target:p.language,range:[p.start,p.end]})),projectedInk),
          bounds:selectionBounds,hasSelection:()=>offeredParts.length>0,editing:()=>window.paperNotes?.editing(),
          apply:(color,style,remove)=>act('mark',{color,style,remove}),
          addNote:()=>{act('note');tools.hide();},addBookmark:()=>act('bookmark')
        });
        window.paperAnnotationMenu=tools;
        """#

    /// Shared cards use sentence-local projections. Only the native bridge owns persisted PDF offsets.
    static let noteSelectionScript = #"""
        const highlightColors=Object.fromEntries(Object.entries(\#(HTMLAnnotationMenuScript.colors)).map(([name,[,hex]])=>[name,hex]));
        function rangesFor(anchor) {
          const language=anchor.target==='translation'?'zh':anchor.target==='source'?'en':null;
          const span=pairs.get(anchor.key)?.[language],node=span?.firstChild;
          if(!span?.isConnected||node?.nodeType!==Node.TEXT_NODE||anchor.start<0||anchor.end<=anchor.start
              ||anchor.end>node.length||node.substringData(anchor.start,anchor.end-anchor.start)!==anchor.text)return [];
          const range=document.createRange();range.setStart(node,anchor.start);range.setEnd(node,anchor.end);
          return [range];
        }
        function overlappingInk(ranges,visit){
          for(const cut of ranges){
            for(const entry of inlineNoteRanges.get(cut.startContainer.parentElement)||[]){
              if(entry.shared)continue;
              const {range}=entry,start=Math.max(cut.startOffset,range.startOffset),end=Math.min(cut.endOffset,range.endOffset);
              if(start<end)visit(entry,start,end);
            }
          }
        }
        function clippedRange(range,start,end){
          const part=range.cloneRange();part.setStart(range.startContainer,start);part.setEnd(range.endContainer,end);
          return part;
        }
        window.paperSelection={
          rangesFor,lineRanges,sectionKey:a=>pairs.get(a.key)?.sectionKey,
          beginNote:()=>act('note'),
          // Clicking a standalone highlight asks Swift for the immutable PDF anchor before opening a draft.
          projectedMarks:()=>[],
          restore(anchors){
            const parts=[],pieces=[];
            for(const anchor of anchors){
              const [range]=rangesFor(anchor);if(!range)continue;
              const language=anchor.target==='translation'?'zh':'en';
              parts.push({id:anchor.key,language,start:anchor.start,end:anchor.end,text:anchor.text});pieces.push({range});
            }
            rememberSelection(parts,pieces);paintSelection(pieces);
          },
          clear(){
            getSelection().removeAllRanges();rememberSelection([],[]);paintSelection([]);tools.hide();
            lastSelection='[[],[]]';post({action:'selection',ids:[],pieces:[]});
          },
          editingChanged(id,open){
            window.webkit.messageHandlers.reader.postMessage({kind:open?'noteEdit':'noteClose',id,paperID:document.body.dataset.paperId});
          },
          liftPaint(ranges){
            const paints=[];
            overlappingInk(ranges,(entry,start,end)=>{
              paints.push({range:clippedRange(entry.range,start,end),color:entry.color,kind:entry.kind});
            });
            for(const cut of ranges)for(const range of offeredBounds)if(range.startContainer===cut.startContainer){
              const start=Math.max(cut.startOffset,range.startOffset),end=Math.min(cut.endOffset,range.endOffset);
              if(start<end)paints.push({range:clippedRange(range,start,end),color:'rgba(160,125,89,.30)',kind:'highlight',selected:true});
            }
            return paints;
          },
          liftRanges(ranges){
            const changed=new Set();overlappingInk([...lifted,...ranges],entry=>changed.add(entry));lifted=ranges;
            for(const entry of changed){
              const group=CSS.highlights?.get(entry.name);if(!group)continue;
              for(const fragment of entry.fragments)group.delete(fragment);
              entry.fragments=excludingRanges([entry.range],lifted);
              for(const fragment of entry.fragments)group.add(fragment);
            }
            refreshSelectionInk();
          }
        };
        """#
}
