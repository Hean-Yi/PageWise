extension PDFSentenceTextCanvas {
    /// A semantic table remains selectable while the surrounding bilingual paragraphs are updated.
    static let tableScript = #"""
        function setCellRuns(cell,runs) {
          if (!runs?.length) return;
          cell.dataset.plain=cell.textContent;
          cell.replaceChildren();
          for (const run of runs) {
            let text=document.createTextNode(run.text);
            const tags=[];
            if (run.baseline==='superscript') tags.push('sup');
            if (run.baseline==='subscript') tags.push('sub');
            if (run.bold) tags.push('strong');
            if (run.italic) tags.push('em');
            for (const tag of tags) {
              const wrapper=document.createElement(tag);
              wrapper.append(text);text=wrapper;
            }
            cell.append(text);
          }
        }
        function makeTable(data,label) {
          const table=document.createElement('table');
          table.setAttribute('aria-label',label);
          table.lang='en';
          const grouped=data.headerRows?.length;
          const headers=grouped ? data.headerRows : [data.header.map((text,column)=>({text,column}))];
          if (grouped) {
            for (const title of headers[0]) {
              const group=document.createElement('colgroup');group.span=title.columnSpan;table.append(group);
            }
          }
          const head=table.createTHead();
          for (const titles of headers) {
            const row=head.insertRow();
            for (const title of titles) {
              const cell=document.createElement('th');
              cell.colSpan=title.columnSpan || 1;cell.rowSpan=title.rowSpan || 1;
              cell.scope=cell.colSpan>1 ? 'colgroup' : 'col';cell.dataset.column=title.column;
              cell.textContent=title.text;setCellRuns(cell,title.runs);row.append(cell);
            }
          }
          const body=table.createTBody();
          for (const values of data.rows) {
            const row=body.insertRow();
            for (const value of values) row.insertCell().textContent=value;
          }
          for (const style of data.styledCells) {
            if (grouped && style.row===0) continue;
            const row=style.row===0 ? head.rows[0] : body.rows[style.row-1];
            if (row?.cells[style.column]) setCellRuns(row.cells[style.column],style.runs);
          }
          return table;
        }
        // PDFKit can substitute one font for several publication weights. For complex tables,
        // keep the visible original and fit selectable cell text to the verified PDF boxes.
        function makeSourceTable(table,item) {
          const source=document.createElement('div'), image=document.createElement('img');
          source.className='source-table';source.style.minWidth=(item.sourceWidth/10)+'em';
          image.alt='';image.draggable=false;image.width=item.width;image.height=item.height;
          const measure=document.createElement('canvas').getContext('2d');
          measure.font='100px Georgia';
          for (const [r,row] of Array.from(table.rows).entries()) {
            for (const [c,cell] of Array.from(row.cells).entries()) {
              const [left,top,width,height]=item.table.cellBounds[r][c];
              const text=document.createElement('span');
              text.textContent=cell.textContent;cell.replaceChildren(text);
              const heightInWidths=height*item.height/item.width;
              cell.style.left=(left*100)+'%';cell.style.top=(top*100)+'%';
              cell.style.width=(width*100)+'%';cell.style.height=(height*100)+'%';
              cell.style.fontSize=(heightInWidths*100)+'cqw';
              const measured=measure.measureText(text.textContent).width;
              if (measured>0) text.style.transform='scaleX('+(100*width/(heightInWidths*measured))+')';
            }
          }
          image.addEventListener('error',()=>{
            for (const cell of table.querySelectorAll('th,td')) {
              cell.removeAttribute('style');cell.firstChild.style.removeProperty('transform');
              cell.textContent=cell.dataset.plain ?? cell.textContent;
            }
            source.replaceWith(table);
          },{once:true});
          image.src='data:image/png;base64,'+item.png;
          source.append(image,table);return source;
        }
        function showReadingTable(figure,item,title) {
          const table=makeTable(item.table,item.label);
          const tools=document.createElement('figcaption'), scroller=document.createElement('div');
          tools.className='table-tools';scroller.className='table-scroll';
          title.textContent=item.label;title.className='table-title';tools.append(title);
          for (const [step,label,mark] of [[-1,'向左查看列','‹'],[1,'向右查看列','›']]) {
            const arrow=document.createElement('button');
            arrow.type='button';arrow.className='table-step';arrow.dataset.step=step;arrow.hidden=true;
            arrow.title=label;arrow.setAttribute('aria-label',label);arrow.textContent=mark;
            arrow.addEventListener('click',()=>scroller.scrollBy({left:step*scroller.clientWidth*.75,
              behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'}));
            tools.append(arrow);
          }
          const copy=document.createElement('button');
          copy.type='button';copy.textContent='复制表格';copy.dataset.copyTable=item.id;
          copy.setAttribute('aria-live','polite');
          copy.title='复制整张表，保留行列';
          copy.addEventListener('click',()=>send('copyTable',item.id));tools.append(copy);
          scroller.append(item.table.cellBounds && item.png ? makeSourceTable(table,item) : table);
          figure.append(tools,scroller);
          scroller.addEventListener('scroll',()=>updateTableWidth(scroller),{passive:true});
        }
        function tableCopied(id,copied) {
          const button=main.querySelector('[data-copy-table="'+CSS.escape(id)+'"]');
          if (!button) return;
          button.textContent=copied ? '已复制' : '复制失败';
          clearTimeout(button.resetLabel);
          button.resetLabel=setTimeout(()=>{button.textContent='复制表格';},1800);
        }
        function updateTableWidth(scroller) {
          const limit=scroller.scrollWidth-scroller.clientWidth, wide=limit>2;
          const steps=scroller.previousElementSibling.querySelectorAll('.table-step');
          for (const arrow of steps) {
            arrow.hidden=!wide;
            arrow.setAttribute('aria-hidden',String(!wide));
            arrow.disabled=Number(arrow.dataset.step)<0 ? scroller.scrollLeft<1 : scroller.scrollLeft>=limit-1;
          }
          if (wide) {
            scroller.tabIndex=0;scroller.setAttribute('role','region');
            scroller.setAttribute('aria-label',scroller.querySelector('table').getAttribute('aria-label')+'，横向滚动');
          } else {
            scroller.removeAttribute('tabindex');scroller.removeAttribute('role');scroller.removeAttribute('aria-label');
          }
        }
        function updateTableWidths() {
          for (const scroller of main.querySelectorAll('.table-scroll')) updateTableWidth(scroller);
        }
        new ResizeObserver(updateTableWidths).observe(main);
        function copyTableCells(range) {
          const common=range.commonAncestorContainer;
          const element=common.nodeType===Node.TEXT_NODE ? common.parentElement : common;
          const table=element.closest?.('.reading-table table');
          if (!table) return null;
          const lines=[];
          let first=Infinity,last=-1;
          for (const row of table.rows) {
            const fields=[];
            for (const cell of row.cells) {
              if (!range.intersectsNode(cell)) continue;
              const part=selectedText(range,cell);
              if (!part && cell.textContent) continue;
              const column=Number(cell.dataset.column ?? cell.cellIndex);
              const complete=part===cell.textContent;
              first=Math.min(first,column);last=Math.max(last,column+(complete ? cell.colSpan-1 : 0));
              fields[column]=complete ? (cell.dataset.plain ?? part) : part;
            }
            if (fields.length) lines.push(fields);
          }
          return lines.length ? lines.map(fields=>
            Array.from({length:last-first+1},(_,i)=>{
              const value=fields[first+i] ?? '';
              return /["\t\r\n]/.test(value) ? '"'+value.replaceAll('"','""')+'"' : value;
            }).join('\t')).join('\n') : null;
        }
        """#
}
