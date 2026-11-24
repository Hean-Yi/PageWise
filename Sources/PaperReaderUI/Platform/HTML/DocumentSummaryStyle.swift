import PaperReaderKit

/// Shared by the appendix after the last TeX block and the reader opened from the outline.
enum DocumentSummaryStyle {
    static let css = """
        #reader-document-summary{
          \(ReadingPageTypography.sourceColumn);box-sizing:border-box;min-width:0;overflow-wrap:anywhere;
          font:17px/1.8 \(ReadingPageTypography.sourceChinese);color:inherit;
          --note-rule:light-dark(#d9d4ca,#514d45);--note-accent:light-dark(#9f503a,#e8a086);
          --note-tint:light-dark(#f0ede6,#322f2a)
        }
        body.pdf-summary #reader-document-summary{
          \(ReadingPageTypography.pdfColumn);font:var(--zh-size,16px)/1.8 \(ReadingPageTypography.pdfChinese)
        }
        #reader + #reader-document-summary{min-height:85vh;break-before:page}
        #reader-document-summary>header{display:flex;align-items:center;gap:12px;border-top:1px solid var(--note-rule);
          padding-top:18px;margin-bottom:26px;font:600 14px/1.4 system-ui}
        #reader-document-summary>header span{margin-inline-start:auto}
        #reader-document-summary>header button{padding:4px 0 4px 10px;border:0;background:transparent;
          font:500 14px/1.4 system-ui;color:var(--note-accent);cursor:pointer}
        #reader-document-summary :is(button,a):focus-visible{outline:2px solid var(--note-accent);outline-offset:3px}
        #reader-document-summary .note-prose{cursor:text;min-height:2em}
        #reader-document-summary .note-prose:empty::before{content:'写下阅读笔记…';opacity:.55}
        #reader-document-summary .note-prose:focus-visible{outline:1px solid var(--note-rule);outline-offset:4px}
        #reader-document-summary .summary-writing.reader-note-card{position:static;display:block;width:100%;height:auto;
          max-width:none;max-height:none;border:0;box-shadow:none;border-radius:0;transform:none;overflow:visible;
          font:inherit;color:inherit;background:transparent}
        #reader-document-summary .summary-writing .cm-editor{height:auto}
        #reader-document-summary .summary-writing .cm-scroller{font:inherit;overflow:visible;padding:0}
        #reader-document-summary .summary-writing .note-md-heading{font-family:system-ui}
        #reader-document-summary .summary-writing .note-md-h1{font-size:1.8em}
        #reader-document-summary .summary-writing .note-md-h2{font-size:1.45em}
        #reader-document-summary .note-prose>:first-child{margin-block-start:0}
        #reader-document-summary .note-prose>:last-child{margin-block-end:0}
        #reader-document-summary .note-prose :is(h1,h2,h3,h4,h5,h6){margin:1.5em 0 .55em;font:650 1.15em/1.45 system-ui}
        #reader-document-summary .note-prose h1{font-size:1.8em;line-height:1.3}
        #reader-document-summary .note-prose h2{font-size:1.45em}
        #reader-document-summary .note-prose h3{font-size:1.25em}
        #reader-document-summary .note-prose :is(p,ul,ol,pre,table,blockquote){margin:0 0 1em}
        #reader-document-summary .note-prose :is(ul,ol){padding-inline-start:1.6em}
        #reader-document-summary .note-prose li+li{margin-block-start:.35em}
        #reader-document-summary .note-prose li>:is(ol,ul){margin:.3em 0}
        #reader-document-summary .note-prose blockquote{border-inline-start:2px solid var(--note-rule);padding-inline-start:1em}
        #reader-document-summary .note-prose blockquote>:last-child{margin-bottom:0}
        #reader-document-summary .note-prose :is(pre,table){display:block;max-width:100%;overflow-x:auto}
        #reader-document-summary .note-prose pre{padding:.7em 1em;background:var(--note-tint);border-radius:5px}
        #reader-document-summary .note-prose :is(pre,code){font: .9em/1.6 ui-monospace,monospace}
        #reader-document-summary .note-prose pre code{font:inherit}
        #reader-document-summary .note-prose table{border-collapse:collapse;font-variant-numeric:tabular-nums}
        #reader-document-summary .note-prose :is(th,td){border:1px solid var(--note-rule);padding:.3em .6em;text-align:start}
        #reader-document-summary .note-prose .note-math{display:inline-block;max-width:100%;overflow-x:auto;vertical-align:middle}
        #reader-document-summary .note-prose .note-math:has(math[display=block]){display:block;margin:1em 0;text-align:center}
        #reader-document-summary .note-prose math{margin:0}
        #reader-document-summary .note-prose hr{border:0;border-block-start:1px solid var(--note-rule);margin:1.5em 0}
        #reader-document-summary a[data-passage]{cursor:pointer;color:var(--note-accent);text-decoration:underline;text-underline-offset:.18em}
        """
}
