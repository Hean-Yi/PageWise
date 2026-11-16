import CoreGraphics
import CoreText
import Foundation
import PaperReaderKit

/// Original, offline fixture for inspecting the real application's TeX-derived HTML.
enum TeXPreviewSmoke {
    @MainActor static func run(root: URL) async throws {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path) else {
            throw ReaderError.message("验收目录已有书库，请使用新的隔离目录。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = #"""
            \documentclass{article}
            \newcommand{\vect}[1]{\mathbf{#1}}
            \title{TeX Source Reading - Original Offline Fixture}
            \begin{document}
            \maketitle
            \begin{abstract}
            This original fixture verifies paragraphs, mathematics, figures and tables.
            The Chinese text is a local layout fixture, not a model response.
            \end{abstract}
            \section{Stable paragraphs}
            A complete paragraph comes directly from the source. Its inline formula is
            $\vect{y}=\vect{x}+1$. No PDF line joining is needed.

            The next paragraph keeps its own source identity. Figure~\ref{fig:flow}
            illustrates the route from source evidence to bilingual reading.
            \begin{equation}\label{eq:sum} s = \sum_{i=1}^{n} x_i \end{equation}
            \begin{figure}
            \includegraphics{flow.svg}
            \caption{Original source evidence and validated reading blocks.}
            \label{fig:flow}
            \end{figure}
            \section{Preserved table}
            \begin{table}
            \caption{Original fixture values; this table is not translated.}
            \begin{tabular}{lr}
            \toprule
            Item & Value \\
            \midrule
            Sources & 3 \\
            Blocks & 3 \\
            \bottomrule
            \end{tabular}
            \end{table}
            \end{document}
            """#
        let svg = #"""
            <svg xmlns="http://www.w3.org/2000/svg" width="520" height="110" viewBox="0 0 520 110">
            <rect x="8" y="20" width="180" height="68" rx="12" fill="#e8dfd1"/>
            <rect x="328" y="20" width="180" height="68" rx="12" fill="#e4ece3"/>
            <path d="M205 54 H310 M298 42 L310 54 L298 66" fill="none" stroke="#966044" stroke-width="3"/>
            <text x="98" y="59" text-anchor="middle" font-size="18">TeX source</text>
            <text x="418" y="59" text-anchor="middle" font-size="18">Reading blocks</text>
            </svg>
            """#
        let archive = tar([("main.tex", Data(source.utf8)), ("flow.svg", Data(svg.utf8))])
        let blocks = try await TeXPaperParser().parse(archive)
        // A one-page original fixture, independent of the application's reading generator.
        let pdf = root.appendingPathComponent("Original Fixture.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(pdf as CFURL, mediaBox: &bounds, nil) else {
            throw ReaderError.message("无法生成离线 PDF 样例。")
        }
        context.beginPDFPage(nil)
        let text = NSAttributedString(
            string: blocks.map(\.text).joined(separator: "\n\n"),
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString, 10, nil)
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(), CGPath(rect: bounds.insetBy(dx: 40, dy: 40), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        var paper = try await PDFImporter(root: root).storeOriginal(at: pdf)
        let candidate = PaperCandidate(
            id: "https://arxiv.org/abs/0000.00000v1", title: "TeX 重排 · 原创离线验收", authors: "Fixture", year: "2026",
            pdfURL: URL(string: "https://arxiv.org/pdf/0000.00000v1")!)
        paper.title = candidate.title
        paper = try await OnlineSourceStore().attach(
            DownloadedPublication(pdfURL: pdf, candidate: candidate, texArchive: archive), to: paper, root: root)
        let evidence = try await OnlineSourceStore().prepare(paper: paper, root: root)
        guard evidence.route == "tex" else { throw ReaderError.message("原创样例未使用 TeX。") }
        paper.blocks = evidence.blocks
        paper.reflowJob = ReflowJob(sources: evidence.blocks)
        paper.reflowJob?.evidenceRoute = "tex"
        paper.reflowJob?.finished = true
        paper.reflowJob?.hasPresentedContent = true
        let pairs = evidence.blocks.map { block -> BilingualBlock in
            guard let rich = block.richContent, rich.requiresTranslation else {
                return BilingualBlock(block: block, translation: nil)
            }
            let markers = rich.mathematics.keys.sorted().joined(separator: " ")
            let translation = "原创离线排版测试（非模型输出）：正文按完整段落呈现，公式与图片保留，来源位置稳定。" + markers
            paper.translations[block.id.uuidString] = rich.readableTranslation(translation)
            return BilingualBlock(block: block, translation: translation)
        }
        paper.htmlReading = try await HTMLReadingStore().append(pairs, to: nil, paper: paper, root: root)
        paper.translatedBlockCount = paper.blocks.count
        for index in paper.blocks.indices { paper.blocks[index].richContent = nil }
        var state = LibraryState()
        state.papers = [paper]
        try await LibraryStore(directory: root).save(state)
        let loaded = try await LibraryStore(directory: root).load()
        guard loaded.papers.first?.htmlReading == paper.htmlReading,
            try Data(contentsOf: pdf) == Data(contentsOf: root.appendingPathComponent(paper.originalPath))
        else {
            throw ReaderError.message("重启内容或原版完整性验证失败。")
        }
        let note = try NoteMerger.merge(existing: "# 用户笔记\n自己的观点应保留。", body: "离线验收", paperID: paper.id, baseline: nil)
        guard note.text.contains("自己的观点应保留。") else { throw ReaderError.message("笔记保留验证失败。") }
        print("PASS: TeX source, protected mathematics, localized image, preserved table, persisted reading")
        print("Isolated library: \(root.path)")
    }

    private static func tar(_ files: [(String, Data)]) -> Data {
        var result = Data()
        for (path, data) in files {
            var header = [UInt8](repeating: 0, count: 512)
            func write(_ text: String, at offset: Int) {
                for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
            }
            write(path, at: 0)
            write(String(format: "%011o", data.count), at: 124)
            header[156] = 48
            write("ustar", at: 257)
            for index in 148..<156 { header[index] = 32 }
            write(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148)
            header[154] = 0
            result.append(contentsOf: header)
            result.append(data)
            result.append(Data(repeating: 0, count: (512 - data.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1_024))
        return result
    }
}
