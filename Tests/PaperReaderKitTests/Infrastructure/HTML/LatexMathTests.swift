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
