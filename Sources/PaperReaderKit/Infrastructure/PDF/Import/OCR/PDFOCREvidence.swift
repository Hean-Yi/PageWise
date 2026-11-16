import CoreGraphics
import Foundation
import PDFKit

/// A conservative English-prose adapter. Unknown ink is retained, never invented as text.
enum PDFOCREvidence {
    struct Recovery {
        let blocks: [TextBlock]
        let warning: String
    }

    static func recover(_ page: PDFPage, sourcePage: Int, modelOrdering: Bool = false) throws -> Recovery? {
        guard eligible(page) else { return nil }
        return try recover(
            page, sourcePage: sourcePage, candidates: VisionPDFTextRecognizer.recognize(page),
            modelOrdering: modelOrdering)
    }

    /// Separate candidate admission from Vision so uncertainty and omissions can be tested deterministically.
    static func recover(_ page: PDFPage, sourcePage: Int, candidates: [PDFOCRLine], modelOrdering: Bool = false) throws
        -> Recovery?
    {
        guard eligible(page), !candidates.isEmpty, candidates.count <= 600,
            let pixels = PDFFigurePixels(page: page)
        else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard
            candidates.allSatisfy({
                !$0.bounds.isEmpty && !$0.bounds.isNull
                    && [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height].allSatisfy(\.isFinite)
                    && bounds.insetBy(dx: -1, dy: -1).contains($0.bounds)
            })
        else { return nil }
        let lines = candidates.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > 2 { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
        let nativeLines = PDFProcessor.positionedLines(on: page).rows.flatMap { $0 }
        var unsafe = lines.filter { !isProse($0) || conflictsWithTextLayer($0, native: nativeLines) }.map(\.bounds)
        // A region not explained by recognized text may be a missed glyph, equation or drawing.
        // No minimum extent filter: even small missing symbols must remain visible.
        let unexplained = try pixels.graphicComponents(
            excluding: lines.map(\.bounds), minimumCells: 1, minimumExtent: 0)
        guard unexplained.count <= 300 else { return nil }
        if modelOrdering {
            unsafe += unexplained
            unsafe += nativeLines.filter { native in
                !lines.contains {
                    $0.bounds.insetBy(dx: -3, dy: -3).contains(native.bounds)
                        && normalized($0.text) == normalized(native.text)
                }
            }.map(\.bounds)
            guard
                var blocks = try PDFModelPageEvidence.recover(
                    page, sourcePage: sourcePage, lines: lines.map { .init(text: $0.text, bounds: $0.bounds) },
                    regions: unsafe)
            else { return nil }
            for index in blocks.indices where blocks[index].richContent?.requiresTranslation == true {
                let html = blocks[index].richContent!.html.replacingOccurrences(
                    of: "<p>", with: "<p data-ocr-confidence='device-recognized'>")
                blocks[index].richContent?.html = html
            }
            return Recovery(blocks: blocks, warning: "第 \(sourcePage + 1) 页正文由设备端 OCR 识别，结构交给模型整理；不确定区域保留原图，请对照原版核对。")
        }
        // Large graphics can contain paragraph-like labels. Their boundaries are too ambiguous
        // for this prose-only OCR adapter; retain the complete page instead.
        if unexplained.contains(where: { $0.height > 45 && $0.width > 45 }) { return nil }
        unsafe += unexplained
        var bands = mergeBands(unsafe, lines: lines, bounds: bounds)
        // Every original text-layer fragment must also have a disposition, including damaged text
        // or material that Vision did not recognize at all.
        for native in nativeLines
        where !lines.contains(where: {
            $0.bounds.insetBy(dx: -3, dy: -3).contains(native.bounds)
                && normalized($0.text) == normalized(native.text)
        }) {
            bands.append(native.bounds)
        }
        bands = mergeBands(bands, lines: lines, bounds: bounds)
        if !bands.isEmpty {
            // Full-width crops cut both columns. Ordering each resulting strip independently
            // would emit right-column text before the remaining left column. Only a verified
            // single-column page can be divided this way; retain ambiguous/multicolumn pages.
            let wholePageLayout = PDFProcessor.orderedColumns(textRows(lines), pageBounds: bounds)
            guard wholePageLayout.reliable, wholePageLayout.groups.count == 1 else { return nil }
        }
        var blocks: [TextBlock] = []
        var proseCount = 0
        var top = bounds.maxY
        func appendText(upper: CGFloat, lower: CGFloat) throws {
            let selected = lines.filter { $0.bounds.midY <= upper && $0.bounds.midY > lower }
            guard !selected.isEmpty else { return }
            let rows = textRows(selected)
            let layout = PDFProcessor.orderedColumns(rows, pageBounds: bounds)
            if !layout.reliable {
                let rect = selected.reduce(CGRect.null) { $0.union($1.bounds) }
                blocks.append(try crop(page, rect: fullWidth(rect, bounds: bounds), sourcePage: sourcePage))
                return
            }
            for group in layout.groups {
                for var block in PDFProcessor.paragraphs(from: group, sourcePage: sourcePage) {
                    let paragraphLines = group.filter { block.text.contains($0.text) }
                    let geometry = paragraphLines.reduce(CGRect.null) {
                        $0.union($1.bounds)
                    }
                    let rect = [
                        (geometry.minX - bounds.minX) / bounds.width,
                        (geometry.minY - bounds.minY) / bounds.height,
                        geometry.width / bounds.width, geometry.height / bounds.height,
                    ].map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
                    let confidence =
                        lines.filter { line in paragraphLines.contains { $0.bounds == line.bounds } }
                        .map(\.confidence).min() ?? 0
                    block.richContent = RichContent(
                        html:
                            "<p data-source-page='\(sourcePage)' data-ocr-rect='\(rect)' data-ocr-confidence='\(confidence)'>\(HTMLPaperParser.escape(block.text))</p>",
                        translationInput: block.text, mathematics: [:], mathDescriptions: [:])
                    blocks.append(block)
                    proseCount += 1
                }
            }
        }
        for band in bands {
            try Task.checkCancellation()
            try appendText(upper: top, lower: band.maxY)
            blocks.append(try crop(page, rect: band, sourcePage: sourcePage))
            top = band.minY
        }
        try appendText(upper: top, lower: bounds.minY - 1)
        guard proseCount > 0 else { return nil }
        let preserved = blocks.contains { $0.richContent?.isFigure == true }
        let warning =
            "第 \(sourcePage + 1) 页正文由设备端 OCR 识别，请对照原版核对。"
            + (preserved ? "不确定文字、公式或未识别区域已保留原图，不参与翻译。" : "OCR 置信度不代表逐字准确。")
        return Recovery(blocks: blocks, warning: warning)
    }

    private static func eligible(_ page: PDFPage) -> Bool {
        page.rotation % 360 == 0
            && !page.annotations.contains { $0.type != String(PDFAnnotationSubtype.link.rawValue.dropFirst()) }
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
    }

    private static func conflictsWithTextLayer(_ line: PDFOCRLine, native: [PDFProcessor.TextLine]) -> Bool {
        let matches = native.filter { $0.bounds.intersects(line.bounds) }
        guard !matches.isEmpty else { return false }
        return normalized(matches.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " "))
            != normalized(line.text)
    }

