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
            if !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite, bounds.height > 1,
                bounds.width >= bounds.height
            {
                lines.append(.init(text: text, bounds: bounds))
            }
        }
        return text(in: lines, titlePage: pageIndex == 0)
    }

    static func text(in lines: [Line], titlePage: Bool = false) -> String? {
        let sorted = lines.sorted { $0.bounds.midY > $1.bounds.midY }
        guard let label = sorted.firstIndex(where: { AbstractPassage.withoutLabel($0.text) != nil }) else {
            return titlePage ? unlabelledAbstract(in: sorted) : nil
        }
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
            append(line.text, to: &body)
            previous = line
        }
        return nil
    }

    /// Some publishers put the abstract directly between the byline and the first numbered section.
    /// Require metadata above, a verified end below, and a separate, multi-line block of prose in between.
    private static func unlabelledAbstract(in rows: [Line]) -> String? {
        guard
            let end = rows.firstIndex(where: { line in
                let text = line.text
                return text.range(
                    of:
                        #"(?i)^(?:(?:1|I)[.)]?\s+)?(?:introduction|引言|绪论)\s*[.：:]?$|^(?:key\s*words?|index terms|关键词)\s*[:：.—–-]"#,
                    options: .regularExpression) != nil
            })
        else { return nil }
        var upper = end
        while upper > 0, isContactLine(rows[upper - 1].text) { upper -= 1 }
        guard upper >= 4 else { return nil }

        let last = rows[upper - 1]
        guard last.text.last.map({ ".!?。！？”’)]".contains($0) }) == true else { return nil }
        var lower = upper - 1
        while lower > 0 {
            let above = rows[lower - 1]
            let below = rows[lower]
            let height = last.bounds.height
            let distance = above.bounds.midY - below.bounds.midY
            guard distance > height * 0.4, distance < height * 1.9,
                abs(above.bounds.minX - below.bounds.minX) < max(20, height * 1.8),
                (0.78...1.26).contains(above.bounds.height / height), !isContactLine(above.text)
            else { break }
            lower -= 1
        }
        let block = rows[lower..<upper]
        guard lower >= 2, block.count >= 3, let first = block.first,
            first.text.first.map({ $0.isUppercase || AbstractPassage.containsChinese(first.text) }) == true,
            // Affiliation numbers are often glued to the first word in the PDF text layer.
            rows[..<lower].suffix(10).contains(where: {
                $0.text.range(
                    of:
                        #"(?i)(?:university|institute|college|laborator(?:y|ies)|department|research|universit[äé]|大学|研究所)|@|[\d†‡*][\s,，]+\p{Lu}"#,
                    options: .regularExpression) != nil
            })
        else { return nil }

        // A competing paragraph or caption above the proposed start would make the boundary ambiguous.
        let preceding = rows[lower - 1].text
        if preceding.count > 60, preceding.last.map({ ".!?。！？".contains($0) }) == true,
            !isContactLine(preceding)
        {
            return nil
        }
        var body = ""
        for line in block {
            guard body.utf8.count + line.text.utf8.count < 48_000 else { return nil }
            append(line.text, to: &body)
        }
        guard body.count >= 130, body.filter({ ".!?。！？".contains($0) }).count >= 2 else { return nil }
        return body
    }

    private static func isContactLine(_ text: String) -> Bool {
        text.range(
            of:
                #"(?i)^(?:[*†‡]\s*)?(?:correspond(?:ence|ing author)|contacts?|e-?mail|date|published|code|project(?: page)?|website|equal contribution)\s*[:：\s]|^(?:https?://|www\.|github\.com/)|^\S+@\S+$"#,
            options: .regularExpression) != nil
    }

    private static func append(_ line: String, to body: inout String) {
        if !body.isEmpty {
            switch PDFEnglishLineBreak.separator(after: body, before: line, spellings: []) {
            case .space: body += " "
            case .removeHyphen: body.removeLast()
            case .joined: break
            }
        }
        body += line
    }
}
