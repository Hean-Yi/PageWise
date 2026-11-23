import Foundation
import PDFKit

/// Keeps the original page geometry as the authority for tables, excerpts and source links.
enum PDFIllustratedPage {
    static func compose(
        text: PDFSentenceExtraction, on page: PDFPage, pageIndex: Int, includeSourceReading: Bool = true,
        regions suppliedRegions: [PDFCaptionRegion]? = nil
    ) throws -> PDFSentenceExtraction {
        let regions = try suppliedRegions ?? PDFCaptionRegionDetector.regions(on: page)
        var remainingBytes = 8 * 1_024 * 1_024
        func render(_ bounds: CGRect) -> Data? {
            guard remainingBytes > 0,
                let data = autoreleasepool(invoking: { PDFRegionRenderer.png(page: page, bounds: bounds) }),
                data.count <= remainingBytes
            else { return nil }
            remainingBytes -= data.count
            return data
        }

        var covered: [CGRect] = []
        var coveredIDs: Set<String> = []
        var crops: [(PDFCaptionRegion, Data?, PDFReadingTable?)] = []
        let byline = text.illustrations.first { $0.originalText?.kind == .byline }?.sourceBounds
        for candidate in regions {
            try Task.checkCancellation()
            let region = try separatingByline(byline, from: candidate, on: page)
            var png: Data?
            var table: PDFReadingTable?
            if let bounds = region.sourceBounds, covered.count < 6 {
                png = render(bounds)
                if region.label.hasPrefix("表 "), includeSourceReading || png == nil {
                    table = PDFTableExtractor.extract(on: page, in: bounds)
                    // These cells use the published crop for typography that PDFKit cannot reproduce.
                    if png == nil, table?.sourceCellBounds.isEmpty == false { table = nil }
                }
                if png != nil || table != nil {
                    covered.append(bounds)
                    let inside = bounds.insetBy(dx: -1, dy: -1)
                    for sentence in text.sentences
                    where !sentence.rects.isEmpty
                        && sentence.rects.allSatisfy({ line in rect(line).map(inside.contains) == true })
                    {
                        coveredIDs.insert(sentence.id)
                    }
                }
            }
            crops.append((region, png, table))
        }
        let sentences = text.sentences.filter { !coveredIDs.contains($0.id) }
        var items = crops.map { region, png, table in
            PDFReadingIllustration(
                id: "p\(pageIndex)-illustration-\(region.captionRange.location)", label: region.label,
                pageIndex: pageIndex,
                sourceBounds: region.sourceBounds ?? region.captionBounds,
                insertBeforeSentenceID: insertion(for: region, in: sentences), imagePNG: png, table: table)
        }
        var notice: String?
        if includeSourceReading {
            let box = page.bounds(for: .cropBox)
            // A very fragmented text layer reads better as one expandable original page.
            let tooFragmented = text.unpairedBounds.count > 320
            let excerpts =
                tooFragmented
                ? []
                : PDFSourceRemainder.regions(
                    for: text.unpairedBounds, excluding: covered, sentences: sentences, cropBox: box)
            let unresolved = items.filter { $0.imagePNG == nil && $0.table == nil }
            let originalText = text.illustrations.filter { item in
                guard let original = item.originalText else { return false }
                return original.kind != .prose
                    || !covered.contains { $0.insetBy(dx: -1, dy: -1).contains(item.sourceBounds) }
            }
            let wholePage = sentences.isEmpty && covered.isEmpty && originalText.isEmpty
            // A verified table can survive even when the surrounding text layer could not be read.
            let unreadableBody =
                text.sentences.isEmpty && originalText.isEmpty && text.notice != nil && !covered.isEmpty
            var needsSupplement = text.hasUnlocatedText || tooFragmented || !unresolved.isEmpty || unreadableBody
            if !wholePage {
                for (index, bounds) in excerpts.enumerated() {
                    try Task.checkCancellation()
                    guard index < 24, let png = render(bounds) else {
                        needsSupplement = true
                        break
                    }
                    let excerpt = PDFReadingIllustration(
                        id: "p\(pageIndex)-excerpt-\(index)", label: "原排片段", pageIndex: pageIndex,
                        sourceBounds: bounds, insertBeforeSentenceID: insertion(at: bounds, in: sentences),
                        imagePNG: png, presentation: .excerpt)
                    // An omitted heading and the figure below it can both precede the figure caption.
                    let followingFigure = items.firstIndex { item in
                        let figure = item.sourceBounds
                        return item.presentation == .illustration
                            && item.insertBeforeSentenceID == excerpt.insertBeforeSentenceID
                            && bounds.minY >= figure.maxY
                            && min(bounds.maxX, figure.maxX) > max(bounds.minX, figure.minX)
                    }
                    items.insert(excerpt, at: followingFigure ?? items.endIndex)
                }
            }
            if wholePage || needsSupplement {
                try Task.checkCancellation()
                // A single page facsimile also covers ambiguous or overlapping captions without guessing a boundary.
                if let png = autoreleasepool(invoking: { PDFRegionRenderer.png(page: page, bounds: box) }) {
                    let names = unresolved.map(\.label).joined(separator: "、")
                    let label = wholePage ? "原页 \(pageIndex + 1)" : (names.isEmpty ? "原版补充" : "\(names)所在原页")
                    items.removeAll { $0.imagePNG == nil && $0.table == nil }
                    items.append(
                        PDFReadingIllustration(
                            id: "p\(pageIndex)-source", label: label, pageIndex: pageIndex, sourceBounds: box,
                            insertBeforeSentenceID: unresolved.first?.insertBeforeSentenceID, imagePNG: png,
                            presentation: wholePage ? .originalPage : .supplement))
                } else {
                    notice = text.notice ?? "部分原文未能在此显示，请查看原页。"
                }
            }
            for block in originalText {
                var anchor = block.insertBeforeSentenceID
                if let id = anchor, coveredIDs.contains(id),
                    let index = text.sentences.firstIndex(where: { $0.id == id })
                {
                    anchor = text.sentences[index...].first { !coveredIDs.contains($0.id) }?.id
                }
                let position = items.firstIndex { item in
                    guard item.insertBeforeSentenceID == anchor else { return false }
                    if item.presentation == .supplement { return true }
                    let a = block.sourceBounds
                    let b = item.sourceBounds
                    if min(a.maxY, b.maxY) > max(a.minY, b.minY), a.maxX <= b.minX + 2 { return true }
                    if min(a.maxY, b.maxY) > max(a.minY, b.minY), b.maxX <= a.minX + 2 { return false }
                    return a.maxY > b.maxY
                }
                let anchored = PDFReadingIllustration(
                    id: block.id, label: block.label, pageIndex: pageIndex, sourceBounds: block.sourceBounds,
                    insertBeforeSentenceID: anchor, imagePNG: nil, originalText: block.originalText)
                items.insert(anchored, at: position ?? items.endIndex)
            }
        }
        var result = PDFSentenceExtraction(
            sentences: text.sentences, notice: text.notice, illustrations: items, picturedSentenceIDs: coveredIDs)
        result.paragraphNotice = notice
        return result
    }

