import Foundation
import PDFKit

/// A complex table can still contain a simple, independently readable left-hand label/value pair.
/// Only that pair and explicit group titles go to the analysis. Never infer missing cells or reuse
/// headers across an interruption, and never present the subset as a reconstruction of the table.
enum PDFTableEvidenceColumn {
    private struct Token {
        let text: String
        var box: CGRect
    }

    static func rows(on page: PDFPage, in bounds: CGRect) throws -> String? {
        guard page.rotation % 360 == 0, (1...70_000).contains(page.numberOfCharacters), !bounds.isEmpty,
            let raw = page.string as NSString?, raw.length == page.numberOfCharacters,
            let selection = page.selection(for: bounds), (1...1_000).contains(selection.numberOfTextRanges(on: page))
        else { return nil }
        var tokens: [Token] = []
        for index in 0..<selection.numberOfTextRanges(on: page) {
            try Task.checkCancellation()
            let range = selection.range(at: index, on: page)
            guard range.location >= 0, range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= raw.length
            else { return nil }
            for word in words.matches(in: raw as String, range: range) {
                guard tokens.count < 2_000, let part = page.selection(for: word.range) else { return nil }
                let value = raw.substring(with: word.range)
                let box = part.bounds(for: page)
                guard part.string == value, !box.isEmpty, bounds.insetBy(dx: -1, dy: -1).contains(box),
                    !value.unicodeScalars.contains(where: {
                        $0.properties.generalCategory == .privateUse || $0 == "\u{fffd}"
                    })
                else { return nil }
                tokens.append(Token(text: value, box: box))
            }
        }
        var lines: [[Token]] = []
        for item in tokens.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = lines.last?.first,
                abs(first.box.midY - item.box.midY) <= min(first.box.height, item.box.height) * 0.32
            {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        let rows = lines.map { line in
            var cells: [Token] = []
            for word in line.sorted(by: { $0.box.minX < $1.box.minX }) {
                if let last = cells.last, word.box.minX - last.box.maxX < min(last.box.height, word.box.height) * 0.28 {
                    cells[cells.count - 1] = Token(text: last.text + " " + word.text, box: last.box.union(word.box))
                } else {
                    cells.append(word)
                }
            }
            return cells
        }
        // The column title must be a leaf at the same x coordinate as the data. A title spanning
        // multiple ensuing numeric columns is a grouped label and cannot identify one value.
        for (index, header) in rows.prefix(8).enumerated() {
            guard header.count >= 3, header[0].text.contains(where: \.isLetter),
                header[1].text.contains(where: \.isLetter),
                !header[1].text.contains(where: \.isNumber),
                header[0].box.maxX < header[1].box.minX, header[1].box.maxX < header[2].box.minX
            else { continue }
            var result: [String] = ["分组\t" + header[0].text + "\t" + header[1].text]
            var group = ""
            for row in rows.dropFirst(index + 1) {
                guard let first = row.first else { continue }
                if row.count == 1, first.text.count <= 75, first.text.contains(where: \.isLetter),
                    first.box.midX > header[1].box.maxX
                {
                    // Preserve explicit spanning group titles, e.g. the model or dataset name.
                    group = first.text
                    continue
                }
                if row.allSatisfy({ $0.box.minX > header[1].box.maxX }) && result.count == 1 {
                    // Multi-level headers may subdivide separate columns to the right.
                    continue
                }
                guard row.count >= 3, first.text.contains(where: \.isLetter), first.box.maxX < row[1].box.minX,
                    first.box.midX < header[1].box.minX,
                    number.firstMatch(in: row[1].text, range: NSRange(row[1].text.startIndex..., in: row[1].text))
                        != nil,
                    abs(row[1].box.midX - header[1].box.midX)
                        <= max(header[1].box.height * 0.8, header[1].box.width * 0.26),
                    row[2].box.minX > max(row[1].box.maxX, header[1].box.maxX)
                else { break }
                result.append([group, first.text, row[1].text].joined(separator: "\t"))
            }
            if result.count >= 4 { return result.joined(separator: "\n") }
        }
        return nil
    }

    private static let words = try! NSRegularExpression(pattern: #"\S+"#)
    private static let number = try! NSRegularExpression(pattern: #"^[+−-]?\d+(?:[.,]\d+)*%?$"#)
}
