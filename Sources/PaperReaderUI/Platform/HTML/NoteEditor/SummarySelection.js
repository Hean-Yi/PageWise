import {GFM, parser} from '@lezer/markdown';

const grammar = parser.configure(GFM);
const markup = new Set(['HeaderMark', 'EmphasisMark', 'StrikethroughMark', 'QuoteMark',
  'ListMark', 'TaskMarker', 'LinkMark', 'CodeMark', 'CodeInfo', 'TableDelimiter', 'HTMLTag', 'LinkTitle', 'LinkLabel']);
const projections = new WeakMap();

// Each rendered UTF-16 unit keeps both source boundaries: at **A** the start of A is after the opening marks.
function project(raw, literal) {
  const skips = new Map(), decoded = new Map(), code = [], taskItems = [];
  const decoder = document.createElement('textarea');
  grammar.parse(raw).iterate({enter(node) {
    const {name, from, to} = node;
    if (name === 'ListItem') {
      const marker = node.node.getChild('Task')?.getChild('TaskMarker');
      taskItems.push(marker && /^\[[ xX]\]$/.test(raw.slice(marker.from, marker.to)) ? marker.from + 1 : null);
    }
    if (markup.has(name) || (name === 'URL' && node.node.parent?.name === 'Link')) {
      skips.set(from, to);
    } else if (name === 'Escape' || name === 'Entity') {
      const token = raw.slice(from, to);
      if (name === 'Entity') decoder.innerHTML = token;
      decoded.set(from, {to, value: name === 'Escape' ? token.slice(1) : decoder.value});
    } else if (['InlineCode', 'CodeBlock', 'FencedCode'].includes(name)) {
      code.push([from, to]);
    }
  }});
  let visible = '';
  const starts = [], ends = [];
  for (let i = 0; i < raw.length;) {
    if (skips.has(i)) { i = skips.get(i); continue; }
    const entity = decoded.get(i);
    let value = entity?.value ?? raw[i], end = entity?.to ?? i + 1;
    if (!literal && /\s/.test(value[0])) {
      while (end < raw.length && /\s/.test(raw[end])) end++;
      value = ' ';
      // A soft break can contain a quote/list marker between two otherwise contiguous spaces.
      if (visible.endsWith(' ')) { ends[ends.length - 1] = end; i = end; continue; }
    }
    visible += value;
    for (let j = 0; j < value.length; j++) {
      starts.push(j === 0 ? i : Math.min(i + j, end));
      ends.push(j === value.length - 1 ? end : Math.min(i + j + 1, end));
    }
    i = end;
  }
  const formulas = noteFormulaRanges(raw, code);
  return {visible, starts, ends, formulas, taskItems, raw};
}

// Scan each prose interval separately: a literal dollar inside code cannot open or close a formula.
export function noteFormulaRanges(text, excluded = []) {
  const formulas = [];
  const pattern = /(?<![\\$])\$\$([\s\S]+?)\$\$|(?<!\\)\\\[([\s\S]+?)\\\]|(?<!\\)\\\(([\s\S]+?)\\\)|(?<![\\$])\$(?![\s$])((?:\\.|[^$\n])+?)(?<!\s)\$(?![\d$])/g;
  let start = 0;
  function scan(end) {
    for (const m of text.slice(start, end).matchAll(pattern)) {
      const from = start + m.index;
      formulas.push({from, to: from + m[0].length, latex: (m[1] ?? m[2] ?? m[3] ?? m[4]).trim(),
        display: m[1] !== undefined || m[2] !== undefined, raw: m[0]});
    }
  }
  for (const [from, to] of excluded) {
    if (from > start) scan(from);
    start = Math.max(start, to);
  }
  scan(text.length);
  return formulas;
}

function blockOf(prose, node) {
  if (!node || !prose.contains(node)) return null;
  const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  return element.closest('[data-note-range]') || element.closest('.note-prose > *') || prose;
}

