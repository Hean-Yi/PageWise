import Foundation
import PDFKit

/// Match printed list and section markers before interpreting horizontal whitespace as a gutter.
enum PDFProseMarkers {
    typealias Line = PDFSentenceExtractor.Line
    private static let bullets = "•◦▪‣⁃●○"

    static func startsItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if bullets.contains(first) { return true }
        guard first == "(" || first.isNumber else { return false }
        return text.range(of: #"^(?:\([a-zA-Z0-9]{1,3}\)|\d{1,3}[.)])\s+\p{L}"#, options: .regularExpression) != nil
    }

    /// The next baseline of a hanging list aligns with the printed text, even when the PDFKit
    /// selection reports the marker and the first word as one run.
    static func continuesItem(after line: Line, with next: Line, source: NSString, page: PDFPage) -> Bool {
        let value = PDFSentenceExtractor.content(line, source: source)
        guard startsItem(value), let first = line.runs.first else { return false }
        let runText = source.substring(with: first.range) as NSString
        let expression = #"^(?:[•◦▪‣⁃●○]|\([a-zA-Z0-9]{1,3}\)|\d{1,3}[.)])\s*"#
        let prefix = runText.range(of: expression, options: .regularExpression)
        guard prefix.location != NSNotFound else { return false }
        let offset = NSMaxRange(prefix)
        let start: CGFloat
        if offset < first.range.length {
            let initial = NSRange(location: first.range.location + offset, length: 1)
            guard let box = page.selection(for: initial)?.bounds(for: page), !box.isEmpty else { return false }
            start = box.minX
        } else if line.runs.count > 1 {
            start = line.runs[1].bounds.minX
        } else {
            return false
        }
        return abs(next.bounds.minX - start) <= max(2, next.bounds.height * 0.6)
    }

    static func attach(in rows: [[Line]], source: NSString) -> [[Line]] {
        rows.enumerated().map { index, row in
            guard row.count > 1 else { return row }
            var result = [Line]()
            for line in row {
                if let label = result.last, canAttach(label, to: line, in: rows, at: index, source: source) {
                    result[result.count - 1] = Line(
                        runs: label.runs + line.runs, bounds: label.bounds.union(line.bounds))
                } else {
                    result.append(line)
                }
            }
            return result
        }
    }

    private static func canAttach(_ label: Line, to line: Line, in rows: [[Line]], at index: Int, source: NSString)
        -> Bool
    {
        let mark = PDFSentenceExtractor.content(label, source: source)
        guard mark.count <= 8, let last = label.runs.last, let first = line.runs.first else { return false }
        let height = max(line.bounds.height, label.bounds.height)
        let gap = line.bounds.minX - label.bounds.maxX
        guard gap >= 0, gap <= height * 3.4, abs(line.bounds.midY - label.bounds.midY) <= height * 0.4 else {
            return false
        }
        let value = PDFSentenceExtractor.content(line, source: source)
        guard value.first?.isLetter == true else { return false }
        if mark.count == 1, let bullet = mark.first, bullets.contains(bullet) { return true }
        guard mark.range(of: #"^\d+(?:\.\d+)*\.?$"#, options: .regularExpression) != nil,
            value.first?.isUppercase == true, value.last.map({ !".,;:".contains($0) }) == true,
            value.count < 85, abs(label.bounds.height - line.bounds.height) <= height * 0.25
        else { return false }
        // A section has prose beneath it within the same column, set off from its heading.
        // This also keeps adjacent numeric table cells or chart labels independent.
        let section = label.bounds.union(line.bounds)
        let following = rows.dropFirst(index + 1).prefix(5).flatMap { $0 }.first {
            let b = $0.bounds
            let overlap = min(b.maxX, section.maxX) - max(b.minX, section.minX)
            return overlap > min(section.width, b.width) * 0.36 && b.width > height * 6
        }
        guard let following, section.midY - following.bounds.midY >= height * 1.2,
            section.midY - following.bounds.midY <= height * 5.5
        else { return false }
        let between = NSRange(
            location: NSMaxRange(last.range), length: max(0, first.range.location - NSMaxRange(last.range)))
        guard first.range.location >= NSMaxRange(last.range), between.length <= 16 else { return false }
        return source.substring(with: between).allSatisfy(\.isWhitespace)
    }
}
