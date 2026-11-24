#if os(macOS)
    import AppKit
    import CoreText
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func continuousPDFTablePreservesMathAndCopiesSelectedCellsDuringTranslation() async throws {
        let paperID = UUID()
        let sentences = ["Before the table.", "After the table."].enumerated().map { index, text in
            PDFSourceSentence(id: "s\(index)", text: text, pageIndex: 0, rects: [], paragraphID: "p")
        }
        let table = PDFReadingTable(
            header: ["Parameter", "Value"], rows: [["H_{KV}", "10⁻⁶"], ["Count", "24"]],
            styledCells: [
                .init(
                    row: 1, column: 0, runs: [.init(text: "H", italic: true), .init(text: "KV", baseline: .subscript)]),
                .init(row: 1, column: 1, runs: [.init(text: "10"), .init(text: "−6", baseline: .superscript)]),
                .init(row: 2, column: 1, runs: [.init(text: "24", bold: true)]),
            ])
        let illustration = PDFReadingIllustration(
            id: "parameters", label: "表 1", pageIndex: 0, sourceBounds: CGRect(x: 36, y: 150, width: 260, height: 75),
            insertBeforeSentenceID: "s1", imagePNG: nil, table: table)
        var page = PDFParagraphPage(
            index: 0, sentences: sentences, translations: [:], illustrations: [illustration], notice: nil)
        var revealed: [PDFReadingIllustration] = []
        var openedPages: [Int] = []
        func canvas() -> PDFSentenceTextCanvas {
            tableCanvas(
                paperID: paperID, page: page, onReveal: { revealed.append($0) }, onOpen: { openedPages.append($0) })
        }
        let coordinator = canvas().makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        func evaluate(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        try await waitForReadingTable(in: web)
        let inParagraph = try await evaluate(
            """
            const figure = document.querySelector('figure'), table = figure.querySelector('table');
            return !figure.querySelector('.source-table')
                && figure.previousElementSibling.querySelector('.en').dataset.sentence === 's0'
                && figure.nextElementSibling.querySelector('.en').dataset.sentence === 's1'
                && [...table.tHead.rows[0].cells].every(cell => cell.tagName === 'TH' && cell.scope === 'col')
                && table.querySelector('sub').textContent === 'KV' && table.querySelector('sup').textContent === '−6'
                && table.querySelector('em').textContent === 'H' && table.querySelector('strong').textContent === '24';
            """)
        #expect(inParagraph)
        let selected = try await evaluate(
            """
            const table = document.querySelector('table'), first = table.querySelector('em').firstChild;
            const last = table.querySelector('strong').firstChild;
            first.parentElement.click();
            getSelection().setBaseAndExtent(first,0,last,last.length);
            window.tableEndpoints = [first,last];
            document.querySelector('.table-title').dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
            return !getSelection().isCollapsed;
            """)
        #expect(selected)

        page.translations["s0"] = "表格之前。"
        coordinator.update(canvas(), view: web)
        let preserved = try await evaluate(
            """
            const [first,last] = window.tableEndpoints, selected = getSelection();
            return document.querySelector('.zh[data-sentence="s0"]').textContent === '表格之前。'
                && selected.anchorNode === first && selected.anchorOffset === 0
                && selected.focusNode === last && selected.focusOffset === last.length;
            """)
        #expect(preserved)
        let copied =
            try await web.callAsyncJavaScript(
                """
                const clipboard = new DataTransfer();
                document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:clipboard,cancelable:true}));
                return clipboard.getData('text/plain');
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        #expect(copied == "H_{KV}\t10⁻⁶\nCount\t24")

        // The caption is still an explicit source link after the reader clears their selection.
        #expect(revealed.isEmpty)
        _ = try await evaluate(
            "getSelection().removeAllRanges(); document.querySelector('.table-title').click(); return true;")
        for _ in 0..<60 where revealed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(revealed == [illustration])
        #expect(openedPages.isEmpty)
    }

    @Test @MainActor func continuousPDFTableCopiesMergedHeadersAtTheirOriginalColumns() async throws {
        let bounds = CGRect(x: 36, y: 150, width: 392, height: 72)
        func cellBounds(_ row: Int, _ column: Int, span: Int = 1) -> CGRect {
            CGRect(
                x: bounds.minX + CGFloat(column * 56 + 2), y: bounds.maxY - CGFloat(row * 18 + 15),
                width: CGFloat(span * 56 - 4), height: 12)
        }
        let lengths: [PDFReadingTable.HeaderCell] = (1...6).map { column in
            switch (column - 1) % 3 {
            case 0: .init(text: "1K", column: column)
            case 1: .init(text: "2K", column: column)
            default:
                .init(text: "4K†", column: column, runs: [.init(text: "4K"), .init(text: "†", baseline: .superscript)])
            }
        }
        let rows = [
            ["Standard", "0.879", "0.713", "0.553", "0.862", "0.918", "0.326"],
            ["MA", "1.000", "0.981", "0.630", "0.950", "1.000", "0.687"],
        ]
        let cellRects = [
            [cellBounds(0, 0).offsetBy(dx: 0, dy: -8), cellBounds(0, 1, span: 3), cellBounds(0, 4, span: 3)],
            (1...6).map { cellBounds(1, $0) },
            (0...6).map { cellBounds(2, $0) },
            (0...6).map { cellBounds(3, $0) },
        ]
        let table = PDFReadingTable(
            header: ["Variant", "1K", "2K", "4K†", "1K", "2K", "4K†"], rows: rows,
            styledCells: [
                .init(row: 0, column: 3, runs: lengths[2].runs),
                .init(row: 2, column: 1, runs: [.init(text: "1.000", bold: true)]),
            ],
            headerRows: [
                [
                    .init(text: "Variant", column: 0, rowSpan: 2),
                    .init(text: "niah_single_1", column: 1, columnSpan: 3),
                    .init(text: "niah_single_2", column: 4, columnSpan: 3),
                ],
                lengths,
            ], sourceCellBounds: cellRects)
        let imageRows = [["Variant", "niah_single_1", "niah_single_2"], lengths.map(\.text)] + rows
        let png = try tableImage(in: bounds, contents: imageRows, cellRects: cellRects)
        let item = PDFReadingIllustration(
            id: "niah", label: "表 3", pageIndex: 0, sourceBounds: bounds,
            insertBeforeSentenceID: nil, imagePNG: png, table: table)
        let page = PDFParagraphPage(index: 0, sentences: [], translations: [:], illustrations: [item], notice: nil)
        let coordinator = tableCanvas(paperID: UUID(), page: page).makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        try await waitForReadingTable(in: web)
        let geometry =
            try await web.callAsyncJavaScript(
                """
                const source=document.querySelector('.source-table'), image=source.querySelector(':scope > img');
                await image.decode();
                const table=source.querySelector('table'), head=table.tHead, body=table.tBodies[0];
                const top=[...head.rows[0].cells], leaves=[...head.rows[1].cells];
                const cell=body.rows[1].cells[1], art=image.getBoundingClientRect(), score=cell.getBoundingClientRect();
                const caret=document.caretRangeFromPoint(score.x+score.width*.5,score.y+score.height*.4);
                return {
                  image: image.naturalWidth===392 && image.naturalHeight===72 && art.width>0 && art.height>0,
                  x: Math.abs((score.left-art.left)/art.width-58/392)<0.005,
                  y: Math.abs((score.top-art.top)/art.height-57/72)<0.01,
                  shape: head.rows.length===2 && top.length===3 && leaves.length===6,
                  variant: top[0].tagName==='TH' && top[0].textContent==='Variant' && top[0].rowSpan===2,
                  groups: top.slice(1).every((cell,i) => cell.tagName==='TH' && cell.colSpan===3 && cell.scope==='colgroup'
                        && cell.textContent==='niah_single_'+(i+1)),
                  leaves: leaves.every(cell => cell.tagName==='TH' && cell.scope==='col')
                      && leaves[2].textContent==='4K†' && leaves[5].textContent==='4K†',
                  score: cell.textContent==='1.000',
                  selectsScore: caret?.startContainer.nodeType===Node.TEXT_NODE && cell.contains(caret.startContainer)
                };
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Bool]
        let checks = try #require(geometry)
        #expect(checks.filter { !$0.value }.keys.sorted().isEmpty)

        func copiedContents(of selector: String) async throws -> String? {
            try await web.callAsyncJavaScript(
                """
                const range=document.createRange(), selection=getSelection();
                range.selectNodeContents(document.querySelector(selector));
                selection.removeAllRanges();selection.addRange(range);
                const clipboard=new DataTransfer();
                document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:clipboard,cancelable:true}));
                return clipboard.getData('text/plain');
                """, arguments: ["selector": selector], in: nil, contentWorld: .defaultClient) as? String
        }
        let headers = try await copiedContents(of: "thead")
        #expect(headers == "Variant\tniah_single_1\t\t\tniah_single_2\t\t\n\t1K\t2K\t4K†\t1K\t2K\t4K†")
        let groupTitles = try await copiedContents(of: "thead tr:first-child")
        #expect(groupTitles == "Variant\tniah_single_1\t\t\tniah_single_2\t\t")
        let values = try await copiedContents(of: "tbody")
        #expect(
            values == "Standard\t0.879\t0.713\t0.553\t0.862\t0.918\t0.326\nMA\t1.000\t0.981\t0.630\t0.950\t1.000\t0.687"
        )
    }

    @Test @MainActor func overflowingTableCanBeNavigatedAndCopiedWithoutLosingReadingPosition() async throws {
        let titles = (1...8).map { "Measurement-\($0)" }
        let values = ["1.00", "", "0.03", "5", "0.00", "A \"score\"", "", ""]
        let clipboardRow = "1.00\t\t0.03\t5\t0.00\t\"A \"\"score\"\"\"\t\t"
        let table = PDFReadingTable(header: titles, rows: [values])
        let figure = PDFReadingIllustration(
            id: "wide", label: "表 B.2", pageIndex: 0, sourceBounds: .zero,
            insertBeforeSentenceID: nil, imagePNG: nil, table: table)
        let page = PDFParagraphPage(index: 0, sentences: [], translations: [:], illustrations: [figure], notice: nil)
        var copied: String?
        var canvas = tableCanvas(paperID: UUID(), page: page)
        canvas.copyTableText = {
            copied = $0
            return true
        }
        let coordinator = canvas.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        try await waitForReadingTable(in: web)
        let narrow = try await web.callAsyncJavaScript(
            """
            const scroller=document.querySelector('.table-scroll'), arrows=document.querySelectorAll('.table-step');
            const range=document.createRange();range.selectNodeContents(document.querySelector('tbody'));
            getSelection().removeAllRanges();getSelection().addRange(range);
            const clip=new DataTransfer();
            document.dispatchEvent(new ClipboardEvent('copy',{clipboardData:clip,cancelable:true}));
            const result=[!arrows[1].hidden && !arrows[1].disabled && arrows[0].disabled,
              scroller.scrollWidth>scroller.clientWidth && document.documentElement.scrollWidth<=innerWidth,
              clip.getData('text/plain')===expected];
            getSelection().removeAllRanges();scroller.scrollLeft=scroller.scrollWidth;
            scroller.dispatchEvent(new Event('scroll'));result.push(arrows[1].disabled && !arrows[0].disabled);
            document.querySelector('[data-copy-table]').click();
            return result;
            """, arguments: ["expected": clipboardRow], in: nil, contentWorld: .defaultClient)
        #expect(narrow as? [Bool] == [true, true, true, true])
        for _ in 0..<60 where copied == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(copied == titles.joined(separator: "\t") + "\n" + clipboardRow)
        let label = try await web.callAsyncJavaScript(
            "return document.querySelector('[data-copy-table]').textContent",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        #expect(label as? String == "已复制")
    }

    @MainActor private func tableImage(in bounds: CGRect, contents: [[String]], cellRects: [[CGRect]]) throws -> Data {
        let bitmap = try #require(
            CGContext(
                data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
        bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(bounds)
        for (row, values) in contents.enumerated() {
            let font = row == 3 ? NSFont.boldSystemFont(ofSize: 10) : NSFont.systemFont(ofSize: 10)
            for (column, text) in values.enumerated() {
                let rect = cellRects[row][column]
                bitmap.textPosition = CGPoint(x: rect.minX, y: rect.minY + 2)
                CTLineDraw(
                    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])),
                    bitmap)
            }
        }
        let image = try #require(bitmap.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    @MainActor private func tableCanvas(
        paperID: UUID, page: PDFParagraphPage, onReveal: @escaping (PDFReadingIllustration) -> Void = { _ in },
        onOpen: @escaping (Int) -> Void = { _ in }
    ) -> PDFSentenceTextCanvas {
        PDFSentenceTextCanvas(
            sentences: [], translations: [:], layout: .paragraph, fontSize: 16, onSelection: { _ in },
            onRevealIllustration: onReveal,
            continuous: .init(
                paperID: paperID, pageCount: 1, pages: [0: page], targetPage: 0, jumpRevision: 0,
                onVisiblePage: { _ in }, onOpenOriginalPage: onOpen))
    }

    @MainActor private func waitForReadingTable(in web: WKWebView) async throws {
        for _ in 0..<160 {
            let ready =
                try? await web.callAsyncJavaScript(
                    "return !!document.querySelector('tbody')", arguments: [:], in: nil, contentWorld: .defaultClient)
                as? Bool
            if ready == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The PDF reading table did not appear.")
    }
#endif
