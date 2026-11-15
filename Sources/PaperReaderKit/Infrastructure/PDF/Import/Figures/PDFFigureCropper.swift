import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Caption-anchored pixel recovery. A rejection is preferable to publishing a plausible but wrong crop.
enum PDFFigureCropper {
    struct Recovery {
        let bounds: CGRect
        let image: PaperImage
        let coverageText: String
    }
    private struct Line {
        let text: String
        let bounds: CGRect
        var isBody: Bool { text.count >= 55 && text.split(whereSeparator: \.isWhitespace).count >= 8 }
        var isCaption: Bool {
            text.range(of: #"^\s*(Figure|Fig\.|Table)\s*\d"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static func recover(caption: String, from page: PDFPage, diagnostic: ((String) -> Void)? = nil) throws -> Recovery?
    {
        guard let bounds = try region(caption: caption, from: page, diagnostic: diagnostic) else { return nil }
        let image = try rasterize(page, bounds: bounds)
        return Recovery(bounds: bounds, image: image, coverageText: page.selection(for: bounds)?.string ?? "")
    }

    static func region(
        caption: String, from page: PDFPage, pixels supplied: PDFFigurePixels? = nil,
        diagnostic: ((String) -> Void)? = nil
    ) throws -> CGRect? {
        try Task.checkCancellation()
        guard normalized(caption).count >= 12, caption.count <= 8_000,
            let pixels = supplied ?? PDFFigurePixels(page: page)
        else {
            diagnostic?("unsupported page or caption")
            return nil
        }
        let lines = textLines(on: page)
        guard let captionBounds = locate(caption, in: lines) else {
            diagnostic?("caption not uniquely located")
            return nil
        }
        let pageBounds = pixels.pageBounds
        let components = try pixels.graphicComponents(excluding: lines.map(\.bounds)).filter {
            $0.minY >= captionBounds.maxY - 2 && $0.maxY <= pageBounds.maxY - 12
                && !($0.height <= 6 && $0.width > pageBounds.width * 0.6)
        }
        var column = pageBounds.insetBy(dx: 12, dy: 0)
        if captionBounds.width < pageBounds.width * 0.55 {
            if captionBounds.maxX < pageBounds.midX + 8 {
                column.size.width = pageBounds.midX - column.minX
            } else if captionBounds.minX > pageBounds.midX - 8 {
                column.origin.x = pageBounds.midX
                column.size.width = pageBounds.maxX - 12 - column.minX
            }
        }
        let candidates = components.filter {
            horizontalOverlap($0, captionBounds) > min($0.width, captionBounds.width) * 0.25
        }
        guard let seed = candidates.min(by: { $0.minY < $1.minY }), seed.minY - captionBounds.maxY <= 120 else {
            diagnostic?("no nearby drawing")
            return nil
        }
        if seed.minX < column.minX - 8 || seed.maxX > column.maxX + 8 { column = pageBounds.insetBy(dx: 12, dy: 0) }
        // A paragraph between the caption and the closest drawing is evidence of a wrong association.
        guard
            !lines.contains(where: {
                $0.isBody && $0.bounds.minY > captionBounds.maxY + 2
                    && $0.bounds.maxY < seed.minY - 2 && horizontalOverlap($0.bounds, column) > $0.bounds.width * 0.5
            })
        else {
            diagnostic?("paragraph between caption and drawing")
            return nil
        }
        let barriers = lines.filter { line in
            guard line.isBody || line.isCaption, line.bounds.minY > seed.maxY + 8,
                horizontalOverlap(line.bounds, column) > line.bounds.width * 0.5
            else { return false }
            return !components.contains { $0.insetBy(dx: -2, dy: -2).contains(line.bounds) }
        }
        let top = barriers.map(\.bounds.minY).min() ?? (pageBounds.maxY - 18)
        let selected = components.filter { rect in
            rect.maxY < top && rect.minX >= column.minX - 8 && rect.maxX <= column.maxX + 8
        }
        guard !selected.isEmpty else {
            diagnostic?("no drawing within boundaries")
            return nil
        }
        var bounds = selected.reduce(CGRect.null) { $0.union($1) }
        let drawing = bounds
        let labelArea = drawing.insetBy(dx: -32, dy: -20)
        for line in lines where line.bounds.minY > captionBounds.maxY + 1 && line.bounds.maxY < top - 1 {
            if labelArea.intersects(line.bounds), horizontalOverlap(line.bounds, column) > line.bounds.width * 0.9 {
                bounds = bounds.union(line.bounds)
            }
        }
        // Labels can extend well beyond plotted lines. Grow through touching text boxes
        // until stable instead of cutting a word at the first pixel-derived edge.
        for _ in 0..<20 {
            let previous = bounds
            for line in lines where line.bounds.minY > captionBounds.maxY + 1 && line.bounds.maxY < top - 1 {
                if bounds.insetBy(dx: -8, dy: -8).intersects(line.bounds),
                    horizontalOverlap(line.bounds, column) > line.bounds.width * 0.9
                {
                    if line.isBody && !drawing.insetBy(dx: -8, dy: -8).intersects(line.bounds) {
                        diagnostic?("body text at crop boundary")
                        return nil
                    }
                    bounds = bounds.union(line.bounds)
                }
            }
            if bounds == previous { break }
        }
        let band = CGRect(
            x: column.minX, y: captionBounds.maxY + 2, width: column.width, height: max(0, top - captionBounds.maxY - 2)
        )
        bounds = bounds.insetBy(dx: -8, dy: -8).intersection(band)
        let envelope = bounds
        guard let ink = pixels.inkBounds(in: bounds) else {
            diagnostic?("no foreground pixels")
            return nil
        }
        bounds = ink.insetBy(dx: -6, dy: -6)
        // Font selection bounds may include substantial blank bearings. Retain the full
        // boxes we already accepted, instead of mistaking pixel-tight trimming for a cut glyph.
        for line in lines where envelope.contains(line.bounds) && bounds.intersects(line.bounds) {
            bounds = bounds.union(line.bounds.insetBy(dx: -2, dy: -2))
        }
        guard bounds.width >= 40, bounds.height >= 30, bounds.minY > captionBounds.maxY,
            bounds.minX > pageBounds.minX + 4, bounds.maxX < pageBounds.maxX - 4,
            bounds.maxY < pageBounds.maxY - 8,
            bounds.width * bounds.height < pageBounds.width * pageBounds.height * 0.8,
            !lines.contains(where: {
                $0.bounds.intersects(bounds) && !bounds.insetBy(dx: -2, dy: -2).contains($0.bounds)
            }),
            !barriers.contains(where: { $0.bounds.intersects(bounds) })
        else {
            diagnostic?(
                "ambiguous boundary \(bounds); caption \(captionBounds); cut text \(lines.filter { $0.bounds.intersects(bounds) && !bounds.insetBy(dx: -2, dy: -2).contains($0.bounds) }.map(\.bounds)); barriers \(barriers.filter { $0.bounds.intersects(bounds) }.map(\.bounds))"
            )
            return nil
        }
        return bounds
    }

    static func replacingFailedFigure(_ block: TextBlock, from page: PDFPage) throws -> TextBlock? {
        guard let caption = block.richContent?.figureCaption,
            let recovery = try recover(caption: caption.text, from: page)
        else { return nil }
        let image = recovery.image
        let notice = "图片已从原始 PDF 裁剪补全，图内文字保持原样。"
        var result = block
        result.text = caption.text
        result.hasImageFailure = false
        result.preservesSourcePage = nil
        result.imageWarnings = [notice]
        result.richContent = RichContent(
            html:
                "<figure><img src='\(image.dataURI)' width='\(image.width)' height='\(image.height)'>\(caption.html)<div class='image-notice'>\(notice)</div></figure>",
            translationInput: caption.translationInput, mathematics: caption.mathematics,
            mathDescriptions: caption.mathDescriptions,
            imageSizes: [PaperImageSize(width: image.width, height: image.height)], isFigure: true,
            imageTextForCoverage: recovery.coverageText, figureCaption: caption)
        return result
    }

    static func captionPage(_ caption: String, in document: PDFDocument) throws -> Int? {
        guard normalized(caption).count >= 12 else { return nil }
        var matches: [Int] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if let page = document.page(at: index), locate(caption, in: textLines(on: page)) != nil {
                matches.append(index)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func textLines(on page: PDFPage) -> [Line] {
        let fragments = (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []).compactMap {
            selection -> Line? in
            guard let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let bounds = selection.bounds(for: page)
            guard [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite), !bounds.isEmpty else {
                return nil
            }
            return Line(text: text, bounds: bounds)
        }.sorted { $0.bounds.midY > $1.bounds.midY }
        var rows: [[Line]] = []
        for fragment in fragments {
            if let row = rows.last, let first = row.first, abs(first.bounds.midY - fragment.bounds.midY) <= 2 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        var result: [Line] = []
        for row in rows {
            var merged: [Line] = []
            for fragment in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                if let last = merged.last, fragment.bounds.minX >= last.bounds.maxX - 2,
                    fragment.bounds.minX - last.bounds.maxX
                        < max(8, min(last.bounds.height, fragment.bounds.height) * 2)
                {
                    merged[merged.count - 1] = Line(
                        text: last.text + " " + fragment.text, bounds: last.bounds.union(fragment.bounds))
                } else {
                    merged.append(fragment)
                }
            }
            result += merged
        }
        return result
    }

    private static func locate(_ caption: String, in lines: [Line]) -> CGRect? {
        let needle = normalized(caption)
        var matches: [CGRect] = []
        for start in lines.indices {
            var text = ""
            var bounds = CGRect.null
            var previous: CGRect?
            for index in start..<min(lines.count, start + 30) {
                let current = lines[index].bounds
                if let previous {
                    if horizontalOverlap(current, lines[start].bounds) < min(current.width, lines[start].bounds.width)
                        * 0.3
                    {
                        continue
                    }
                    if current.maxY > previous.minY + 4 { continue }
                    if previous.minY - current.maxY > max(24, previous.height * 2.5) { break }
                }
                text += normalized(lines[index].text)
                bounds = bounds.union(lines[index].bounds)
                if text == needle {
                    matches.append(bounds)
                    break
                }
                if !needle.hasPrefix(text) { break }
                previous = current
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }

    static func rasterize(_ page: PDFPage, bounds: CGRect) throws -> PaperImage {
        try Task.checkCancellation()
        guard let reference = page.pageRef else { throw ReaderError.message("原始图件无法读取。") }
        let scale = min(3, 4_096 / max(bounds.width, bounds.height))
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ReaderError.message("无法准备原始图件裁剪。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(reference)
        let bytes = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
        else { throw ReaderError.message("原始图件裁剪失败。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), bytes.length <= 24_000_000 else {
            throw ReaderError.message("裁剪图件过大。")
        }
        return PaperImage(
            dataURI: "data:image/png;base64," + (bytes as Data).base64EncodedString(),
            width: Double(width), height: Double(height), notices: [])
    }
}