    private static func rect(_ components: [Double]) -> CGRect? {
        guard components.count == 4 else { return nil }
        return CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
    }

    /// A title-page illustration can share the page width with the byline above it. Require a
    /// visible gap before shortening a crop, and keep the whole source available if ink touches.
    private static func separatingByline(_ byline: CGRect?, from region: PDFCaptionRegion, on page: PDFPage) throws
        -> PDFCaptionRegion
    {
        guard let byline, let box = region.sourceBounds, byline.intersects(box),
            box.intersection(byline).width > min(box.width, byline.width) * 0.55,
            byline.minY > region.captionBounds.maxY, region.label.hasPrefix("图 ")
        else { return region }
        let lower = CGRect(x: box.minX, y: box.minY, width: box.width, height: byline.minY - box.minY)
        var clipped: CGRect?
        if box.maxY <= byline.maxY + 4, lower.height > region.captionBounds.height * 2, let ink = PDFCaptionInk(page) {
            var strips = try ink.strips(in: lower)
            // A glyph can paint a descender just beyond its PDFKit line box. It belongs to the
            // byline only if it touches that edge and a separate band of whitespace follows.
            if let last = strips.last, lower.maxY - last.bounds.maxY < 1.5,
                lower.maxY - last.bounds.minY <= min(3, region.captionBounds.height * 0.28)
            {
                strips.removeLast()
            }
            let flank = CGRect(x: box.minX, y: byline.minY, width: box.width, height: box.maxY - byline.minY)
            let sides = [
                CGRect(x: flank.minX, y: flank.minY, width: max(0, byline.minX - flank.minX - 2), height: flank.height),
                CGRect(
                    x: byline.maxX + 2, y: flank.minY, width: max(0, flank.maxX - byline.maxX - 2), height: flank.height
                ),
            ]
            let otherInk = try sides.contains { side in
                guard side.width > 2 else { return false }
                return try !ink.strips(in: side).isEmpty
            }
            if let top = strips.map(\.bounds.maxY).max(), lower.maxY - top >= 3,
                !otherInk,
                strips.contains(where: { $0.longestStroke > 25 || $0.drawnRows > 2 })
            {
                clipped = CGRect(x: box.minX, y: box.minY, width: box.width, height: top + 2 - box.minY)
            }
        }
        return PDFCaptionRegion(
            label: region.label, captionBounds: region.captionBounds, captionRange: region.captionRange,
            sourceBounds: clipped)
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
        return insertion(at: caption, in: sentences, fallbackOffset: NSMaxRange(region.captionRange))
    }

    private static func insertion(at caption: CGRect, in sentences: [PDFSourceSentence], fallbackOffset: Int? = nil)
        -> String?
    {
        var lastAbove: Int?
        for (index, sentence) in sentences.enumerated() {
            guard let line = sentence.rects.first.flatMap(rect) else { continue }
            let overlap = min(line.maxX, caption.maxX) - max(line.minX, caption.minX)
            guard overlap > min(line.width, caption.width) * 0.25 else { continue }
            if line.midY <= caption.midY + max(2, caption.height * 0.55) { return sentence.id }
            lastAbove = index
        }
        if let lastAbove, lastAbove + 1 < sentences.count { return sentences[lastAbove + 1].id }
        if lastAbove == nil, let fallbackOffset {
            return sentences.first { ($0.characterRanges.first?.location ?? 0) >= fallbackOffset }?.id
        }
        return nil
    }
}
