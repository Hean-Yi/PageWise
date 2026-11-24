import {EditorState} from '@codemirror/state';
import {history, undo, redo} from '@codemirror/commands';
import {
  readSummarySelection, restoreSummarySelection, summarySourcePoint, summaryDOMPoint, summaryMathRange, summaryTaskRange
} from './SummarySelection.js';

// WebKit edits the typeset document itself. The source document and its undo history
// record Markdown replacements, so untouched tables, references and TeX keep their original spelling.
export function attachSummary(prose, onChange, onEditing) {
  const newState = doc => EditorState.create({doc, extensions: [history()]});
  let state = newState(''), source = '', compiled = null, lastHTML = null, editing = false;
  let pendingInput = null, composing = null, raw = null, remembered = null;
  let lastNative = null, ignoreCompositionCommit = false, pointerDown = false;
  const listeners = new AbortController();
  const listen = (target, type, f) => target.addEventListener(type, f, {signal: listeners.signal});
  const caret = position => ({anchor: position, head: position});
  const selectionAPI = () => {
    const sel = getSelection();
    return [sel.anchorNode, sel.anchorOffset, sel.focusNode, sel.focusOffset];
  };
  const inProse = node => node && prose.contains(node);
  function remember(selection) {
    remembered = selection;
    lastNative = selectionAPI();
  }
  function rawPoint(node, offset) {
    if (!raw?.element.contains(node)) return null;
    const range = document.createRange();
    range.selectNodeContents(raw.element);
    range.setEnd(node, offset);
    return Math.min(raw.to, raw.from + range.toString().length);
  }
  function point(node, offset, bias) {
    return rawPoint(node, offset) ?? summarySourcePoint(prose, source, node, offset, bias);
  }
  function read() {
    const native = selectionAPI();
    if (lastNative && native.every((v, i) => v === lastNative[i])) return remembered;
    if (!inProse(native[0]) || !inProse(native[2])) return remembered;
    if (raw) {
      const a = rawPoint(native[0], native[1]), h = rawPoint(native[2], native[3]);
      if (a !== null && h !== null) return {anchor: a, head: h};
    }
    return readSummarySelection(prose, source) ?? remembered;
  }
  function restore(selection) {
    if (!selection) return;
    restoreSummarySelection(prose, source, selection.anchor, selection.head);
    remember(selection);
  }
  function begin(selection) {
    if (!editing) {
      editing = true;
      prose.setAttribute('contenteditable', 'true');
      prose.setAttribute('role', 'textbox');
      prose.setAttribute('aria-multiline', 'true');
      prose.setAttribute('aria-label', '笔记 Markdown 编辑器');
      onEditing(true);
    }
    prose.focus({preventScroll: true});
    if (selection) restore(selection);
  }
  function applyHTML() {
    if (compiled === null || raw || composing || pointerDown) return;
    const html = compiled;
    compiled = null;
    const selected = editing ? read() : null;
    // Reconcile only the changed top-level blocks. In particular, opening the
    // editor never replaces a node or changes the scroll position.
    const template = document.createElement('template');
    template.innerHTML = html;
    for (const task of template.content.querySelectorAll('li input[type=checkbox]')) {
      if (summaryTaskRange(template.content, source, task)) {
        task.disabled = false;
        task.setAttribute('aria-label', '任务完成状态');
      }
    }
    let old = prose.firstChild;
    let changed = false;
    for (const fresh of [...template.content.childNodes]) {
      if (old?.isEqualNode(fresh)) {
        old = old.nextSibling;
      } else if (old?.nextSibling?.isEqualNode(fresh)) {
        const obsolete = old;
        old = old.nextSibling.nextSibling;
        obsolete.remove();
        changed = true;
      } else {
        const next = old?.nextSibling;
        if (old) old.replaceWith(fresh);
        else prose.append(fresh);
        old = next;
        changed = true;
      }
    }
    while (old) {
      const next = old.nextSibling;
      old.remove();
      old = next;
      changed = true;
    }
    prose.style.whiteSpace = 'normal';
    if (changed && selected && document.activeElement === prose) restore(selected);
    for (const link of prose.querySelectorAll('a[data-passage]')) {
      link.editPassageSource = () => revealSource(link, false);
    }
  }
  function finish() {
    if (!editing) return;
    if (composing) commitComposition(composing.text);
    const selection = read();
    closeRaw();
    editing = false;
    prose.removeAttribute('contenteditable');
    prose.removeAttribute('role');
    prose.removeAttribute('aria-multiline');
    prose.setAttribute('aria-label', '阅读笔记正文');
    applyHTML();
    if (selection) remember(selection);
    onEditing(false);
  }
  function patchSourceRanges(tr) {
    for (const block of prose.querySelectorAll('[data-note-range]')) {
      const [a,b] = block.dataset.noteRange.split(':').map(Number);
      block.dataset.noteRange = tr.changes.mapPos(a, -1) + ':' + tr.changes.mapPos(b, 1);
    }
    if (raw) {
      raw.from = tr.changes.mapPos(raw.from, -1);
      raw.to = tr.changes.mapPos(raw.to, 1);
    }
  }
  function store(tr) {
    state = tr.state;
    if (!tr.docChanged) return;
    patchSourceRanges(tr);
    source = state.doc.toString();
    compiled = null;
    onChange(source);
  }
  // Use the browser's target range for character/word deletion, autocorrect,
  // spellcheck and replacement. Accessibility insertText can deliver only 'input'.
  function intent(event) {
    const type = event.inputType || 'insertText';
    let selection = read() ?? caret(source.length);
    const target = event.getTargetRanges?.()[0];
    if (target && inProse(target.startContainer) && inProse(target.endContainer)) {
      const sel = getSelection();
      const current = sel.rangeCount ? sel.getRangeAt(0) : null;
      const isCurrent = current && current.startContainer === target.startContainer &&
        current.startOffset === target.startOffset && current.endContainer === target.endContainer &&
        current.endOffset === target.endOffset;
      if (!isCurrent) {
        selection = {anchor: point(target.startContainer, target.startOffset, 1),
                     head: point(target.endContainer, target.endOffset, -1)};
      }
    }
    let from = Math.min(selection.anchor, selection.head), to = Math.max(selection.anchor, selection.head);
    if (type.startsWith('delete') && from === to) {
      // When native ranges are unavailable, operate on an entire grapheme.
      if (type.endsWith('Backward')) {
        const text = source.slice(0, from);
        const last = new Intl.Segmenter(undefined, {granularity:'grapheme'}).segment(text).containing(from - 1);
        from = last?.index ?? from;
      } else if (type.endsWith('Forward')) {
        const next = new Intl.Segmenter(undefined, {granularity:'grapheme'}).segment(source).containing(to);
        to += next?.segment.length ?? 0;
      }
    }
    let text = event.data ?? '';
    if (type === 'insertParagraph') {
      const element = getSelection().focusNode?.parentElement;
      text = raw || element?.closest('pre') ? '\n' : '\n\n';
      const line = state.doc.lineAt(from).text;
      const list = element?.closest('li') && line.match(/^(\s*)([-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/);
      if (list) {
        const marker = /^\d/.test(list[2]) ? (parseInt(list[2], 10) + 1) + list[2].slice(-1) : list[2];
        text = '\n' + list[1] + marker + ' ' + (/\[[ xX]\]/.test(list[0]) ? '[ ] ' : '');
      } else if (element?.closest('blockquote')) text = '\n> ';
    } else if (type === 'insertLineBreak') text = raw ? '\n' : ' '.repeat(2) + '\n';
    else if (!type.startsWith('insert') && !type.startsWith('delete')) return null;
    return {from, to, text: text.replace(/\r\n?/g, '\n'), type};
  }
  function replace(change) {
    const {from, to, text, type} = change;
    if (from === to && !text) return;
    state = state.update({selection: {anchor: from, head: to}}).state;
    const selection = caret(from + text.length);
    const userEvent = type.startsWith('delete') ? 'delete' : type === 'insertFromPaste' ? 'input.paste' : 'input.type';
    store(state.update({changes: {from, to, insert: text}, selection, userEvent}));
    remember(selection);
  }
  function replaceDOM(range, text) {
    range.deleteContents();
    const node = document.createTextNode(text);
    range.insertNode(node);
    getSelection().setBaseAndExtent(node, text.length, node, text.length);
  }
  function rangeFor(sourceFrom, sourceTo) {
    const a = summaryDOMPoint(prose, source, sourceFrom, 1);
    const b = summaryDOMPoint(prose, source, sourceTo, -1);
    const range = document.createRange();
    range.setStart(a.node, a.offset);
    range.setEnd(b.node, b.offset);
    return range;
  }
  function insert(from, to, text, type) {
    const sel = getSelection();
    const native = sel.rangeCount && inProse(sel.anchorNode) && inProse(sel.focusNode) ? sel.getRangeAt(0) : null;
    const current = read();
    const range = native && current && from === Math.min(current.anchor,current.head) && to === Math.max(current.anchor,current.head)
      ? native : rangeFor(from, to);
    replaceDOM(range, text);
    replace({from, to, text, type});
  }
  function goBack(forward) {
    if (composing) return;
    raw = null;
    (forward ? redo : undo)({state, dispatch(tr) {
      const replacements = [];
      tr.changes.iterChanges((a,b,_c,_d,text) => replacements.push([rangeFor(a,b), text.toString()]));
      for (const [range,text] of replacements.reverse()) replaceDOM(range,text);
      store(tr);
      restore({anchor:tr.state.selection.main.anchor, head:tr.state.selection.main.head});
    }});
  }
  function closeRaw() {
    if (!raw) return;
    if (source.slice(raw.from, raw.to) === raw.originalText) {
      raw.element.replaceWith(raw.originalNode);
    } else if (lastHTML?.source === source) {
      compiled = lastHTML.html;
    }
    raw = null;
    applyHTML();
  }
  function revealSource(element, formula) {
    const block = element.closest('[data-note-range]');
    if (!block) return;
    let region = formula ? element.closest('.note-math,.note-math-error') : block;
    const span = formula ? summaryMathRange(prose, source, region) : null;
    if (formula && !span) return;
    const [from, to] = span ? [span.from, span.to] : block.dataset.noteRange.split(':').map(Number);
    closeRaw();
    if (!region.isConnected) {
      region = [...prose.querySelectorAll(formula ? '.note-math,.note-math-error' : '[data-note-range]')].find(el =>
        formula ? summaryMathRange(prose, source, el)?.from === from : Number(el.dataset.noteRange.split(':')[0]) === from);
      if (!region) return;
    }
    begin();
    const replacement = document.createElement(formula ? 'span' : 'div');
    replacement.dataset.summarySource = '';
    replacement.textContent = source.slice(from, to);
    if (region.dataset.noteRange) replacement.dataset.noteRange = region.dataset.noteRange;
    raw = {element: replacement, originalNode: region, originalText: replacement.textContent, from, to};
    region.replaceWith(replacement);
    const offset = formula ? (replacement.textContent.match(/^\$+|^\\[[(]/)?.[0].length ?? 0) : 0;
    getSelection().setBaseAndExtent(replacement.firstChild, offset, replacement.firstChild, offset);
    remember(caret(from + offset));
  }
  function commitComposition(text) {
    if (!composing) return;
    const change = composing;
    composing = null;
    // An empty compositionend explicitly cancels the marked text, including a replacement selection.
    if (text) replace({...change, text});
    applyHTML();
  }
  prose.tabIndex = 0;
  prose.spellcheck = false;
  prose.setAttribute('aria-label', '阅读笔记正文');
  prose.setAttribute('aria-keyshortcuts', 'Enter');
  listen(document, 'selectionchange', () => {
    if (editing && !composing && !pendingInput && inProse(getSelection().anchorNode)) {
      const s = read();
      if (s) remember(s);
    }
  });
  listen(prose, 'pointerdown', () => { pointerDown = true; });
  listen(document, 'pointerup', () => {
    if (!pointerDown) return;
    pointerDown = false;
    // A click needs its original target after pointerup.
    requestAnimationFrame(applyHTML);
  });
  listen(prose, 'click', event => {
    const task = event.target.closest('input[type=checkbox]');
    if (task) {
      const marker = summaryTaskRange(prose, source, task);
      if (!marker || task.disabled || event.button !== 0) { event.preventDefault(); return; }
      store(state.update({changes: {...marker, insert: task.checked ? 'x' : ' '}, userEvent: 'input'}));
      return;
    }
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey ||
        event.target.closest('a,button,input') || !getSelection().isCollapsed) return;
    if (event.target.closest('[data-summary-source]')) return;
    const formula = !!event.target.closest('.note-math,.note-math-error');
    if (formula || event.altKey) { revealSource(event.target, formula); return; }
    closeRaw();
    if (editing) return;
    const range = document.caretRangeFromPoint(event.clientX, event.clientY);
    const aimed = range && event.target.contains(range.startContainer);
    const position = aimed ? point(range.startContainer, range.startOffset, 1) :
      point(event.target, 0, 1);
    begin(caret(position));
  });
  listen(prose, 'keydown', event => {
    if (event.isComposing || composing || event.defaultPrevented) return;
    const mod = event.metaKey || event.ctrlKey;
    if (!editing) {
      if (event.target !== prose || event.key !== 'Enter') return;
      event.preventDefault();
      begin(remembered ?? caret(0));
    } else if (event.key === 'Escape' || (mod && event.key === 'Enter')) {
      event.preventDefault(); finish();
    } else if (mod && event.key.toLowerCase() === 'z') {
      event.preventDefault(); goBack(event.shiftKey);
    } else if (mod && event.key.toLowerCase() === 'a') {
      event.preventDefault();
      const range = document.createRange(); range.selectNodeContents(prose);
      const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
      remember({anchor:0, head:source.length});
    } else if (event.key === 'F2' && !raw) {
      const element = getSelection().focusNode?.parentElement;
      if (inProse(element)) { event.preventDefault(); revealSource(element,false); }
    }
  });
  listen(prose, 'beforeinput', event => {
    if (!editing) return;
    if (event.isComposing || composing || event.inputType?.includes('Composition')) return;
    if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
      event.preventDefault(); goBack(event.inputType === 'historyRedo'); return;
    }
    if (event.inputType === 'formatBold' || event.inputType === 'formatItalic') {
      event.preventDefault();
      const s = read();
      if (s) {
        const from = Math.min(s.anchor,s.head), to = Math.max(s.anchor,s.head);
        const mark = event.inputType === 'formatBold' ? '**' : '*';
        insert(from, to, mark + source.slice(from, to) + mark, 'insertText');
      }
      return;
    }
    pendingInput = intent(event);
    if (!pendingInput) event.preventDefault();
  });
  listen(prose, 'input', event => {
    if (!editing || event.isComposing || composing || ignoreCompositionCommit || event.inputType?.includes('Composition')) return;
    // WebKit's execCommand and some accessibility inputs skip beforeinput.
    // Their native caret already follows the insertion; use the pre-input bookmark.
    const change = pendingInput ?? (remembered && event.inputType === 'insertText' ?
      {from:Math.min(remembered.anchor,remembered.head), to:Math.max(remembered.anchor,remembered.head),
       type:'insertText', text:event.data ?? ''} : intent(event));
    pendingInput = null;
    if (change) replace(change);
  });
  listen(prose, 'compositionstart', () => {
    const s = read() ?? caret(source.length);
    composing = {from: Math.min(s.anchor,s.head), to: Math.max(s.anchor,s.head), text:'', type:'insertCompositionText'};
    pendingInput = null;
  });
  listen(prose, 'compositionupdate', event => { if (composing) composing.text = event.data; });
  listen(prose, 'compositionend', event => {
    commitComposition(event.data);
    ignoreCompositionCommit = true;
    queueMicrotask(() => { ignoreCompositionCommit = false; });
  });
  listen(prose, 'paste', event => {
    if (!editing) return;
    event.preventDefault();
    const text = event.clipboardData?.getData('text/plain'), s = read();
    if (text !== undefined && s) insert(Math.min(s.anchor,s.head), Math.max(s.anchor,s.head), text.replace(/\r\n?/g,'\n'), 'insertFromPaste');
  });
  listen(prose, 'drop', event => { event.preventDefault(); });
  const api = {
    get value() { return source; },
    get selectionStart() { const s = read() ?? caret(source.length); return Math.min(s.anchor,s.head); },
    get selectionEnd() { const s = read() ?? caret(source.length); return Math.max(s.anchor,s.head); },
    insertPassage(expected, from, to, markdown) {
      if (!editing || expected !== source || from < 0 || to < from || to > source.length) return false;
      begin({anchor:from, head:to}); insert(from, to, markdown, 'insertText'); return true;
    }
  };
  return {
    get editor() { return editing ? api : null; },
    editForCitation() {
      if (!editing) begin(read() ?? caret(source.length));
      return api;
    },
    finish,
    update(value, html) {
      const normalized = value.replace(/\r\n?/g, '\n');
      if (editing && normalized !== source) return;
      if (source !== normalized) {
        state = newState(normalized); source = normalized; remembered = null; lastNative = null;
      }
      if (!html) {
        if (!editing && !prose.hasChildNodes()) { prose.textContent = source; prose.style.whiteSpace = 'pre-wrap'; }
        return;
      }
      lastHTML = {source, html};
      compiled = html;
      applyHTML();
    },
    destroy() { listeners.abort(); }
  };
}
