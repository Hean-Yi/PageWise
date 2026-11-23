import Foundation
import NaturalLanguage
import PDFKit

/// PDFKit sometimes emits a single token for several visibly spaced words on tightly justified lines.
/// Only add a space where an actual band of blank pixels separates two independently attested words.
final class PDFEnglishWordSpacing {
    private let page: PDFPage
    private lazy var inkMap = PageInk(page: page)
    // Tightly justified PDFs can lose most spaces on one line and just one on the next.
    private lazy var denselySet = page.string?.firstMatch(of: /[a-z]{26,}/) != nil

    init(page: PDFPage) { self.page = page }

    func sourceRanges(
        for range: NSRange, in source: NSString, bounds: CGRect, spellings: Set<String>
    )
        -> [NSRange]
    {
        let text = source.substring(with: range)
        guard (18...380).contains(range.length), (6...25).contains(bounds.height),
            bounds.width > bounds.height * 7
        else { return [range] }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard denselySet || words.count * 9 <= range.length || words.contains(where: { $0.utf8.count >= 18 }) else {
            return [range]
        }
        let tokens = text.matches(of: /[A-Za-z0-9_]+/).filter {
            $0.output.utf8.count >= 4 && $0.output.first?.isLetter == true
                && ($0.output.dropFirst().allSatisfy { $0.isLowercase || $0.isNumber }
                    || $0.output.wholeMatch(of: /[A-Za-z][a-z]+[A-Z]{2,}/) != nil)
        }
        guard denselySet || tokens.contains(where: { $0.output.utf8.count >= 9 }) else { return [range] }
        let vocabulary = NLEmbedding.wordEmbedding(for: .english)
        let candidates = tokens.filter { vocabulary?.contains($0.output.lowercased()) != true }
        let punctuation =
            denselySet
            ? text.matches(of: /[a-zA-Z]{2,}[,;:]([a-zA-Z])|[a-zA-Z](\[[0-9])|\]([a-zA-Z])/)
            : []
        guard
            (denselySet && (!candidates.isEmpty || !punctuation.isEmpty)) || candidates.count >= 2
                || candidates.contains(where: { $0.output.utf8.count >= 14 }),
            let ink = inkMap?.line(in: bounds)
        else { return [range] }
        var offsets = [Int]()
        for candidate in candidates {
            let local = NSRange(candidate.range, in: text)
            let token = candidate.output
            let start = range.location + local.location
            // Source and display indices coincide inside the ASCII token. Selection bounds, as
            // opposed to characterBounds(at:), index the same string as PDFKit's text selection.
            let boxes = (start..<(start + local.length)).compactMap {
                page.selection(for: NSRange(location: $0, length: 1))?.bounds(for: page)
            }
            guard boxes.count == local.length else { continue }
            let gaps = zip(boxes, boxes.dropFirst()).map { ink.blankWidth(from: $0.midX, to: $1.midX) }
            let ordinary = gaps.sorted()[(gaps.count - 1) / 2]
            // The measured width is quantized at both edges of the painted gap.
            let minimum = max(bounds.height * 0.17, ordinary * 2.3 + 0.25) - 0.8 / ink.scale
            let breaks = gaps.indices.filter { gaps[$0] >= minimum }.map { $0 + 1 }
            guard !breaks.isEmpty else { continue }
            let boundaries = [0] + breaks + [local.length]
            let spelling = token.lowercased() as NSString
            let recognized = zip(boundaries, boundaries.dropFirst()).map { a, b in
                let part = spelling.substring(with: NSRange(location: a, length: b - a))
                let acronym = token.utf8.dropFirst(a).prefix(b - a)
                let capitalized = (2...8).contains(acronym.count) && acronym.allSatisfy { (65...90).contains($0) }
                let possessive =
                    start > 0 && a == 0 && part == "s" && [39, 0x2019].contains(source.character(at: start - 1))
                return capitalized || possessive || part.allSatisfy(\.isNumber) || part == "a" || part == "i"
                    || (part.count >= 2 && (spellings.contains(part) || vocabulary?.contains(part) == true))
            }
            let corroborated = breaks.indices.filter { recognized[$0] && recognized[$0 + 1] }
            let widths = corroborated.map { gaps[breaks[$0] - 1] }.sorted()
            for (index, offset) in breaks.enumerated() {
                // Neighbouring confirmed words establish the publisher's word spacing even when
                // an inflection or a technical term is absent from the device vocabulary.
                let sameSpacing =
                    widths.count >= 2 && (recognized[index] || recognized[index + 1])
                    && gaps[offset - 1] >= widths[widths.count / 2] * 0.78
                if (recognized[index] && recognized[index + 1]) || sameSpacing { offsets.append(start + offset) }
            }
        }
        for match in punctuation {
            guard let marker = match.1 ?? match.2 ?? match.3 else { continue }
            let i = range.location + NSRange(marker.startIndex..<marker.endIndex, in: text).location
            guard let previous = page.selection(for: NSRange(location: i - 1, length: 1))?.bounds(for: page),
                let next = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page),
                ink.blankWidth(from: previous.midX, to: next.midX) >= bounds.height * 0.20
            else { continue }
            offsets.append(i)
        }
        let boundaries = [range.location] + offsets.sorted() + [NSMaxRange(range)]
        return zip(boundaries, boundaries.dropFirst()).map { NSRange(location: $0, length: $1 - $0) }
    }

    /// Render at most one bounded grayscale page per extraction, and only on pages with suspicious text.
    private struct PageInk {
        let cropBox: CGRect
        let scale: CGFloat
        let bitmap: CGContext

        init?(page: PDFPage) {
            guard let reference = page.pageRef, reference.rotationAngle % 360 == 0 else { return nil }
            cropBox = page.bounds(for: .cropBox)
            let area = cropBox.width * cropBox.height
            guard area.isFinite, area > 0 else { return nil }
            scale = min(5, sqrt(6_000_000 / area), 4_096 / max(cropBox.width, cropBox.height))
            guard scale >= 2,
                let bitmap = CGContext(
                    data: nil, width: Int(ceil(cropBox.width * scale)), height: Int(ceil(cropBox.height * scale)),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            self.bitmap = bitmap
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            bitmap.scaleBy(x: scale, y: scale)
            bitmap.translateBy(x: -cropBox.minX, y: -cropBox.minY)
            bitmap.drawPDFPage(reference)
        }

        func line(in bounds: CGRect) -> LineInk? {
            let x0 = max(0, Int(floor((bounds.minX - cropBox.minX) * scale)))
            let x1 = min(bitmap.width, Int(ceil((bounds.maxX - cropBox.minX) * scale)))
            let y0 = max(0, bitmap.height - Int(ceil((bounds.maxY - cropBox.minY) * scale)))
            let y1 = min(bitmap.height, bitmap.height - Int(floor((bounds.minY - cropBox.minY) * scale)))
            guard x0 < x1, y0 < y1, let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let stride = bitmap.bytesPerRow
            let columns = (x0..<x1).map { x in (y0..<y1).contains { y in pixels[y * stride + x] < 180 } }
            return LineInk(origin: cropBox.minX + CGFloat(x0) / scale, scale: scale, columns: columns)
        }
    }

    private struct LineInk {
        let origin: CGFloat
        let scale: CGFloat
        let columns: [Bool]

        func blankWidth(from left: CGFloat, to right: CGFloat) -> CGFloat {
            let start = max(0, Int(ceil((left - origin) * scale)))
            let end = min(columns.count, Int(floor((right - origin) * scale)) + 1)
            guard start < end else { return 0 }
            var widest = 0
            var run = 0
            for x in start..<end {
                run = columns[x] ? 0 : run + 1
                widest = max(widest, run)
            }
            return CGFloat(widest) / scale
        }
    }
}
