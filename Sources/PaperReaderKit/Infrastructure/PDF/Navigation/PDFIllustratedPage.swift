import Foundation
import PDFKit

/// Composes one reading page. Crops are regenerated from the original and never enter the translation cache.
enum PDFIllustratedPage {
    static func compose(text: PDFSentenceExtraction, on page: PDFPage, pageIndex: Int) throws -> PDFSentenceExtraction {
        let regions = try PDFCaptionRegionDetector.regions(on: page)
        guard !regions.isEmpty else { return text }

        var remainingBytes = 8 * 1_024 * 1_024
        var images = 0
        var coveredIDs: Set<String> = []
        var crops: [(PDFCaptionRegion, Data?)] = []
        for region in regions {
            try Task.checkCancellation()
            var png: Data?
            if images < 6, remainingBytes > 0, let bounds = region.sourceBounds,
                let data = autoreleasepool(invoking: { PDFRegionRenderer.png(page: page, bounds: bounds) }),
                data.count <= remainingBytes
            {
                png = data
                images += 1
                remainingBytes -= data.count
                // A diagram can contain complete sentences. Omit them from the translation request only
                // when every source line is visibly preserved inside the delivered image.
                let inside = bounds.insetBy(dx: -1, dy: -1)
                for sentence in text.sentences
                where !sentence.rects.isEmpty
                    && sentence.rects.allSatisfy({ line in rect(line).map(inside.contains) == true })
                {
                    coveredIDs.insert(sentence.id)
                }
            }
            crops.append((region, png))
        }
        let sentences = text.sentences.filter { !coveredIDs.contains($0.id) }
        let illustrations = crops.map { region, png in
            PDFReadingIllustration(
                id: "p\(pageIndex)-illustration-\(region.captionRange.location)", label: region.label,
                pageIndex: pageIndex,
                sourceBounds: region.sourceBounds ?? region.captionBounds,
                insertBeforeSentenceID: insertion(for: region, in: sentences), imagePNG: png)
        }
        return PDFSentenceExtraction(
            sentences: text.sentences, notice: text.notice, illustrations: illustrations,
            picturedSentenceIDs: coveredIDs)
    }

    private static func rect(_ components: [Double]) -> CGRect? {
        guard components.count == 4 else { return nil }
        return CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
    }

    /// Prefer the actual caption's PDF character range. For omitted captions, use lines in the
    /// same column so that a right-column table does not precede the left-column body at that height.
    private static func insertion(for region: PDFCaptionRegion, in sentences: [PDFSourceSentence]) -> String? {
        let caption = region.captionBounds
        if let match = sentences.first(where: { sentence in
            sentence.characterRanges.contains { NSIntersectionRange($0, region.captionRange).length > 0 }
        }) {
            return match.id
        }
        var lastAbove: Int?
        for (index, sentence) in sentences.enumerated() {
            guard let line = sentence.rects.first.flatMap(rect) else { continue }
            let overlap = min(line.maxX, caption.maxX) - max(line.minX, caption.minX)
            guard overlap > min(line.width, caption.width) * 0.25 else { continue }
            if line.midY <= caption.midY + max(2, caption.height * 0.55) { return sentence.id }
            lastAbove = index
        }
        if let lastAbove, lastAbove + 1 < sentences.count { return sentences[lastAbove + 1].id }
        if lastAbove == nil {
            // Some narrow captions sit in an otherwise empty column. Use the next source range
            // only in this case, as PDF text streams may interleave columns.
            return sentences.first(where: {
                ($0.characterRanges.first?.location ?? 0) >= NSMaxRange(region.captionRange)
            })?.id
        }
        return nil
    }
}