    private static func isProse(_ line: PDFOCRLine) -> Bool {
        let text = line.text
        let words = text.split(whereSeparator: \.isWhitespace)
        guard line.confidence.isFinite, line.confidence >= 0.9, text.count >= 30, words.count >= 6,
            text.filter(\.isLetter).count * 100 >= text.count * 65,
            text.unicodeScalars.allSatisfy({
                CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ,.;:!?()'-\"%\u{2019}\u{2013}"
                ).contains($0)
            })
        else { return false }
        // Isolated variables and several single-letter labels are common OCR renderings of formulas.
        return !words.contains { word in
            let letters = word.filter(\.isLetter)
            return letters.count == 1 && letters != "a" && letters != "A" && letters != "I"
        }
    }

    private static func textRows(_ lines: [PDFOCRLine]) -> [[PDFProcessor.TextLine]] {
        var rows: [[PDFProcessor.TextLine]] = []
        for line in lines {
            let value = PDFProcessor.TextLine(text: line.text, bounds: line.bounds)
            if let last = rows.last?.first,
                abs(last.bounds.midY - line.bounds.midY) < min(last.bounds.height, line.bounds.height) * 0.4
            {
                rows[rows.count - 1].append(value)
            } else {
                rows.append([value])
            }
        }
        return rows.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    private static func fullWidth(_ rect: CGRect, bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX, y: max(bounds.minY, rect.minY - 3), width: bounds.width,
            height: min(bounds.maxY, rect.maxY + 3) - max(bounds.minY, rect.minY - 3))
    }

    private static func mergeBands(_ seeds: [CGRect], lines: [PDFOCRLine], bounds: CGRect) -> [CGRect] {
        var bands = seeds.map { fullWidth($0, bounds: bounds) }
        for _ in 0...(lines.count + 1) {
            let before = bands
            bands = bands.map { band in
                lines.filter { $0.bounds.intersects(band) }.reduce(band) {
                    $0.union(fullWidth($1.bounds, bounds: bounds))
                }
            }.sorted { $0.maxY > $1.maxY }
            var merged: [CGRect] = []
            for band in bands {
                if let last = merged.last, last.minY <= band.maxY + 3 {
                    merged[merged.count - 1] = last.union(band)
                } else {
                    merged.append(band)
                }
            }
            bands = merged
            if bands == before { break }
        }
        return bands
    }

    private static func crop(_ page: PDFPage, rect: CGRect, sourcePage: Int) throws -> TextBlock {
        let image = try PDFFigureCropper.rasterize(page, bounds: rect)
        var block = TextBlock(sourcePage: sourcePage, text: "")
        let notice = "此区域保留原文；OCR 无法可靠区分文字、公式或图形。"
        block.imageWarnings = [notice]
        block.richContent = RichContent(
            html:
                "<figure class='pdf-region'><img src='\(image.dataURI)' width='\(image.width)' height='\(image.height)' alt='保留的原文区域'><div class='image-notice'>\(notice)</div></figure>",
            translationInput: "", mathematics: [:], mathDescriptions: [:],
            imageSizes: [PaperImageSize(width: image.width, height: image.height)], isFigure: true)
        return block
    }
}
