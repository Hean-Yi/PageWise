import Foundation
import PDFKit

/// On title pages the publication history or license can run alongside the abstract.
enum PDFAbstractColumn {
    struct Line {
        let text: String
        let bounds: CGRect
    }

    static func read(url: URL, pageIndex: Int) throws -> String? {
        guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex),
            page.rotation % 360 == 0, (1...70_000).contains(page.numberOfCharacters),
            let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))
        else { return nil }
        defer { withExtendedLifetime(document) {} }
        var lines: [Line] = []
        for row in selection.selectionsByLine() {
            try Task.checkCancellation()
            guard let text = row.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                continue
            }
            let bounds = row.bounds(for: page)
            if !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite, bounds.height > 1 {
                lines.append(.init(text: text, bounds: bounds))
            }
        }
        return text(in: lines)
    }

    static func text(in lines: [Line]) -> String? {
        let sorted = lines.sorted { $0.bounds.midY > $1.bounds.midY }
        guard let label = sorted.firstIndex(where: { AbstractPassage.withoutLabel($0.text) != nil }) else { return nil }
        let heading = sorted[label]
        let inline = AbstractPassage.withoutLabel(heading.text) ?? ""
        let below = sorted.dropFirst(label + 1)
        guard
            let first = below.first(where: {
                $0.bounds.midY < heading.bounds.midY - 2 && heading.bounds.minY - $0.bounds.maxY < 45
                    && $0.bounds.minX - 12 <= heading.bounds.midX && $0.bounds.maxX + 12 >= heading.bounds.midX
                    && $0.text.count >= 10
            })
        else { return nil }
        let indent = max(16, min(46, first.bounds.width * 0.14))
        let margin = first.bounds.minX
        var body = inline
        var previous: Line?
        for line in below where line.bounds.midY <= first.bounds.midY + 1 {
            guard abs(line.bounds.minX - margin) <= indent else { continue }
            if let previous {
                let gap = previous.bounds.minY - line.bounds.maxY
                let heading =
                    AbstractPassage.ends(at: line.text)
                    || (line.text.count < 85 && line.bounds.height > first.bounds.height * 1.24 && gap > 3)
                if heading { return body.isEmpty ? nil : body }
                // Another block interrupts the column without a verifiable section boundary.
                guard gap < max(34, first.bounds.height * 3.7) else { return nil }
            }
            guard body.utf8.count + line.text.utf8.count < 48_000 else { return nil }
            if !body.isEmpty {
                switch PDFEnglishLineBreak.separator(after: body, before: line.text, spellings: []) {
                case .space: body += " "
                case .removeHyphen: body.removeLast()
                case .joined: break
                }
            }
            body += line.text
            previous = line
        }
        return nil
    }
}
