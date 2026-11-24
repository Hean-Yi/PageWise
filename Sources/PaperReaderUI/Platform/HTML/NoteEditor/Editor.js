import {attachSummary} from './SummaryEditor.js';
import {EditorState, StateField, StateEffect, Transaction} from '@codemirror/state';
import {EditorView, Decoration, WidgetType, keymap, placeholder} from '@codemirror/view';
import {history, historyKeymap, defaultKeymap, undo, redo} from '@codemirror/commands';
import {markdown, markdownKeymap} from '@codemirror/lang-markdown';
import {syntaxTree} from '@codemirror/language';
import {GFM} from '@lezer/markdown';

// Markdown remains the sole source. Decorations never serialize rendered HTML back to text.
const compiled = StateEffect.define();
class Rendered extends WidgetType {
  constructor(html, from, to, block=false) {super();Object.assign(this,{html,from,to,block});}
  eq(other) {return this.html===other.html && this.from===other.from && this.to===other.to;}
  toDOM(view) {
    const node=document.createElement(this.block?'div':'span');node.className='note-md-widget';node.innerHTML=this.html;
    node.title='点击编辑 Markdown';node.setAttribute('contenteditable','false');
    node.onmousedown=event=>{if(event.target.closest('a[data-passage]'))return;event.preventDefault();view.dispatch({selection:{anchor:Math.min(this.to,this.from+1)}});view.focus();};
    return node;
  }
  ignoreEvent() {return true;}
}
// An ordinary mark is still editable text. WebKit can place the caret inside its label
// during mousedown, which removes the mark before the subsequent click or AX press.
class PassageLink extends WidgetType {
  constructor(href, id, label, from) {
    super();
    Object.assign(this, {href, id, label, from});
  }
  eq(other) {
    return this.href === other.href && this.id === other.id &&
      this.label === other.label && this.from === other.from;
  }
  toDOM(view) {
    const a = document.createElement('a');
    a.href = this.href;
    a.dataset.passage = this.id;
    a.textContent = this.label;
    a.contentEditable = 'false';
    a.tabIndex = 0;
    a.title = '预览引用';
    a.setAttribute('aria-keyshortcuts', 'Enter F2');
    a.editPassageSource = () => {
      view.dispatch({selection: {anchor: this.from + 1}});
      view.focus();
    };
    return a;
  }
  ignoreEvent() { return true; }
}