function bounds(prose, block, source) {
  const value = block.dataset.noteRange;
  if (value) return value.split(':').map(n => Math.min(source.length, Number(n)));
  if (prose === block) return [0, source.length];
  // Sanitizing raw HTML may unwrap a block. Use its actual neighbours as bounds.
  let start = 0, end = source.length;
  for (const other of prose.querySelectorAll('[data-note-range]')) {
    const [from, to] = other.dataset.noteRange.split(':').map(Number);
    const relation = block.compareDocumentPosition(other);
    if (relation & Node.DOCUMENT_POSITION_PRECEDING) start = to;
    if (relation & Node.DOCUMENT_POSITION_FOLLOWING) { end = from; break; }
  }
  return [start, end];
}

function lowerBound(values, needle) {
  let low = 0, high = values.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (values[middle] < needle) low = middle + 1; else high = middle;
  }
  return low;
}

function projection(block, raw) {
  let map = projections.get(block);
  if (!map || map.raw !== raw) {
    map = project(raw, block.matches('pre,code'));
    projections.set(block, map);
  }
  return map;
}

// Only map the block containing the endpoint. DOM text nodes can change during native input,
// whereas the immutable projection for the same Markdown slice may be reused across keystrokes.
function runsFor(prose, source, block) {
  const [start, end] = bounds(prose, block, source);
  const raw = source.slice(start, end), literal = block.matches('pre,code');
  const map = projection(block, raw);
  const runs = [];
  let cursor = 0, formulaIndex = 0;
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  for (let node; (node = walker.nextNode());) {
    if (node.nodeType === Node.ELEMENT_NODE) {
      if (!node.matches('.note-math,.note-math-error')) continue;
      const latex = node.querySelector('math')?.getAttribute('alttext');
      const index = map.formulas.findIndex((f, i) => i >= formulaIndex &&
        (latex ? f.latex === latex.trim() : f.raw === node.textContent));
      if (index < 0) continue;
      const f = map.formulas[index];
      formulaIndex = index + 1;
      cursor = lowerBound(map.starts, f.to);
      runs.push({node, from: start + f.from, to: start + f.to});
      continue;
    }
    if (node.parentElement.closest('.note-math,.note-math-error')) continue;
    const data = node.data;
    if (!data.length) continue;
    const visible = literal ? data : data.replace(/\s+/g, ' ');
    // SwiftSoup indents HTML containers when serializing. Those whitespace nodes are not prose.
    if (!literal && !visible.trim() && !node.parentElement.closest('p,li,td,th,h1,h2,h3,h4,h5,h6,blockquote,code')) continue;
    let at = map.visible.indexOf(visible, cursor), prefix = 0, match = visible;
    if (at < 0 && visible.trim()) {
      match = visible.trim();
      prefix = visible.indexOf(match);
      at = map.visible.indexOf(match, cursor);
    }
    if (at < 0) continue;
    const points = [];
    let pos = 0, previousSpace = false;
    for (let i = 0; i <= data.length; i++) {
      const unit = Math.max(0, Math.min(match.length, pos - prefix));
      points.push(start + (unit === 0 ? map.starts[at] : map.ends[at + unit - 1]));
      if (i === data.length) break;
      const space = !literal && /\s/.test(data[i]);
      if (!space || !previousSpace) pos++;
      previousSpace = space;
    }
    runs.push({node, from: points[0], to: points.at(-1), points});
    cursor = at + match.length;
  }
  return runs;
}

function domEdge(run, last) {
  if (run.points) return {node: run.node, offset: last ? run.points.length - 1 : 0};
  const parent = run.node.parentNode;
  return {node: parent, offset: Array.prototype.indexOf.call(parent.childNodes, run.node) + Number(last)};
}

