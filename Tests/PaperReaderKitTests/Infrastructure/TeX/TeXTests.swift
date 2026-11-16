import Foundation
import Testing
import zlib

@testable import PaperReaderKit

private func sourceTar(_ files: [(String, Data)], type: UInt8 = 48) -> Data {
    var result = Data()
    for (name, bytes) in files {
        var header = [UInt8](repeating: 0, count: 512)
        func write(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
        }
        write(name, at: 0)
        write(String(format: "%011o", bytes.count), at: 124)
        header[156] = type
        write("ustar", at: 257)
        for index in 148..<156 { header[index] = 32 }
        write(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148)
        header[154] = 0
        result.append(contentsOf: header)
        result.append(bytes)
        result.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
    }
    result.append(Data(repeating: 0, count: 1_024))
    return result
}

private func gzipFixture(_ data: Data) throws -> Data {
    var stream = z_stream()
    #expect(
        deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { deflateEnd(&stream) }
    var output = [UInt8](repeating: 0, count: data.count * 2 + 1_024)
    let capacity = output.count
    let count = try data.withUnsafeBytes { input in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(data.count)
        return try output.withUnsafeMutableBytes { buffer in
            stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(capacity)
            try #require(deflate(&stream, Z_FINISH) == Z_STREAM_END)
            return capacity - Int(stream.avail_out)
        }
    }
    return Data(output.prefix(count))
}