// Read-mode cards, rendered tables and both Markdown editor hosts use the same activation path.
// Scroll and drag on touch remain native. A completed tap, keyboard activation or AX press opens once.
function bindPassages(host, open) {
  const linkFor = event => event.target.closest?.('a[data-passage]');
  function keepCaret(event) {
    if (!linkFor(event) || event.button !== 0) return;
    event.stopPropagation();
    if (event.pointerType !== 'touch') event.preventDefault();
  }
  host.addEventListener('pointerdown', keepCaret, true);
  host.addEventListener('mousedown', keepCaret, true);
  host.addEventListener('click', event => {
    const a = linkFor(event);
    if (!a || event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    if (event.altKey && a.editPassageSource) a.editPassageSource();
    else open(a.dataset.passage);
  }, true);
  host.addEventListener('keydown', event => {
    const a = linkFor(event);
    if (!a) return;
    const edit = event.key === 'F2' && a.editPassageSource;
    if (!edit && event.key !== 'Enter' && event.key !== ' ') return;
    event.preventDefault();
    event.stopPropagation();
    if (event.repeat) return;
    if (edit) a.editPassageSource();
    else open(a.dataset.passage);
  }, true);
}

class TaskCheckbox extends WidgetType {
  constructor(from,checked){super();this.from=from;this.checked=checked;}
  eq(other){return this.from===other.from&&this.checked===other.checked;}
  toDOM(view){const input=document.createElement('input');input.type='checkbox';input.checked=this.checked;input.setAttribute('aria-label','任务完成状态');input.onmousedown=e=>e.preventDefault();input.onclick=()=>{view.dispatch({changes:{from:this.from+1,to:this.from+2,insert:this.checked?' ':'x'}});view.focus();};return input;}
  ignoreEvent(){return true;}
}
function decorations(state, preview) {
  const ranges=[], occupied=[], text=state.doc.toString(), sel=state.selection.main;
  const selected=(from,to)=>!sel.empty && sel.from<to && sel.to>from;
  const editing=(from,to)=>sel.empty && sel.head>from && sel.head<to || selected(from,to);
  const hide=(from,to)=>{if(from<to&&!selected(from,to))ranges.push(Decoration.replace({noteAtomic:true}).range(from,to));};
  const mark=(from,to,cls)=>{if(from<to)ranges.push(Decoration.mark({class:cls}).range(from,to));};
  let tableIndex=0;
  syntaxTree(state).iterate({enter(node){
    const name=node.name, from=node.from,to=node.to;
    if(name==='FencedCode'||name==='CodeBlock'){
      occupied.push([from,to]);for(let n=state.doc.lineAt(from).number;n<=state.doc.lineAt(to).number;n++)ranges.push(Decoration.line({class:'note-md-code-line'}).range(state.doc.line(n).from));return false;
    }
    if(name==='Table'){
      const html=preview.tables[tableIndex++];occupied.push([from,to]);
      if(html&&!editing(from,to)){ranges.push(Decoration.replace({noteAtomic:true,widget:new Rendered(html,from,to,true),block:true}).range(from,to));return false;}
    }
    if(name==='InlineCode'){occupied.push([from,to]);mark(from,to,'note-md-code');}
    if(/^ATXHeading\d$/.test(name))ranges.push(Decoration.line({class:'note-md-heading note-md-h'+name.slice(-1)}).range(state.doc.lineAt(from).from));
    if(name==='StrongEmphasis')mark(from,to,'note-md-strong');
    if(name==='Emphasis')mark(from,to,'note-md-em');
    if(name==='Strikethrough')mark(from,to,'note-md-strike');
    if(name==='Blockquote')for(let n=state.doc.lineAt(from).number;n<=state.doc.lineAt(to).number;n++)ranges.push(Decoration.line({class:'note-md-quote'}).range(state.doc.line(n).from));
    if(['EmphasisMark','CodeMark','StrikethroughMark','QuoteMark'].includes(name))hide(from,to);
    if(name==='HeaderMark'){const end=text[to]===' '?to+1:to;if(sel.head>=end||sel.head<from)hide(from,end);}
    if(name==='ListMark'){if(/[-+*]/.test(text.slice(from,to)))ranges.push(Decoration.replace({noteAtomic:true,widget:new Rendered('<span class="note-md-list-mark">•</span>',from,to)}).range(from,to));else mark(from,to,'note-md-list-mark');}
    if(name==='TaskMarker'&&!editing(from,to))ranges.push(Decoration.replace({noteAtomic:true,widget:new TaskCheckbox(from,text[from+1].toLowerCase()==='x')}).range(from,to));
    if(name==='Link'){
      const destination=node.node.getChild('URL');
      const href=destination && text.slice(destination.from,destination.to);
      const id=preview.links.get(href);
      const close=node.node.getChildren('LinkMark')[1];
      if(id && close && !editing(from,to)){
        const label = text.slice(from + 1, close.from).replace(/\\([\\\[\]])/g, '$1');
        if(label){
          ranges.push(Decoration.replace({widget:new PassageLink(href,id,label,from)}).range(from,to));
          occupied.push([from,to]);
          return false;
        }
      }
    }
  }});
  const pattern=/\$\$([\s\S]+?)\$\$|(?<![\\$])\$(?!\$)((?:\\.|[^$\n])+?)\$(?!\$)/g;
  for(const match of text.matchAll(pattern)){
    const from=match.index,to=from+match[0].length;if(occupied.some(([a,b])=>from<b&&to>a)||editing(from,to))continue;
    const display=match[1]!==undefined,latex=(match[1]??match[2]).trim(),html=preview.math.get((display?'block:':'inline:')+latex);if(!html)continue;
    const block=display&&state.doc.lineAt(from).from===from&&state.doc.lineAt(to).to===to;
    ranges.push(Decoration.replace({noteAtomic:true,widget:new Rendered(html,from,to,block),block}).range(from,to));
  }
  return Decoration.set(ranges,true);
}
const presentation=StateField.define({
  create(state){const preview={math:new Map(),tables:[],links:new Map()};return {preview,ranges:decorations(state,preview)};},
  update(value,tr){let preview=value.preview;for(const effect of tr.effects)if(effect.is(compiled))preview=effect.value;
    // Old tables must never replace a newly edited table before the new source has compiled.
    if(tr.docChanged)preview={math:preview.math,tables:[],links:preview.links};
    return tr.docChanged||tr.selection||syntaxTree(tr.startState)!==syntaxTree(tr.state)||preview!==value.preview?{preview,ranges:decorations(tr.state,preview)}:value;
  },
  provide:field=>[EditorView.decorations.from(field,v=>v.ranges),EditorView.atomicRanges.of(view=>view.state.field(field).ranges.update({filter:(_from,_to,value)=>!!value.spec.noteAtomic}))]
});
window.PaperNoteEditor={bindPassages,attachSummary,create(host,source,onChange,onDone){
  let silent=false;
  const view=new EditorView({parent:host,state:EditorState.create({doc:source,extensions:[
    markdown({extensions:GFM}),history(),presentation,EditorView.lineWrapping,
    keymap.of([{key:'Mod-Enter',run:()=>{onDone();return true;}},{key:'Escape',run:()=>{onDone();return true;}},...markdownKeymap,...defaultKeymap,...historyKeymap]),
    placeholder('写下想法，支持 Markdown 和 $公式$'),
    EditorView.contentAttributes.of({'aria-label':'笔记 Markdown 编辑器','spellcheck':'false'}),
    EditorView.updateListener.of(update=>{if(update.docChanged&&!silent)onChange(view.state.doc.toString());})
  ]})});
  const api={view,get value(){return view.state.doc.toString();},set value(value){if(value===api.value)return;silent=true;view.dispatch({changes:{from:0,to:view.state.doc.length,insert:value},annotations:Transaction.addToHistory.of(false)});silent=false;},
    get selectionStart(){return view.state.selection.main.from;},get selectionEnd(){return view.state.selection.main.to;},
    setSelectionRange(anchor,head){view.dispatch({selection:{anchor,head}});},focus(){view.focus();},destroy(){view.destroy();},undo(){undo(view);},redo(){redo(view);},
    insertPassage(source,from,to,markdown){
      if(api.value!==source || from<0 || to<from || to>source.length)return false;
      view.dispatch({changes:{from,to,insert:markdown},selection:{anchor:from+markdown.length}});
      view.focus();return true;
    },
    preview(source,html){if(api.value!==source)return;const doc=new DOMParser().parseFromString(html,'text/html'),math=new Map(),links=new Map();for(const node of doc.querySelectorAll('math[alttext]'))math.set((node.getAttribute('display')==='block'?'block:':'inline:')+node.getAttribute('alttext').trim(),node.outerHTML);for(const a of doc.querySelectorAll('a[data-passage]'))links.set(a.getAttribute('href'),a.dataset.passage);view.dispatch({effects:compiled.of({math,links,tables:[...doc.querySelectorAll('table')].map(n=>n.outerHTML)})});}
  };
  host.noteEditor=api;Object.defineProperties(host,{value:{get:()=>api.value,set:v=>{api.value=v;}},selectionStart:{get:()=>api.selectionStart},selectionEnd:{get:()=>api.selectionEnd}});
  host.setSelectionRange=(a,b)=>api.setSelectionRange(a,b);host.focus=()=>api.focus();return api;
}};
