#if os(macOS)
    import PaperReaderKit
    import Testing
    import WebKit

    @testable import PaperReaderUI

    @Test @MainActor func continuousPDFScrollPreservesTheVisibleSentenceWhenEarlierPagesGrowOrUnload() async throws {
        let paperID = UUID()
        var pages: [Int: PDFParagraphPage] = [:]
        var visiblePages: [Int] = []
        var originalPage: Int?
        var target = 1
        var revision = 0
        var outline: PaperNavigationItem?
        func page(_ index: Int, count: Int) -> PDFParagraphPage {
            let rows = (0..<count).map { number in
                let id = "p\(index)s\(number)"
                return PDFSourceSentence(
                    id: id, text: "A sentence about the figures in the appendix.", pageIndex: index,
                    rects: [], paragraphID: id, characterRanges: [NSRange(location: number * 100, length: 40)])
            }
            return PDFParagraphPage(
                index: index, sentences: rows, translations: [:], illustrations: [],
                notice: rows.isEmpty ? "本页为参考文献，保留原文。" : nil)
        }
        func canvas() -> PDFSentenceTextCanvas {
            PDFSentenceTextCanvas(
                sentences: [], translations: [:], layout: .paragraph, fontSize: 16, focusedID: nil,
                focusRevision: 0, followsScroll: false, sourceScrollID: nil, sourceScrollRevision: 0,
                pdfSelectedIDs: [], onScroll: { _ in }, onSelection: { _ in }, onFocus: { _ in },
                continuous: .init(
                    paperID: paperID, pageCount: 6, pages: pages, targetPage: target, jumpRevision: revision,
                    outlineItem: outline,
                    onVisiblePage: { visiblePages.append($0) }, onOpenOriginalPage: { originalPage = $0 }))
        }
        pages[0] = page(0, count: 8)
        pages[1] = page(1, count: 5)
        pages[2] = page(2, count: 7)
        let start = canvas()
        let coordinator = start.makeCoordinator()
        let web = coordinator.makeView()
        defer { coordinator.stop(web) }
        web.frame = CGRect(x: 0, y: 0, width: 450, height: 300)
        func evaluate(_ script: String) async throws -> Bool {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                == true
        }
        for _ in 0..<140 {
            if (try? await evaluate("return document.querySelectorAll('.source-page').length===6")) == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let startsAtCurrentPage = try await evaluate(
            """
            return Math.abs(document.querySelector('[data-page="1"]').getBoundingClientRect().top)<=2
              && document.querySelectorAll('.en').length===20
              && document.querySelector('[data-page="1"] .page-marker').textContent.includes('暂无译文')
              && !document.querySelector('[data-page="1"] .pending').getClientRects().length;
            """)
        #expect(startsAtCurrentPage)
        // Cross the source-page boundary with a scroll, without sending a native jump command.
        _ = try await evaluate(
            """
            const sentence=document.querySelector('.en[data-sentence=p2s2]');
            sentence.scrollIntoView({block:'start'});
            const text=sentence.firstChild;getSelection().setBaseAndExtent(text,2,text,10);
            window.readingSentence=sentence;window.readingTop=sentence.getBoundingClientRect().top;
            return true;
            """)
        for _ in 0..<120 where visiblePages.last != 2 { try await Task.sleep(for: .milliseconds(15)) }
        #expect(visiblePages.last == 2)
        let en = try #require(pages[0]?.sentences)
        pages[0]?.translations = Dictionary(
            uniqueKeysWithValues: en.map { ($0.id, String(repeating: "已翻译的长句。", count: 18)) })
        coordinator.update(canvas(), view: web)
        let staysPut = try await evaluate(
            """
            const y=window.readingSentence.getBoundingClientRect().top;
            window.measured=document.querySelector('[data-page="0"]').getBoundingClientRect().height;
            return Math.abs(y-window.readingTop)<=2 && getSelection().toString()==='sentence'
              && document.querySelector('.en[data-sentence=p2s2]')===window.readingSentence;
            """)
        #expect(staysPut)
        pages[0] = nil
        coordinator.update(canvas(), view: web)
        let recycled = try await evaluate(
            """
            const section=document.querySelector('[data-page="0"]');
            return !section.querySelector('.en') && Math.abs(section.getBoundingClientRect().height-window.measured)<=2
              && Math.abs(window.readingSentence.getBoundingClientRect().top-window.readingTop)<=2;
            """)
        #expect(recycled)
        pages = [4: page(4, count: 5), 5: page(5, count: 0)]
        target = 4
        revision += 1
        coordinator.update(canvas(), view: web)
        let jumps = try await evaluate(
            """
            const page=document.querySelector('[data-page="4"]');
            window.webkit.messageHandlers.sentence.postMessage({action:'viewport',paper: '\(paperID.uuidString)',revision:0,page:0});
            window.scrollTo(0,document.documentElement.scrollHeight);
            document.querySelector('[data-original="5"]').click();
            return !!page.querySelector('.en') && !document.querySelector('.en[data-sentence=p2s2]');
            """)
        #expect(jumps)
        for _ in 0..<120 where visiblePages.last != 5 || originalPage != 5 {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(visiblePages.last == 5)
        #expect(!visiblePages.contains(0))
        #expect(originalPage == 5)

        // Select a subsection before its PDF page has been extracted, then another on the same page.
        target = 3
        for number in [5, 9] {
            outline = PaperNavigationItem(
                id: "chapter-\(number)", title: "Methods", sourcePage: target, depth: 1, isOutline: true,
                sourceRange: NSRange(location: number * 100 + 2, length: 7))
            revision += 1
            coordinator.update(canvas(), view: web)
            if pages[target] == nil {
                pages[target] = page(target, count: 18)
                coordinator.update(canvas(), view: web)
            }
            #expect(
                try await evaluate(
                    "return Math.abs(document.querySelector('.en[data-sentence=p3s\(number)]').getBoundingClientRect().top)<3"
                ))
        }
    }
#endif
