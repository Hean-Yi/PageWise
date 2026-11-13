import CoreGraphics
import CoreText
import Foundation

/// Original, self-contained teaching material. It is not an imported or attributed research paper.
public enum DemoPaper {
    public static func write(to url: URL) throws {
        guard let data = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: data) else {
            throw ReaderError.message("无法创建示例论文。")
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info =
            [kCGPDFContextTitle: "Understanding Attention", kCGPDFContextAuthor: "PaperReader Original Teaching Notes"]
            as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &box, info) else {
            throw ReaderError.message("无法创建示例 PDF。")
        }

        context.beginPDFPage(nil)
        line("Understanding Attention", x: 54, y: 730, size: 25, in: context)
        line("An original teaching note for PaperReader", x: 54, y: 704, size: 11, in: context)
        line("Abstract", x: 54, y: 661, size: 14, in: context)
        paragraph(
            "Attention is a way to combine information using a question about relevance. A reader can compare a query with several keys, turn the comparisons into weights, and use those weights to combine the associated values. This note develops that idea with a small retrieval example and explains why the resulting weights should be interpreted carefully.",
            y: 637, height: 112, in: context)
        line("1  A retrieval viewpoint", x: 54, y: 498, size: 14, in: context)
        paragraph(
            "Imagine a notebook containing observations about several experiments. Each observation has a short label and a longer description. The question you are trying to answer becomes the query. The labels act as keys, while the descriptions supply the values. Comparing the query to the keys lets the system decide which descriptions deserve more weight.",
            y: 474, height: 112, in: context)
        paragraph(
            "This procedure separates address from content. A key describes when an observation might be useful; a value carries the information that is retrieved. In a learned system, both can be transformed representations of the same input. Their distinct roles still provide a useful way to understand the computation.",
            y: 343, height: 105, in: context)
        line("2  From comparison to a mixture", x: 54, y: 212, size: 14, in: context)
        paragraph(
            "A comparison produces one score for each key. Normalizing the scores creates nonnegative weights that sum to one. The output is a weighted mixture of values. A concentrated set of weights emphasizes a few observations; a spread-out set combines evidence more broadly. Neither pattern is automatically better without the surrounding task.",
            y: 188, height: 112, in: context)
        line("Original demonstration material - 1", x: 54, y: 38, size: 9, in: context)
        context.endPDFPage()

        context.beginPDFPage(nil)
        line("Understanding Attention", x: 54, y: 736, size: 17, in: context)
        line("3  Context changes the question", x: 54, y: 690, size: 14, in: context)
        paragraph(
            "A word can need different evidence in different sentences. Consider the word bank in a description of a river and in a discussion of a loan. A contextual query lets the surrounding words influence what is retrieved. Attention can therefore change the information available to the same token as its context changes.",
            y: 666, height: 106, in: context)
        paragraph(
            "Multiple attention heads can form several mixtures at once. One may capture local dependencies while another uses distant context. These examples describe possible behavior, not a guarantee that individual heads always have clean human-readable roles. A useful explanation should be checked against the actual inputs and outputs.",
            y: 540, height: 106, in: context)
        line("4  Reading the evidence carefully", x: 54, y: 407, size: 14, in: context)
        paragraph(
            "An attention weight is part of a computation. It does not, by itself, prove that a token caused a prediction or that a model understood a concept. Other transformations and later layers can change how information is used. Comparing interventions and alternative examples gives stronger evidence than inspecting a single weight pattern.",
            y: 383, height: 106, in: context)
        line("5  Questions for further reading", x: 54, y: 249, size: 14, in: context)
        paragraph(
            "When reading an attention-based method, identify the source of queries, keys, and values. Check which positions may interact and which are masked. Ask how the scores are scaled, how long inputs affect computation, and what experiment supports the claimed benefit. Keep reported results separate from your own hypotheses about why the method works.",
            y: 225, height: 118, in: context)
        line("Original demonstration material - 2", x: 54, y: 38, size: 9, in: context)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url, options: .withoutOverwriting)
    }

    private static func line(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Georgia" as CFString, size, nil)
        let string = NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }

    private static func paragraph(_ text: String, y: CGFloat, height: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Georgia" as CFString, 11, nil)
        var spacing: CGFloat = 4.5
        let paragraphStyle = withUnsafePointer(to: &spacing) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let string = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(x: 54, y: y - height, width: 504, height: height), transform: nil)
        context.textMatrix = .identity
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
    }
}