private let sourceMain = #"""
    \documentclass{article}
    \newcommand{\method}[1]{\textbf{#1}}
    \newcommand{\vect}[1]{\mathbf{#1}}
    \title{Original TeX Reading Fixture}
    \author{Fixture Author}
    \begin{document}
    \maketitle
    \begin{abstract}
    This original fixture describes \method{stable evidence} with $\vect{x}+1$.
    \end{abstract}
    \input{sections/body}
    \begin{figure}
    \centering
    \includegraphics[width=\linewidth]{plot.svg}
    \caption{An original rectangular diagram.}
    \label{fig:plot}
    \end{figure}
    \begin{table}
    \caption{Original measurements.}
    \begin{tabular}{lr}
    \toprule
    Method & Value \\
    \midrule
    Example & $2$ \\
    \bottomrule
    \end{tabular}
    \end{table}
    \begin{thebibliography}{9}
    \bibitem{fixture} A. Author. An original reference.
    \end{thebibliography}
    \end{document}
    """#

private func sourceFixture() -> Data {
    sourceTar([
        ("main.tex", Data(sourceMain.utf8)),
        (
            "sections/body.tex",
            Data(
                #"""
                \section{Evidence}\label{sec:evidence}
                The first complete paragraph has a reference to Figure~\ref{fig:plot} and \cite{fixture}.

                The next paragraph retains the exact source order.
                \begin{equation}\label{eq:test} y = x^2 + 1 \end{equation}
                We refer to Equation~\eqref{eq:test}.
                \begin{verbatim}
                \input{not-a-real-file} % keep this code as text
                \end{verbatim}
                """#.utf8)
        ),
        (
            "plot.svg",
            Data(
                #"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="blue"/></svg>"#
                    .utf8)
        ),
    ])
}

@Test func texArchiveReadsGzipTarAndSingleSourceWithoutFilesystemExtraction() throws {
    let archive = sourceFixture()
    let plain = try TeXArchive.unpack(archive)
    let compressed = try TeXArchive.unpack(gzipFixture(archive))
    #expect(plain == compressed)
    #expect(plain.count == 3)
    let single = Data(#"\documentclass{article}\begin{document}Original text.\end{document}"#.utf8)
    #expect(try TeXArchive.unpack(gzipFixture(single))["main.tex"] == single)
    var broken = try gzipFixture(single)
    broken.removeLast(3)
    #expect(throws: (any Error).self) { try TeXArchive.unpack(broken) }
}

@Test(arguments: ["../escape.tex", "/absolute.tex", "safe/../../escape.tex", "a\\b.tex"])
func texArchiveRejectsUnsafePaths(_ path: String) {
    #expect(throws: (any Error).self) { try TeXArchive.unpack(sourceTar([(path, Data("test".utf8))])) }
}

@Test func texArchiveRejectsLinksDuplicatesAndBrokenChecksums() {
    let file = ("main.tex", Data(sourceMain.utf8))
    #expect(throws: (any Error).self) { try TeXArchive.unpack(sourceTar([file], type: 50)) }
    #expect(throws: (any Error).self) { try TeXArchive.unpack(sourceTar([file, file])) }
    var corrupt = sourceTar([file])
    corrupt[0] = 0
    #expect(throws: (any Error).self) { try TeXArchive.unpack(corrupt) }
}

@Test func texParserPreservesParagraphsFormulaAssetsReferencesAndStableSourceIdentity() async throws {
    let source = sourceFixture()
    let blocks = try await TeXPaperParser().parse(source)
    let repeated = try await TeXPaperParser().parse(source)
    #expect(blocks.map(\.id) == repeated.map(\.id))
    #expect(blocks.allSatisfy { $0.sourcePage == -1 && $0.texSource?.archiveDigest == TeXPaperParser.digest(source) })
    let first = try #require(blocks.first { $0.text.contains("first complete paragraph") })
    let next = try #require(blocks.first { $0.text.contains("next paragraph") })
    #expect(first.id != next.id)
    #expect(first.richContent?.html.contains("href=\"#ref-tex-") == true)
    #expect(blocks.contains { $0.richContent?.mathematics.isEmpty == false })
    let figure = try #require(blocks.first { $0.richContent?.isFigure == true })
    #expect(figure.richContent?.html.contains("data:image/") == true)
    #expect(figure.richContent?.figureCaption?.text == "An original rectangular diagram.")
    let table = try #require(blocks.first { $0.richContent?.html.contains("<table") == true })
    #expect(table.richContent?.requiresTranslation == false)
    let bibliography = try #require(blocks.first { $0.text.contains("An original reference") })
    #expect(bibliography.richContent?.requiresTranslation == false)
    let code = try #require(blocks.first { $0.text.contains("not-a-real-file") })
    #expect(code.text.contains("% keep this code as text"))
    #expect(code.richContent?.requiresTranslation == false)
}

@Test(arguments: [
    #"\unknowncommand{do not drop me}"#, #"\input{missing}"#, #"\ref{missing}"#,
    #"\begin{tikzpicture}not rendered\end{tikzpicture}"#,
    #"\newcommand{\loop}{\loop}\loop"#,
])
func texParserRejectsUnresolvedContentBeforePublishing(_ body: String) async throws {
    let source = Data((#"\documentclass{article}\begin{document}"# + body + #"\end{document}"#).utf8)
    await #expect(throws: (any Error).self) { try await TeXPaperParser().parse(source) }
}

@Test func texParserRejectsIncludeCyclesAndMultipleRoots() async throws {
    let cycle = sourceTar([
        ("main.tex", Data(#"\documentclass{article}\begin{document}\input{loop}\end{document}"#.utf8)),
        ("loop.tex", Data(#"\input{loop}"#.utf8)),
    ])
    await #expect(throws: (any Error).self) { try await TeXPaperParser().parse(cycle) }
    let roots = sourceTar([("one.tex", Data(sourceMain.utf8)), ("two.tex", Data(sourceMain.utf8))])
    await #expect(throws: (any Error).self) { try await TeXPaperParser().parse(roots) }
}

private actor SourceFallbackDiscovery: PaperDiscovery {
    var htmlRequests = 0
    let html: [TextBlock]?
    init(html: [TextBlock]? = nil) { self.html = html }
    func search(_ query: String) async throws -> [PaperCandidate] { [] }
    func download(_ candidate: PaperCandidate) async throws -> URL { throw CancellationError() }
    func structuredContent(_ candidate: PaperCandidate) async throws -> [TextBlock]? {
        htmlRequests += 1
        return html
    }
}

@Test func onlineSourceUsesTeXBeforeHTMLAndFallsBackWithoutMixingBody() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let paper = try await PDFImporter(root: root).storeOriginal(at: pdf)
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Original fixture", authors: "", year: "",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1")!)
    let sourceStore = OnlineSourceStore()
    let attached = try await sourceStore.attach(
        DownloadedPublication(pdfURL: pdf, candidate: candidate, texArchive: sourceFixture()), to: paper, root: root)
    let discovery = SourceFallbackDiscovery(html: [TextBlock(sourcePage: -1, text: "HTML fallback")])
    let evidence = try await sourceStore.prepare(paper: attached, root: root, discovery: discovery)
    #expect(evidence.route == "tex")
    #expect(await discovery.htmlRequests == 0)
    #expect(!evidence.blocks.contains { $0.text == "HTML fallback" })
    var noSource = attached
    noSource.onlineSource?.archivePath = nil
    let html = try await sourceStore.prepare(paper: noSource, root: root, discovery: discovery)
    #expect(html.route == "html")
    #expect(html.blocks.map(\.text) == ["HTML fallback"])
    let fallback = try await sourceStore.prepare(paper: noSource, root: root, discovery: SourceFallbackDiscovery())
    #expect(fallback.route == "pdf" && fallback.blocks.isEmpty)
    #expect(!fallback.warnings.isEmpty)
    try Data("changed".utf8).write(to: root.appendingPathComponent(paper.originalPath))
    await #expect(throws: (any Error).self) {
        try await sourceStore.prepare(paper: attached, root: root, discovery: discovery)
    }
}
