import CoreGraphics
import Foundation
import PDFKit

/// Preserves local objects without turning their neighboring columns into images.
/// Geometry proposes groups; the model settles their reading order before publication.
enum PDFModelPageEvidence {
    typealias Line = PDFProcessor.TextLine

    static func recover(_ page: PDFPage, sourcePage: Int, lines: [Line], regions: [CGRect]) throws -> [TextBlock]? {
        let bounds = page.bounds(for: .cropBox)
        var crops = regions.map { $0.insetBy(dx: -2, dy: -2).intersection(bounds) }.filter { !$0.isEmpty }
        // Grow through intersecting glyphs, then merge overlapping crops to give each glyph one owner.
        for _ in 0...(lines.count + crops.count + 1) {
            let before = crops
            crops = crops.map { crop in
                lines.filter { $0.bounds.intersects(crop) }.reduce(crop) {
                    $0.union($1.bounds.insetBy(dx: -1, dy: -1))
                }.intersection(bounds)
            }
            var merged: [CGRect] = []
            for var crop in crops {
                while let index = merged.firstIndex(where: { $0.intersects(crop) }) {
                    crop = crop.union(merged.remove(at: index))
                }
                merged.append(crop)
            }
            crops = merged
            if crops == before { break }
        }
        let text = lines.filter { line in !crops.contains { $0.intersects(line.bounds) } }
        guard !text.isEmpty else { return nil }
        var entries: [(TextBlock, CGRect)] = []
        // Never join lines across a retained object. Unknown columns stay separate evidence.
        var rows: [[Line]] = []
        for line in text.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let first = rows.last?.first,
                abs(first.bounds.midY - line.bounds.midY) < max(2, min(first.bounds.height, line.bounds.height) * 0.3)
            {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        rows = rows.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
        let layout = PDFProcessor.orderedColumns(rows, pageBounds: bounds)
        let groups = layout.reliable ? layout.groups : rows.flatMap { $0 }.map { [$0] }
        for group in groups {
            var chunk: [Line] = []
            func flush() {
                guard !chunk.isEmpty else { return }
                var block = TextBlock(sourcePage: sourcePage, text: chunk.map(\.text).joined(separator: " "))
                block.richContent = RichContent(
                    html: "<p>\(HTMLPaperParser.escape(block.text))</p>", translationInput: block.text,
                    mathematics: [:], mathDescriptions: [:])
                entries.append((block, chunk.reduce(CGRect.null) { $0.union($1.bounds) }))
                chunk = []
            }
            for line in group {
                if let last = chunk.last {
                    let gap = last.bounds.minY - line.bounds.maxY
                    let changedSize =
                        abs(last.bounds.height - line.bounds.height) > min(last.bounds.height, line.bounds.height)
                        * 0.25
                    let indented = line.bounds.minX - last.bounds.minX > max(12, line.bounds.height)
                    let corridor = last.bounds.union(line.bounds)
                    if gap > max(7, line.bounds.height * 0.65) || changedSize || indented
                        || chunk.reduce(0, { $0 + $1.text.count }) + line.text.count > 1_200
                        || crops.contains(where: { $0.intersects(corridor) })
                    {
                        flush()
                    }
                }
                chunk.append(line)
            }
            flush()
        }
        for crop in crops {
            try Task.checkCancellation()
            let selected = lines.filter { crop.intersects($0.bounds) }
            let image = try PDFFigureCropper.rasterize(page, bounds: crop)
            var block = TextBlock(sourcePage: sourcePage, text: selected.map(\.text).joined(separator: "\n"))
            let mathematical =
                block.text.rangeOfCharacter(from: CharacterSet(charactersIn: "=∑∏∫√∂∇≈≠≤≥⊗⊕∈∀∃∝∞∥")) != nil
            let frontMatterRegion =
                sourcePage == 0 && crop.minY > bounds.minY + bounds.height * 0.7
                && block.text.count <= 600
                && block.text.range(
                    of: #"(?i)(?:\bcorrespondence\s*:|\baffiliations?\s*:|[\w.+-]+@[\w.-]+)"#,
                    options: .regularExpression) != nil
            block.reflowMayExclude =
                !mathematical
                && (frontMatterRegion || crop.width * crop.height / (bounds.width * bounds.height) < 0.04
                    || crop.maxX < bounds.minX + bounds.width * 0.1
                    || crop.minX > bounds.maxX - bounds.width * 0.1)
            block.richContent = RichContent(
                html:
                    "<figure class='pdf-region' style='width:\(Int(ceil(crop.width * 1.5)))px;max-width:100%;margin-left:auto;margin-right:auto'><img src='\(image.dataURI)' width='\(image.width)' height='\(image.height)' alt='原版局部图表或公式'></figure>",
                translationInput: "", mathematics: [:], mathDescriptions: [:],
                imageSizes: [PaperImageSize(width: image.width, height: image.height)], isFigure: true)
            entries.append((block, crop))
        }
        guard entries.count <= 128,
            PDFRegionalReflow.characters(lines.map(\.text).joined())
                == PDFRegionalReflow.characters(entries.map { $0.0.text }.joined())
        else { return nil }
        let groupID = UUID()
        var result = entries.sorted {
            if abs($0.1.midY - $1.1.midY) > 2 { return $0.1.midY > $1.1.midY }
            return $0.1.minX < $1.1.minX
        }.map { block, rect in
            var block = block
            block.reflowOrderGroup = groupID
            block.reflowBounds = [
                Double((rect.minX - bounds.minX) / bounds.width), Double((rect.minY - bounds.minY) / bounds.height),
                Double(rect.width / bounds.width), Double(rect.height / bounds.height),
            ]
            return block
        }
        if sourcePage == 0,
            let abstract = result.firstIndex(where: {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "abstract"
            }), abstract > 1
        {
            for index in 1..<abstract where result[index].richContent?.isFigure != true {
                let text = result[index].text
                let words = text.split { !$0.isLetter && $0 != "'" && $0 != "-" }
                let names = words.filter { $0.lowercased() != "and" }
                if text.count < 400, names.count >= 4, text.contains(",") || text.contains(" and "),
                    names.allSatisfy({ $0.first?.isUppercase == true })
                {
                    let html = result[index].richContent?.html ?? "<p>\(HTMLPaperParser.escape(text))</p>"
                    result[index].richContent?.html = "<div class='front-matter'>\(html)</div>"
                    result[index].richContent?.translationInput = ""
                }
            }
        }
        return result
    }
}
