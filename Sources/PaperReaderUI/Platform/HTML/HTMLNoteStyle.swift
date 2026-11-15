import Foundation

enum HTMLNoteStyle {
    static let source = #"""
        (()=>{
          const style=document.createElement('style');style.textContent=`
          #reader-note-layer{position:absolute;top:0;left:0;width:100%;height:0;pointer-events:none;z-index:800}
          .reader-note-card{position:absolute;box-sizing:border-box;pointer-events:auto;width:240px;max-width:calc(100vw - 32px);max-height:min(420px,calc(100vh - 32px));display:flex;flex-direction:column;background:#faf8f3;color:#39352f;border:1px solid #ddd5c7;border-radius:14px;box-shadow:0 4px 16px #332d2818;font:15px/1.55 system-ui;overflow:hidden;transition:height .18s ease,transform .18s ease,box-shadow .18s ease,filter .18s ease,opacity .18s ease,max-height .18s ease;transform:translateY(0)}
          .reader-note-card.compact{overflow-y:auto;display:block}.reader-note-card.compact textarea{height:100px;min-height:60px}
          .reader-note-card[hidden]{display:none!important}
          .reader-note-card:not(.active){max-height:112px;filter:saturate(.55) blur(.18px);opacity:.68;background:#eeebe5;cursor:pointer}
          .reader-note-card.active{transform:translateY(-2px);box-shadow:0 8px 28px #332d2833;z-index:10;filter:none;opacity:1}
          .reader-note-card header{padding:10px 14px 6px;display:flex;align-items:center;gap:8px;flex-shrink:0;font:12px system-ui;color:#796e60}
          .reader-note-card header strong{margin-right:auto;color:inherit;font-weight:600}
          .reader-note-card button{font:inherit;color:inherit;border:0;border-radius:6px;background:transparent;padding:4px 7px;cursor:pointer}
          .reader-note-card button:hover{background:#e8e1d6}.reader-note-card button:focus-visible{outline:2px solid #a34c33}
          .reader-note-card .note-content{padding:8px 14px 14px;overflow:auto;min-height:0;overflow-wrap:anywhere;flex:1}
          .reader-note-card:not(.active) .note-content{display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden;padding-top:0;padding-bottom:8px}
          .reader-note-card:not(.active) header{padding-top:8px;padding-bottom:4px}
          .reader-note-card:not(.active) .note-content :is(p,h1,h2,h3,h4,h5,h6,blockquote,pre,ul,ol){font:inherit;margin-top:0;margin-bottom:0}
          .reader-note-card .note-content>*:first-child{margin-top:0}.reader-note-card .note-content>*:last-child{margin-bottom:0}
          .reader-note-card p,.reader-note-card blockquote,.reader-note-card pre{margin:0 0 .7em}
          .reader-note-card h1,.reader-note-card h2,.reader-note-card h3,.reader-note-card h4,.reader-note-card h5,.reader-note-card h6{font:650 1.15em/1.4 system-ui;margin:.7em 0 .4em}.reader-note-card h1{font-size:1.35em}
          .reader-note-card ul,.reader-note-card ol{padding-left:1.5em;margin:.4em 0}.reader-note-card blockquote{padding-left:10px;border-left:2px solid #b9ac98}
          .reader-note-card pre,.reader-note-card table{max-width:100%;overflow:auto}.reader-note-card pre{font: .9em/1.5 ui-monospace,monospace;padding:8px;background:#eae5dd;border-radius:5px}
          .reader-note-card math{font-size:1em}.reader-note-card math[display=block]{margin:.6em 0;overflow:auto;max-width:100%}.reader-note-card .note-math{display:inline-block;max-width:100%;vertical-align:middle;overflow-x:auto}
          .reader-note-card .note-math-error{color:#aa4935;border-bottom:1px dotted currentColor}
          .reader-note-card textarea{resize:none;box-sizing:border-box;width:100%;min-height:90px;flex:1;height:180px;border:0;outline:0;padding:10px 14px;background:transparent;color:inherit;font:15px/1.55 ui-monospace,monospace;overflow:auto;tab-size:2}
          .reader-note-card footer{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-shrink:0;padding:8px 12px;border-top:1px solid #e6e0d5;font:11px system-ui;color:#796e60}
          .reader-note-card .note-done{background:#a34c33;color:white;padding:5px 12px}.reader-note-card .note-delete{color:#a34c33}
          .reader-note-card .note-live-label{font:11px/1.4 system-ui;color:#8b7c69;padding:4px 14px;border-top:1px solid #e6e0d5;flex-shrink:0}
          .reader-note-card.editing-live textarea,.reader-note-card.editing-live .note-content{flex:1 1 0;min-height:64px}
          .reader-note-card .note-hidden{display:none!important}
          #annotation-menu.note-docked{position:static;width:100%;border:0;border-bottom:1px solid #e6e0d5;border-radius:0;box-shadow:none;flex-shrink:0;padding:8px 10px 0;font-size:12px}
          #annotation-menu.note-docked .bookmark,#annotation-menu.note-docked .add-note{display:none!important}
          #annotation-menu.note-docked .swatch{min-width:0;padding:3px;flex:1 1 0}#annotation-menu.note-docked .swatch span{width:16px;height:16px}
          #annotation-menu.note-docked .remove{padding:5px 8px;font-size:11px}
          #reader-note-decoration{position:absolute;top:0;left:0;width:100%;height:1px;pointer-events:none;z-index:3;overflow:visible}
          #reader-note-decoration .note-wave{fill:none;stroke:#a57957;stroke-width:1;opacity:.85}
          #reader-note-decoration .note-link{fill:none;stroke:#a58c70;stroke-width:1.2;stroke-dasharray:4 4}
          #reader-note-decoration .note-link-reveal{fill:none;stroke:white;stroke-width:4;stroke-dasharray:1;stroke-dashoffset:0;animation:note-link-in .22s cubic-bezier(.2,.7,.2,1) both}
          #reader-note-lift{position:absolute;top:0;left:0;width:100%;height:0;pointer-events:none;z-index:4}#reader-note-lift>span{position:absolute;white-space:pre;transform:translateY(-1.5px);text-shadow:0 1px 3px #332d2822;animation:note-lift .18s ease both}
          ::highlight(note-lift){color:transparent}
          #reader-note-undo{position:fixed;bottom:16px;right:20px;z-index:1100;background:#faf8f3;color:#a34c33;border:1px solid #d9d1c2;border-radius:9px;padding:9px 14px;font:13px system-ui;cursor:pointer}
          @keyframes note-lift{from{transform:translateY(0);opacity:.5}to{transform:translateY(-1.5px);opacity:1}}
          @keyframes note-link-in{from{stroke-dashoffset:1}to{stroke-dashoffset:0}}
          @media(prefers-reduced-motion:reduce){.reader-note-card,#reader-note-lift>span{transition:none!important;animation:none!important;transform:none!important}#reader-note-decoration .note-link-reveal{animation:none!important}}
          @media(prefers-color-scheme:dark){.reader-note-card{background:#302d28;color:#eee8dc;border-color:#51493f}.reader-note-card:not(.active){background:#282621}.reader-note-card header,.reader-note-card footer{color:#c0b3a1}.reader-note-card button:hover,.reader-note-card pre{background:#423a30}#annotation-menu.note-docked{background:#302d28}.reader-note-card footer{border-color:#51493f}}
          `;document.head.append(style);
        })();
        """#
}
