import Foundation
import Testing

@testable import PaperReaderKit

@Test(arguments: [
    (
        #"\mathcal{L}_{\mathrm{OPD}}=\sum_t D\!\left(\pi_T(\cdot\mid x,c,y_{<t}),\pi_S(\cdot\mid x,y_{<t})\right)."#,
        "munder"
    ),
    (#"\frac{\partial f}{\partial x}+\sqrt{x^2+1}"#, "mfrac"),
    (#"\begin{aligned}a&=b+c\\d&=e-f\end{aligned}"#, "mtable"),
    (#"\begin{bmatrix}1&0\\0&1\end{bmatrix}"#, "mtable"),
])
func latexCompilesToStructuredMathML(latex: String, element: String) throws {
    let compiled = try LatexMathCompiler().compile(latex, display: true)
    #expect(compiled.contains("<math"))
    #expect(compiled.contains("<\(element)"))
    #expect(compiled.contains("display=\"block\""))
    #expect(!compiled.contains("annotation"))
}

@Test(arguments: [#"\frac{1}{"#, #"\unknownMacro{x}"#, #"\def\x{\x}\x"#, #"\href{https://example.com}{x}"#])
func invalidOrUnsupportedLatexNeverPublishesAnIncorrectFormula(latex: String) throws {
    let compiler = try LatexMathCompiler()
    #expect(throws: (any Error).self) { try compiler.compile(latex, display: true) }
}

@Test func latexSourceBecomesProtectedTranslationMarkersAndCodeIsPreserved() async throws {
    let html =
        #"<article class='ltx_document'><h2>2 Setup</h2><p>Input \(x_i\) and $y_t$ remain selectable.</p><div>\[\frac{a}{b}=\sum_{t=1}^n t\]</div><pre>literal \(x_i\)</pre><p>Prices are $5 and $10.</p></article>"#
    let blocks = try await HTMLPaperParser().parse(
        Data(html.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    #expect(blocks[1].richContent?.mathematics.count == 2)
    #expect(blocks[1].richContent?.translationInput.contains("[[MATH_1]]") == true)
    #expect(blocks[2].richContent?.requiresTranslation == false)
    #expect(blocks[2].richContent?.html.contains("mfrac") == true)
    #expect(blocks[3].richContent?.html.contains(#"\(x_i\)"#) == true)
    #expect(blocks.last?.text.contains("$5 and $10") == true)
    await #expect(throws: (any Error).self) {
        try await HTMLPaperParser().parse(
            Data(#"<article class='ltx_document'><p>\(\invalidCommand\)</p></article>"#.utf8),
            at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    }
}

@Test func layoutOnlyWrapfloatErrorRetainsAlgorithmLinesAndMath() async throws {
    let html =
        #"<article class='ltx_document'><p>Before.</p><div class='ltx_para'><span class='ltx_ERROR'>{wrapfloat}</span><p>algorithmR0.65<span>Original algorithm</span></p><div class='ltx_listing'><div class='ltx_listingline'>1: Start \(x_i\)</div><div class='ltx_listingline'>2: Update \(x_{i+1}\)</div></div></div><p>After.</p></article>"#
    let blocks = try await HTMLPaperParser().parse(
        Data(html.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    #expect(blocks.count == 4)
    #expect(blocks[1].text == "Original algorithm")
    #expect(blocks[2].richContent?.requiresTranslation == false)
    #expect(blocks[2].richContent?.mathematics.count == 2)
    #expect(blocks[2].richContent?.html.contains("1: Start") == true)
    #expect(blocks[2].richContent?.html.contains("2: Update") == true)
    #expect(!blocks.map(\.text).joined().contains("wrapfloat"))
    await #expect(throws: (any Error).self) {
        try await HTMLPaperParser().parse(
            Data(
                "<article class='ltx_document'><span class='ltx_ERROR'>{wrapfloat}</span><p>Missing listing</p></article>"
                    .utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    }
}

@Test func authorMetadataBecomesCompactHTMLInsteadOfManyTranslationRequests() async throws {
    let html =
        "<article class='ltx_document'><h1>Title</h1><div class='ltx_authors'><span class='ltx_creator'><span class='ltx_personname'>First Author</span><span class='ltx_contact'>Original Institute</span></span><span class='ltx_creator'><span class='ltx_personname'>Second Author</span><span class='ltx_note'>Equal contribution</span></span></div><p>Actual paragraph.</p></article>"
    let blocks = try await HTMLPaperParser().parse(
        Data(html.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    #expect(blocks.count == 3)
    let authors = try #require(blocks[1].richContent)
    #expect(!authors.requiresTranslation)
    #expect(authors.html.contains("paper-authors"))
    #expect(authors.html.contains("<details>"))
    #expect(authors.html.contains("Original Institute"))
    #expect(authors.html.contains("Equal contribution"))
}

@Test func referencesKeepLocalTargetsAndStandaloneEquationsSkipTranslation() async throws {
    let html =
        #"<article class='ltx_document'><section id='S1'><h2>Setup</h2><p>See <a href='#bib.item'>citation</a> and <a href='https://example.com/paper'>source</a>. <a href='javascript:bad()'>Unsafe</a></p><table class='ltx_equation' id='Eq1'><tr><td><math display='block'><mi>x</mi></math></td><td>(1)</td></tr></table></section><ul><li id='bib.item'>Original reference</li></ul></article>"#
    let blocks = try await HTMLPaperParser().parse(
        Data(html.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    let rendered = blocks.compactMap(\.richContent?.html).joined()
    #expect(rendered.contains("id=\"ref-S1\""))
    #expect(rendered.contains("href=\"#ref-bib.item\""))
    #expect(rendered.contains("id=\"ref-bib.item\""))
    #expect(rendered.contains("https://example.com/paper"))
    #expect(!rendered.contains("javascript:"))
    #expect(blocks[2].richContent?.requiresTranslation == false)
}

@Test func tablesStayOriginalAndEachFigurePanelKeepsItsOwnCaption() async throws {
    let source =
        "<article class='ltx_document'><figure class='ltx_table'><figcaption>Table 1: Results</figcaption><table><tr><th>Model</th><td><math><mn>99</mn></math></td></tr></table></figure><table><tr><td>Standalone table</td></tr></table><figure id='F1'><figure><figcaption>Panel A</figcaption></figure><figure><figcaption>Panel B</figcaption></figure><figcaption>Figure 1: Comparison</figcaption></figure><p>After figures.</p></article>"
    let blocks = try await HTMLPaperParser().parse(
        Data(source.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
    #expect(blocks.count == 6)
    #expect(blocks[0].richContent?.requiresTranslation == false)
    #expect(blocks[1].richContent?.requiresTranslation == false)
    #expect(blocks[0].richContent?.html.contains("<table>") == true)
    #expect(blocks[2].richContent?.translationInput == "Panel A")
    #expect(blocks[3].richContent?.translationInput == "Panel B")
    #expect(blocks[4].richContent?.translationInput == "Figure 1: Comparison")
}
