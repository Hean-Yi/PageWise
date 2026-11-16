import CoreGraphics
import Foundation
import PDFKit

/// Extracts prose while retaining unsafe horizontal regions exactly once as local PDF crops.
/// This adapter never infers missing glyphs or reconstructs mathematical notation.
enum PDFRegionalReflow {
    typealias Line = PDFProcessor.TextLine

    static func recover(_ page: PDFPage, sourcePage: Int, modelOrdering: Bool = false) throws -> [TextBlock]? {
        guard page.rotation % 360 == 0,
            !page.annotations.contains(where: { $0.type != String(PDFAnnotationSubtype.link.rawValue.dropFirst()) }),
            let source = page.string, !source.isEmpty
        else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let lines =
            (page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine() ?? [])
            .compactMap { selection -> Line? in
                let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rect = selection.bounds(for: page)
                guard !text.isEmpty, !rect.isNull, !rect.isEmpty,
                    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                    bounds.insetBy(dx: -2, dy: -2).contains(rect)
                else { return nil }
                return Line(text: text, bounds: rect)
            }.sorted { $0.bounds.midY > $1.bounds.midY }
        guard !lines.isEmpty, characters(source) == characters(lines.map(\.text).joined()) else { return nil }
        var regions: [CGRect] = []
        var pagePixels: PDFFigurePixels?
        if PDFGraphicsInspector.containsUnsupportedGraphics(page) {
            guard let pixels = PDFFigurePixels(page: page) else { return nil }
            pagePixels = pixels
            regions = try pixels.graphicComponents(excluding: lines.map(\.bounds), minimumCells: 1, minimumExtent: 0)
                .filter { rect in
                    // The same explicit margin decoration exemption as the text adapter.
                    !(rect.height <= 2 && rect.width >= bounds.width * 0.5
                        && (rect.minY > bounds.maxY - 70 || rect.maxY < bounds.minY + 60))
                }
        }
        if let pagePixels {
            let captions = rows(lines).map { merge($0, bounds: bounds) }.flatMap { $0 }.filter {
                $0.text.range(of: #"^(?:Figure|Fig\.)\s*\d"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
            for caption in captions {
                if let region = try PDFFigureCropper.region(caption: caption.text, from: page, pixels: pagePixels) {
                    regions.append(region)
                }
            }
        }
        let sourceRows = rows(lines)
        for row in sourceRows {
            let merged = merge(row, bounds: bounds)
            let math = row.contains { isMathematical($0.text) }
            let damagedEncoding = row.contains { line in
                line.text.unicodeScalars.contains { $0.value == 0 || $0.value == 0xFFFD }
            }
            let overlapping = zip(row, row.dropFirst()).contains { $0.bounds.maxX > $1.bounds.minX + 1 }
            let tabular =
                merged.count > 2
                || (!modelOrdering && merged.count == 2 && merged.allSatisfy { !isProse($0.text) })
            let tall = row.contains { $0.bounds.height > 36 && $0.bounds.width < $0.bounds.height * 2 }
            if math || damagedEncoding || overlapping || tabular || tall {
                if modelOrdering {
                    regions += row.filter { line in
                        isMathematical(line.text)
                            || line.text.unicodeScalars.contains { $0.value == 0 || $0.value == 0xFFFD }
                            || (line.bounds.height > 36 && line.bounds.width < line.bounds.height * 2)
                            || row.contains { other in
                                other.bounds != line.bounds && other.bounds.intersection(line.bounds).width > 1
                            }
                    }.map(\.bounds)
                    if tabular {
                        // A body column beside several diagram labels is not a full-width table.
                        // Keep prose out of the graphic seeds; each label retains its own bounds.
                        regions += merged.filter { !isProse($0.text) }.map(\.bounds)
                    }
                } else {
                    regions.append(row.reduce(CGRect.null) { $0.union($1.bounds) })
                }
            }
        }
        if modelOrdering {
            return try PDFModelPageEvidence.recover(page, sourcePage: sourcePage, lines: lines, regions: regions)
        }
        // Regions span the page width so parallel labels/columns cannot be clipped or emitted twice.
        // Expand only through line centers: oversized glyph boxes must not absorb neighboring prose.
        regions = bands(regions, bounds: bounds, lines: lines)
        if !regions.isEmpty {
            // Cutting a multicolumn page into full-width bands would read the top of the
            // right column before the bottom of the left. Preserve the page until crops
            // have reliable per-column ownership rather than publishing false precedence.
            let wholePageLayout = PDFProcessor.orderedColumns(
                sourceRows.map { merge($0, bounds: bounds) }, pageBounds: bounds)
            guard wholePageLayout.reliable, wholePageLayout.groups.count == 1 else { return nil }
        }
        var result: [TextBlock] = []
        var top = bounds.maxY
        var proseCharacters = 0
        func appendText(between upper: CGFloat, and lower: CGFloat) throws {
            let selected = lines.filter { $0.bounds.midY <= upper && $0.bounds.midY > lower }
            guard !selected.isEmpty else { return }
            let rowGroups = rows(selected).map { merge($0, bounds: bounds) }
            let layout = PDFProcessor.orderedColumns(rowGroups, pageBounds: bounds)
            if layout.reliable {
                for group in layout.groups {
                    let blocks = formatted(group, sourcePage: sourcePage)
                    proseCharacters += blocks.reduce(0) { $0 + $1.text.count }
                    result += blocks
                }
            } else {
                let rect = selected.reduce(CGRect.null) { $0.union($1.bounds) }.insetBy(dx: -2, dy: -2)
                result.append(try crop(page, rect: rect.intersection(bounds), lines: selected, sourcePage: sourcePage))
            }
        }
        for region in regions {
            try Task.checkCancellation()
            try appendText(between: top, and: region.maxY)
            let selected = lines.filter { $0.bounds.midY <= region.maxY && $0.bounds.midY > region.minY }
            result.append(try crop(page, rect: region, lines: selected, sourcePage: sourcePage))
            top = region.minY
        }
        try appendText(between: top, and: bounds.minY - 2)
        guard proseCharacters > 0, !result.isEmpty,
            characters(source) == characters(result.map(\.text).joined())
        else { return nil }
        return result
    }

    static func characters(_ text: String) -> [UInt32: Int] {
        var counts: [UInt32: Int] = [:]
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            counts[scalar.value, default: 0] += 1
        }
        return counts
    }

    private static func rows(_ lines: [Line]) -> [[Line]] {
        var result: [[Line]] = []
        for line in lines.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let last = result.last, let first = last.first,
                abs(first.bounds.midY - line.bounds.midY) < max(2, min(first.bounds.height, line.bounds.height) * 0.3)
            {
                result[result.count - 1].append(line)
            } else {
                result.append([line])
            }
        }
        return result.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    static func merge(_ row: [Line], bounds: CGRect) -> [Line] {
        var result: [Line] = []
        for line in row {
            let last = result.last
            let sameColumn =
                last.map {
                    ($0.bounds.maxX <= bounds.midX && line.bounds.maxX <= bounds.midX)
                        || ($0.bounds.minX >= bounds.midX && line.bounds.minX >= bounds.midX)
                        || ($0.bounds.minX < bounds.midX && $0.bounds.maxX > bounds.midX + 12)
                        || (line.bounds.minX < bounds.midX && line.bounds.maxX > bounds.midX + 12)
                } ?? false
            if let last, line.bounds.minX >= last.bounds.maxX - 1,
                line.bounds.minX - last.bounds.maxX
                    <= max(8, min(last.bounds.height, line.bounds.height) * (sameColumn ? 3 : 1.1))
            {
                result[result.count - 1] = Line(
                    text: last.text + " " + line.text, bounds: last.bounds.union(line.bounds))
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func isProse(_ text: String) -> Bool {
        text.count >= 45 && text.filter(\.isLetter).count > text.count / 2
    }

    private static func isMathematical(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: "∑∏∫√∂∇≈≠≤≥⊗⊕∈∀∃∝∞∥")) != nil
            || (text.contains("=") && text.filter(\.isLetter).count < 30)
    }

    private static func bands(_ seeds: [CGRect], bounds: CGRect, lines: [Line]) -> [CGRect] {
        var result = seeds.map {
            CGRect(
                x: bounds.minX, y: max(bounds.minY, $0.minY - 2), width: bounds.width,
                height: min(bounds.maxY, $0.maxY + 2) - max(bounds.minY, $0.minY - 2))
        }
        // Expansion is monotonic and bounded by the finite number of source lines.
        for _ in 0...(lines.count + 1) {
            let previous = result
            result = result.map { band in
                lines.filter { $0.bounds.midY >= band.minY && $0.bounds.midY <= band.maxY }.reduce(band) {
                    $0.union($1.bounds.insetBy(dx: 0, dy: -1))
                }
                .intersection(bounds)
            }.sorted { $0.maxY > $1.maxY }
            var merged: [CGRect] = []
            for rect in result {
                if let last = merged.last, last.minY <= rect.maxY + 5 {
                    merged[merged.count - 1] = last.union(rect)
                } else {
                    merged.append(rect)
                }
            }
            result = merged
            if result == previous { break }
        }
        return result
    }

    private static func formatted(_ lines: [Line], sourcePage: Int) -> [TextBlock] {
        let heights = lines.map { $0.bounds.height }.sorted()
        let bodyHeight = heights[heights.count / 2]
        return PDFProcessor.paragraphs(from: lines, sourcePage: sourcePage).map { block in
            var result = block
            let first = lines.first { block.text.hasPrefix($0.text) }
            let numbered =
                block.text.range(of: #"^(?:\d+(?:\.\d+)*|[A-Z])\s+[A-Z][^.!?]{0,85}$"#, options: .regularExpression)
                != nil
            let heading =
                block.text.count < 130
                && ((first?.bounds.height ?? 0) > bodyHeight * 1.2 || numbered
                    || ["Abstract", "References", "Bibliography", "Appendix"].contains(block.text))
            let caption = block.text.range(of: #"^(?:Figure|Table)\s+\d"#, options: .regularExpression) != nil
            let tag = caption ? "figcaption" : (heading ? "h2" : "p")
            result.richContent = RichContent(
                html: "<\(tag)>\(HTMLPaperParser.escape(block.text))</\(tag)>",
                translationInput: block.text, mathematics: [:], mathDescriptions: [:])
            return result
        }
    }

    private static func crop(_ page: PDFPage, rect: CGRect, lines: [Line], sourcePage: Int) throws -> TextBlock {
        let image = try PDFFigureCropper.rasterize(page, bounds: rect)
        var block = TextBlock(sourcePage: sourcePage, text: lines.map(\.text).joined(separator: "\n"))
        block.richContent = RichContent(
            html:
                "<figure class='pdf-region' style='width:\(Int(rect.width * 1.5))px;max-width:100%;margin-left:auto;margin-right:auto'><img style='max-height:none;width:100%;height:auto' src='\(image.dataURI)' width='\(image.width)' height='\(image.height)' alt='原版局部图表或公式'></figure>",
            translationInput: "", mathematics: [:], mathDescriptions: [:],
            imageSizes: [PaperImageSize(width: image.width, height: image.height)], isFigure: true)
        return block
    }
}
