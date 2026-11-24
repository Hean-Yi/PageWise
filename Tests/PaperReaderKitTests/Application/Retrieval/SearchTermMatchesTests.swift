import PaperReaderKit
import Testing

private func marked(_ text: String, by query: String?) -> [String] {
    SearchTermMatches.ranges(in: text, query: query).map { String(text[$0]) }
}

@Test func searchHighlightsCompoundsAcrossEditorialSpellingsAndMergesContiguousHits() {
    let title = "On‑Policy Self–Distillation, ON  POLICY, off-policy and work on learning"
    #expect(marked(title, by: "on-policy self-distillation") == ["On‑Policy Self–Distillation", "ON  POLICY"])
    #expect(
        marked("self-distillation; distillation", by: "distillation self-distillation distillation")
            == ["self-distillation", "distillation"])
}

@Test func searchHighlightsWholeLatinWordsAndPreservesOriginalGraphemes() {
    let authors = "René, Jose\u{301} García, ＪＯＳＥ"
    #expect(marked(authors, by: "jose garcia") == ["Jose\u{301} García", "ＪＯＳＥ"])
    #expect(
        marked("Policy vs. policymakers; off-policy 与Policy模型", by: "policy")
            == ["Policy", "policy", "Policy"])
    #expect(marked("基于自蒸馏的研究：从蒸馏出发。", by: "蒸馏") == ["蒸馏", "蒸馏"])
}

@Test func searchHighlightsTreatTechnicalTermsAndDOIsAsLiterals() {
    #expect(marked("C and C++ for RL, using C# tools", by: "C++") == ["C++"])
    #expect(
        marked("10.1234/Algo-2; Algo-2 baseline (10.1234)", by: "https://doi.org/10.1234/algo-2")
            == ["10.1234/Algo-2"])
    #expect(marked("RLHF; RL", by: "rl") == ["RL"])
    #expect(marked("Any title", by: nil).isEmpty)
    #expect(marked("Any title", by: "…-!?").isEmpty)
}
