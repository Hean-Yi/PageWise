import Foundation

enum HTMLNoteStyle {
    static let source = #"""
        (()=>{
          const style=document.createElement('style');style.textContent=`
          #reader-note-layer{position:absolute;top:0;left:0;width:100%;height:0;pointer-events:none;z-index:800}
          .reader-note-card{position:absolute;box-sizing:border-box;pointer-events:auto;width:240px;max-width:calc(100vw - 32px);max-height:min(420px,calc(100vh - 32px));display:flex;flex-direction:column;background:#faf8f3;color:#39352f;border:1px solid #ddd5c7;border-radius:14px;box-shadow:0 4px 16px #332d2818;font:15px/1.55 system-ui;overflow:hidden;transition:box-shadow .16s ease,opacity .12s ease;transform:translateY(0)}
          .reader-note-card.compact.active{overflow-y:auto}.reader-note-card.compact.active .note-editor{min-height:80px}
          .reader-note-card[hidden]{display:none!important}
          .reader-note-card:not(.active){height:168px;opacity:.8;background:#eeebe5;cursor:pointer}
          .reader-note-card.active{transform:translateY(-2px);border-color:#c4a68a;box-shadow:0 8px 28px #332d2833;z-index:10;filter:none;opacity:1}
          .reader-note-card header{padding:10px 14px 6px;display:flex;align-items:center;gap:8px;flex-shrink:0;font:12px system-ui;color:#796e60}
          .reader-note-card header strong{margin-right:auto;color:inherit;font-weight:600}
          .reader-note-card button{font:inherit;color:inherit;border:0;border-radius:6px;background:transparent;padding:4px 7px;cursor:pointer}
          .reader-note-card button:hover{background:#e8e1d6}.reader-note-card button:focus-visible{outline:2px solid #a34c33}
          .reader-note-card .note-content{padding:8px 14px 14px;overflow:auto;min-height:0;overflow-wrap:anywhere;flex:1}
          .reader-note-card:not(.active) .note-content{display:none}
          .reader-note-card .note-summary{display:none;padding:0 14px 12px;font:15px/24px system-ui;color:#777067;overflow-wrap:anywhere}
          .reader-note-card:not(.active) .note-summary{display:-webkit-box;-webkit-line-clamp:5;-webkit-box-orient:vertical;overflow:hidden;height:120px;flex-shrink:0;filter:blur(.1px)}
          .reader-note-card:not(.active) header{height:34px;box-sizing:border-box;padding:8px 14px 4px}
          .reader-note-card .note-content>*:first-child{margin-top:0}.reader-note-card .note-content>*:last-child{margin-bottom:0}
          .reader-note-card p,.reader-note-card blockquote,.reader-note-card pre{margin:0 0 .7em}
          .reader-note-card h1,.reader-note-card h2,.reader-note-card h3,.reader-note-card h4,.reader-note-card h5,.reader-note-card h6{font:650 1.15em/1.4 system-ui;margin:.7em 0 .4em}.reader-note-card h1{font-size:1.35em}
          .reader-note-card ul,.reader-note-card ol{padding-left:1.5em;margin:.4em 0}.reader-note-card blockquote{padding-left:10px;border-left:2px solid #b9ac98}
          .reader-note-card pre,.reader-note-card table{max-width:100%;overflow:auto}.reader-note-card pre{font: .9em/1.5 ui-monospace,monospace;padding:8px;background:#eae5dd;border-radius:5px}
          .reader-note-card math{font-size:1em}.reader-note-card math[display=block]{margin:.6em 0;overflow:auto;max-width:100%}.reader-note-card .note-math{display:inline-block;max-width:100%;vertical-align:middle;overflow-x:auto}
          .reader-note-card .note-math-error{color:#aa4935;border-bottom:1px dotted currentColor}
          .reader-note-card .note-editor{min-height:90px;flex:1;overflow:hidden;font:15px/1.6 system-ui}
          .reader-note-card .cm-editor{height:100%;background:transparent;color:inherit;outline:none}
          .reader-note-card .cm-scroller{font:inherit;overflow:auto;padding:10px 14px}
          .reader-note-card .cm-content{font:inherit;padding:0;caret-color:#a34c33;min-height:100px}
          .reader-note-card .cm-line{padding:0}.reader-note-card .cm-focused{outline:none}
          .reader-note-card .cm-selectionBackground{background:#b8c6d55c!important}
          .reader-note-card .note-md-strong{font-weight:700}.reader-note-card .note-md-em{font-style:italic}.reader-note-card .note-md-strike{text-decoration:line-through}
          .reader-note-card .note-md-heading{font-weight:650;font-size:1.2em;line-height:1.5;padding:4px 0}.reader-note-card .note-md-h1{font-size:1.35em}
          .reader-note-card .note-md-code,.reader-note-card .note-md-code-line{font-family:ui-monospace,monospace;background:#b7a88e15;border-radius:3px}
          .reader-note-card .note-md-quote{border-left:2px solid #b9ac98;padding-left:9px}
          .reader-note-card .note-md-link,.reader-note-card .note-md-list-mark{color:#a34c33}
          .reader-note-card .note-md-widget{display:inline-block;vertical-align:middle;max-width:100%;overflow:auto;cursor:text}
          .reader-note-card .note-md-widget math{font-size:1em;margin:0}.reader-note-card .note-md-widget>table{font:inherit}
          .reader-note-card footer{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-shrink:0;padding:8px 12px;border-top:1px solid #e6e0d5;font:11px system-ui;color:#796e60}
          .reader-note-card .note-done{background:#a34c33;color:white;padding:5px 12px}.reader-note-card .note-delete{color:#a34c33}
          .reader-note-card .note-hidden{display:none!important}
          #annotation-menu.note-docked{position:static;width:100%;border:0;border-bottom:1px solid #e6e0d5;border-radius:0;box-shadow:none;flex-shrink:0;padding:8px 10px 0;font-size:12px}
          #annotation-menu.note-docked .bookmark,#annotation-menu.note-docked .add-note{display:none!important}
          #annotation-menu.note-docked .swatch{min-width:0;padding:3px;flex:1 1 0}#annotation-menu.note-docked .swatch span{width:16px;height:16px}
          #annotation-menu.note-docked .remove{padding:5px 8px;font-size:11px}
          #reader-note-decoration{position:absolute;top:0;left:0;width:100%;height:1px;pointer-events:none;z-index:5;overflow:visible}
          .note-wave{fill:none;stroke:#a57957;stroke-width:1.05;stroke-linecap:round;stroke-linejoin:round;opacity:.85}
          #reader-note-decoration .note-link{fill:none;stroke:#ad7952;stroke-width:1.35;stroke-dasharray:2 5;stroke-linecap:round;opacity:.8}
          #reader-note-decoration .note-link-end{fill:#faf8f3;stroke:#a34c33;stroke-width:1.3}
          #reader-note-decoration .note-link-start{fill:#a34c33;stroke:none}
          #reader-note-decoration .note-link-reveal{fill:none;stroke:white;stroke-width:4;stroke-dasharray:1;stroke-dashoffset:0;animation:note-link-in .22s cubic-bezier(.2,.7,.2,1) both}
          #reader-note-lift{position:absolute;top:0;left:0;width:100%;height:0;pointer-events:none;z-index:4}.note-lift-group{position:absolute;left:0;top:0;width:100%;height:0;filter:drop-shadow(0 1px 1px #332d2820)}.note-lift-group>span,.note-lift-group>i{position:absolute;white-space:pre;font-style:normal}.note-lift-waves{position:absolute;left:0;top:0;width:100%;height:1px;overflow:visible}
          ::highlight(note-lift){color:transparent}
          #reader-note-undo{position:fixed;bottom:16px;right:20px;z-index:1100;background:#faf8f3;color:#a34c33;border:1px solid #d9d1c2;border-radius:9px;padding:9px 14px;font:13px system-ui;cursor:pointer}
          @keyframes note-link-in{from{stroke-dashoffset:1}to{stroke-dashoffset:0}}
          @media(prefers-reduced-motion:reduce){.reader-note-card,#reader-note-lift .note-lift-group{transition:none!important;animation:none!important;transform:none!important}#reader-note-decoration .note-link-reveal{animation:none!important}}
          @media(prefers-color-scheme:dark){.reader-note-card{background:#302d28;color:#eee8dc;border-color:#51493f}.reader-note-card:not(.active){background:#282621}.reader-note-card header,.reader-note-card footer{color:#c0b3a1}.reader-note-card button:hover,.reader-note-card pre{background:#423a30}#annotation-menu.note-docked{background:#302d28}.reader-note-card footer{border-color:#51493f}}
          `;document.head.append(style);
        })();
        """#
}
