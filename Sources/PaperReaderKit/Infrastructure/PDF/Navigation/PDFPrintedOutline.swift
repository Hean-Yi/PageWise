import Foundation
import PDFKit

#if os(macOS)
    import AppKit
    private typealias OutlineFont = NSFont
#else
    import UIKit
    private typealias OutlineFont = UIFont
#endif

/// Reads printed headings only when a document has no usable embedded outline.
enum PDFPrintedOutline {
    private struct Line {
        let text: String
        let range: NSRange
        let size: CGFloat
        let bold: Bool
    }

    private struct Numbering {
        let section: String
        let subsection: String?
        let title: String
    }

    private static let numbering = try! NSRegularExpression(
        pattern: #"^([1-9][0-9]?|[IVXLCDM]{2,6}|[A-Z])(?:\.([1-9][0-9]?))?\.?\s+(\p{L}.*)$"#)
    private static let familiarTitles: Set<String> = [
        "abstract", "introduction", "background", "related work", "related works", "preliminaries",
        "materials and methods", "methods", "methodology", "experiments", "results", "discussion",
        "results and discussion", "limitations", "conclusion", "conclusions", "future work",
        "acknowledgments", "acknowledgements", "references", "bibliography", "appendix", "appendices",
    ]

    static func items(in document: PDFDocument, paperID: UUID, pageCount: Int) throws -> [PaperNavigationItem] {
        let count = min(document.pageCount, pageCount)
        guard count > 0 else { return [] }
        // Long prose lines provide a more reliable body-size sample than labels, equations and footnotes.
        var sample: [Int: Int] = [:]
        var seenRoots: Set<String> = []
        var seenChildren: Set<String> = []
        var currentSection: String?
        var nextLetter: Character?
        var headings: [PaperNavigationItem] = []
        var reachedReferences = false

        for pageIndex in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex), let attributed = page.attributedString else { continue }
            let lines = readLines(attributed)
            if pageIndex < 5 || sample.isEmpty {
                for line in lines where line.text.count >= 40 && line.size > 0 && line.size < 512 {
                    sample[Int((line.size * 2).rounded()), default: 0] += line.text.count
                }
            }
            let body =
                CGFloat(sample.keys.sorted().max(by: { sample[$0, default: 0] < sample[$1, default: 0] }) ?? 20) / 2
            for (index, line) in lines.enumerated() {
                guard line.text.count <= 160, line.size >= body * 0.89 else { continue }
                let number = parseNumber(line.text)
                let name = (number?.title ?? line.text).lowercased()
                let familiar = familiarTitles.contains(name)
                let prominent = line.size >= body * 1.09 || line.bold
                let depth: Int
                if let number {
                    guard plausibleTitle(number.title),
                        number.subsection != nil || !number.title.hasSuffix(".")
                    else { continue }
                    if let subsection = number.subsection {
                        guard currentSection == number.section,
                            seenChildren.insert(number.section + "." + subsection).inserted
                        else { continue }
                        depth = 1
                    } else if let expected = nextLetter, number.section == String(expected),
                        line.text.hasPrefix(number.section + "."), line.size >= body * 0.96
                    {
                        // IEEE-style outlines use A., B., ... within each Roman-numbered section.
                        nextLetter = expected.asciiValue.flatMap { $0 < 90 ? Character(UnicodeScalar($0 + 1)) : nil }
                        depth = 1
                    } else {
                        guard prominent || (familiar && line.size >= body * 0.96),
                            !(reachedReferences && Int(number.section) != nil),
                            seenRoots.insert(number.section).inserted
                        else { continue }
                        let isRoman =
                            number.section == "I"
                            || (nextLetter != nil
                                && number.section.allSatisfy { "IVXLCDM".contains($0) })
                        nextLetter = isRoman ? "A" : nil
                        currentSection = number.section
                        depth = 0
                    }
                } else {
                    guard familiar, prominent || line.text == line.text.uppercased(),
                        seenRoots.insert(name).inserted
                    else { continue }
                    currentSection = nil
                    nextLetter = nil
                    if name == "references" || name == "bibliography" { reachedReferences = true }
                    depth = 0
                }

                guard let bounds = page.selection(for: line.range)?.bounds(for: page), !bounds.isEmpty else { continue }
                var title = line.text
                var range = line.range
                if !familiar, lines.indices.contains(index + 1) {
                    let next = lines[index + 1]
                    if isContinuation(next, of: line, bounds: bounds, page: page, prominent: prominent) {
                        title += " " + next.text
                        range = NSUnionRange(range, next.range)
                    }
                }
                headings.append(
                    PaperNavigationItem(
                        id: "\(paperID.uuidString)-text-\(pageIndex)-\(range.location)", title: title,
                        sourcePage: pageIndex,
                        depth: depth, isOutline: true, sourceRange: range,
                        sourcePoint: CGPoint(x: bounds.minX, y: bounds.maxY)))
            }
        }
        return headings
    }

    private static func readLines(_ attributed: NSAttributedString) -> [Line] {
        let string = attributed.string as NSString
        var lines: [Line] = []
        var offset = 0
        while offset < string.length {
            var start = 0
            var end = 0
            var contentEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
            offset = end
            let lineRange = NSRange(location: start, length: contentEnd - start)
            let trimmed = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let range = string.range(of: trimmed, options: .literal, range: lineRange)
            guard range.location != NSNotFound,
                let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? OutlineFont
            else { continue }
            let text = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let bold = font.fontName.lowercased().contains("bold")
            lines.append(Line(text: text, range: range, size: font.pointSize, bold: bold))
        }
        return lines
    }

    private static func parseNumber(_ text: String) -> Numbering? {
        let string = text as NSString
        guard let match = numbering.firstMatch(in: text, range: NSRange(location: 0, length: string.length)) else {
            return nil
        }
        let section = string.substring(with: match.range(at: 1))
        // An English title starting with the article “A” has no lettered section marker.
        if section.count == 1, section.first?.isLetter == true, match.range(at: 2).location == NSNotFound,
            !text.hasPrefix(section + ".")
        {
            return nil
        }
        return Numbering(
            section: section,
            subsection: match.range(at: 2).location == NSNotFound ? nil : string.substring(with: match.range(at: 2)),
            title: string.substring(with: match.range(at: 3)))
    }

    private static func plausibleTitle(_ text: String) -> Bool {
        guard let first = text.first, !first.isLowercase, let last = text.last,
            !",;".contains(last), !text.contains(" . . "), text.split(separator: " ").count <= 22
        else { return false }
        return true
    }

    private static func isContinuation(
        _ next: Line, of line: Line, bounds: CGRect, page: PDFPage, prominent: Bool
    ) -> Bool {
        guard abs(next.size - line.size) < 0.3, next.bold == line.bold, parseNumber(next.text) == nil,
            !familiarTitles.contains(next.text.lowercased()), next.text.count + line.text.count < 160,
            let first = next.text.first, first.isLetter, let last = next.text.last, !".,;".contains(last),
            let box = page.selection(for: next.range)?.bounds(for: page)
        else { return false }
        let drop = bounds.maxY - box.maxY
        let indent = box.minX - bounds.minX
        // A body-sized numbered heading can wrap with a hanging indent before the first paragraph.
        guard prominent || indent >= line.size * 0.8 else { return false }
        return abs(indent) <= line.size * 4 && drop > 0.4 * line.size && drop < 1.65 * line.size
    }
}
