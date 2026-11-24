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
          bounds:selectionBounds,hasSelection:()=>offeredParts.length>0,
          apply:(color,style,remove)=>act('mark',{color,style,remove}),
          addNote:()=>{act('note');tools.hide();},addBookmark:()=>act('bookmark')
        });
        """#
}