// Identify the visible list item first. An incidental HTML checkbox must never toggle a later Markdown task.
export function summaryTaskRange(prose, source, input) {
  const block = blockOf(prose, input), item = input?.closest('li');
  if (!block || !item || !input.matches('input[type="checkbox"]')) return null;
  const first = item.firstElementChild;
  if (input !== first && !(first?.matches('p') && input === first.firstElementChild)) return null;
  const items = [...block.querySelectorAll('li')];
  const [start, end] = bounds(prose, block, source);
  const markers = projection(block, source.slice(start, end)).taskItems;
  if (items.length !== markers.length) return null;
  const marker = markers[items.indexOf(item)];
  return marker == null ? null : {from: start + marker, to: start + marker + 1};
}

export function summaryMathRange(prose, source, element) {
  const target = element.closest('.note-math,.note-math-error');
  const block = blockOf(prose, target);
  if (!block) return null;
  const run = runsFor(prose, source, block).find(r => r.node === target);
  return run ? {from: run.from, to: run.to} : null;
}

export function summarySourcePoint(prose, source, node, offset, bias = 1) {
  const block = blockOf(prose, node);
  if (!block) return null;
  if (node === prose) {
    if (offset === 0) return 0;
    if (offset >= node.childNodes.length) return source.length;
    const child = node.childNodes[offset];
    return summarySourcePoint(prose, source, child, 0, bias);
  }
  // The initial plain-text fallback has no semantic spans yet.
  if (block === prose && prose.childNodes.length === 1 && prose.firstChild === node) {
    return Math.min(source.length, offset);
  }
  const runs = runsFor(prose, source, block);
  for (const run of runs) {
    if (run.node === node && run.points) return run.points[Math.min(offset, run.points.length - 1)];
    if (!run.points && run.node.contains(node)) return bias < 0 ? run.from : run.to;
  }
  // WebKit also represents a caret between inline elements as a parent/child index.
  const caret = document.createRange();
  caret.setStart(node, offset);
  caret.collapse(true);
  let previous = null;
  for (const run of runs) {
    const point = domEdge(run, false);
    if (caret.comparePoint(point.node, point.offset) >= 0) return bias < 0 && previous ? previous.to : run.from;
    previous = run;
  }
  return previous?.to ?? bounds(prose, block, source)[0];
}

export function summaryDOMPoint(prose, source, offset, bias = 1) {
  const blocks = [...prose.children];
  if (!blocks.length) {
    const child = prose.firstChild;
    return child?.nodeType === Node.TEXT_NODE ? {node: child, offset: Math.min(offset, child.length)} : {node: prose, offset: 0};
  }
  let block = blocks[0];
  for (const element of blocks) {
    const [from, to] = bounds(prose, element, source);
    if (from > offset && bias < 0) break;
    block = element;
    if (offset < to || (offset === to && bias < 0)) break;
  }
  const runs = runsFor(prose, source, block);
  let previous = null;
  for (const run of runs) {
    if (offset < run.from) return previous && bias < 0 ? domEdge(previous, true) : domEdge(run, false);
    if (offset <= run.to) {
      if (!run.points) return domEdge(run, offset === run.to || (offset > run.from && bias > 0));
      const index = lowerBound(run.points, offset);
      return {node: run.node, offset: index};
    }
    previous = run;
  }
  return previous ? domEdge(previous, true) : {node: block, offset: 0};
}

export function readSummarySelection(prose, source) {
  const selection = getSelection();
  if (!selection?.rangeCount || !prose.contains(selection.anchorNode) || !prose.contains(selection.focusNode)) return null;
  const anchor = summarySourcePoint(prose, source, selection.anchorNode, selection.anchorOffset);
  const head = selection.isCollapsed ? anchor : summarySourcePoint(prose, source, selection.focusNode, selection.focusOffset);
  return {anchor, head};
}

export function restoreSummarySelection(prose, source, anchor, head = anchor) {
  if (![anchor, head].every(n => Number.isInteger(n) && n >= 0 && n <= source.length)) return false;
  const a = summaryDOMPoint(prose, source, anchor, anchor <= head ? 1 : -1);
  const b = anchor === head ? a : summaryDOMPoint(prose, source, head, head >= anchor ? -1 : 1);
  getSelection().setBaseAndExtent(a.node, a.offset, b.node, b.offset);
  return true;
}
