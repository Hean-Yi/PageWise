import Foundation
import PDFKit

/// Original material excluded from bilingual prose. All rectangles are in unrotated PDF page coordinates.
struct PDFSourceRemainder {
    private(set) var bounds: [CGRect] = []
    private(set) var hasUnlocatedText = false

    mutating func add(_ rect: CGRect, within crop: CGRect) {
        guard !rect.isNull, !rect.isInfinite, rect.minX.isFinite, rect.minY.isFinite,
            rect.width.isFinite, rect.height.isFinite, !rect.isEmpty
        else {
            hasUnlocatedText = true
            return
        }
        let visible = rect.intersection(crop)
        if !visible.isEmpty { bounds.append(visible) }
    }

    mutating func add(_ range: Range<Int>, on page: PDFPage, source: NSString, within crop: CGRect) {
        let characters = source.substring(with: NSRange(range))
        guard !characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let selection = page.selection(for: NSRange(range)), selection.string == characters else {
            hasUnlocatedText = true
            return
        }
        let lines = selection.selectionsByLine()
        if lines.isEmpty { hasUnlocatedText = true }
        for line in lines { add(line.bounds(for: page), within: crop) }
    }

    /// Combine nearby omitted lines into readable excerpts. A neighboring reflowed sentence
    /// or a delivered table/figure must never become the middle of a rectangular excerpt.
    static func regions(
        for bounds: [CGRect], excluding images: [CGRect], sentences: [PDFSourceSentence], cropBox: CGRect
    ) -> [CGRect] {
        let coverage = images.map { $0.insetBy(dx: -1, dy: -1) }
        let remaining = bounds.filter { box in !coverage.contains(where: { $0.contains(box) }) }
        guard !remaining.isEmpty else { return [] }
        let body = sentences.flatMap { sentence in
            sentence.rects.compactMap { r -> CGRect? in
                guard r.count == 4 else { return nil }
                return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            }
        }

        let occupied = images + body
        // A typeset equation can have a distant number at the right margin. A region of
        // single-column prose establishes that these can share a row; two-column papers
        // otherwise keep the normal gutter between horizontal fragments.
        let left = body.filter { $0.maxX < cropBox.midX && $0.width > cropBox.width * 0.18 }
        let right = body.filter { $0.minX >= cropBox.midX && $0.width > cropBox.width * 0.18 }
        let singleColumn =
            body.filter { $0.width > cropBox.width * 0.52 }.count >= 3
            && !left.contains { l in right.contains { abs($0.midY - l.midY) < max(7, l.height) } }

        func includesOtherContent(_ area: CGRect) -> Bool {
            occupied.contains { other in
                let common = area.intersection(other)
                return common.width > 1 && common.height > min(2, other.height * 0.3)
            }
        }

        // Group horizontal fragments first, so that a vertical join cannot swallow the
        // neighboring column just because the previous line extends closer to its gutter.
        var lines: [CGRect] = []
        for box in remaining.sorted(by: precedes) {
            if let index = lines.lastIndex(where: { line in
                let height = min(line.height, box.height)
                let gap = max(line.minX, box.minX) - min(line.maxX, box.maxX)
                return abs(line.midY - box.midY) <= max(1, height * 0.48)
                    && (singleColumn || gap <= max(4, height * 1.6)) && !includesOtherContent(line.union(box))
            }) {
                lines[index] = lines[index].union(box)
            } else {
                lines.append(box)
            }
        }

        var groups: [(bounds: CGRect, last: CGRect)] = []
        for line in lines.sorted(by: precedes) {
            if let index = groups.lastIndex(where: { group in
                let last = group.last
                let height = max(last.height, line.height)
                let yGap = last.minY - line.maxY
                let xOverlap = min(last.maxX, line.maxX) - max(last.minX, line.minX)
                return line.midY < last.midY && yGap <= max(5, height * (singleColumn ? 1.8 : 0.95))
                    && (singleColumn || xOverlap >= min(last.width, line.width) * 0.4)
                    && !includesOtherContent(group.bounds.union(line))
            }) {
                groups[index] = (groups[index].bounds.union(line), line)
            } else {
                groups.append((line, line))
            }
        }
        // The rectangle for a multiline equation may already include an isolated superscript.
        // Keep just the containing excerpt in that case.
        var result: [CGRect] = []
        for group in groups.sorted(by: { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }) {
            let rect = group.bounds.insetBy(dx: -2, dy: -2).intersection(cropBox)
            if !result.contains(where: { $0.contains(rect) }) { result.append(rect) }
        }
        return result.sorted(by: precedes)
    }

    private static func precedes(_ a: CGRect, _ b: CGRect) -> Bool {
        a.midY == b.midY ? a.minX < b.minX : a.midY > b.midY
    }
}
