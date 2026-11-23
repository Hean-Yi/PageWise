import CoreText
import Foundation
import PDFKit

/// A byline is original front matter. Keep each author's affiliations and contact details together
/// when a publisher prints several cards across the page.
struct PDFBylineExtractor {
    typealias Line = PDFSentenceExtractor.Line

    let rows: Range<Int>
    let bounds: CGRect
    /// Nil when the complete region is more faithful than linearizing its text layer.
    let paragraphs: [String]?

    static func locate(in rows: [[Line]], on page: PDFPage, source: NSString) -> Self? {
        let crop = page.bounds(for: .cropBox)
        guard let attributed = page.attributedString, attributed.string == source as String else { return nil }
        let sizes = rows.map { row in row.map { fontSize(of: $0, in: attributed) }.max() ?? 0 }
        func box(_ row: [Line]) -> CGRect { row.reduce(CGRect.null) { $0.union($1.bounds) } }
        let boxes = rows.map(box)
        let bodySizes = rows.indices.filter {
            boxes[$0].midY < crop.midY + crop.height * 0.1 && boxes[$0].width > crop.width * 0.18 && sizes[$0] > 0
        }.map { sizes[$0] }.sorted()
        guard !bodySizes.isEmpty else { return nil }
        let bodySize = bodySizes[bodySizes.count / 2]
        let top = rows.indices.filter {
            boxes[$0].midY > crop.minY + crop.height * 0.61 && boxes[$0].width > crop.width * 0.17
                && rows[$0].count == 1
        }
        guard let largest = top.map({ sizes[$0] }).max(), largest >= bodySize * 1.20,
            let title = top.first(where: { sizes[$0] >= largest * 0.95 })
        else { return nil }
        var endTitle = title
        while rows.indices.contains(endTitle + 1) {
            let next = endTitle + 1
            let pitch = boxes[endTitle].midY - boxes[next].midY
            let text = rowText(rows[next], source: source)
            let sameTitleSize = sizes[next] >= largest * 0.89 && pitch <= largest * 1.7
            let subtitle =
                sizes[next] > bodySize * 1.13 && pitch <= largest * 1.50 && text.split(separator: " ").count >= 4
            let marked = text.contains(where: { $0.isNumber || $0 == "@" || $0 == "†" || $0 == "*" })
            guard rows[next].count == 1, pitch > 0, sameTitleSize || (subtitle && !marked),
                !isSection(text)
            else { break }
            endTitle = next
        }
        let start = endTitle + 1
        guard rows.indices.contains(start) else { return nil }
        let first = rowText(rows[start], source: source)
        guard resemblesNames(first) || isOrganization(first) else { return nil }
        var end = start
        var projectLinks = false
        for index in start..<rows.count {
            let values = rows[index].map { PDFSentenceExtractor.content($0, source: source) }
            if values.contains(where: { isSection($0) || isProse($0) }) { break }
            let resource = values.contains { $0.contains("/") }
            if projectLinks && !resource && !values.contains(where: { $0.contains("@") || isOrganization($0) }) {
                break
            }
            projectLinks = resource
            if index > start, boxes[index - 1].midY - boxes[index].midY > max(42, bodySize * 4.0) { break }
            // A dense row of tiny labels after the byline usually begins a figure.
            if index > start, sizes[index] < sizes[start] * 0.75, rows[index].count >= 3 {
                let following = rows.indices.dropFirst(index + 1).prefix {
                    boxes[index].midY - boxes[$0].midY <= sizes[start] * 4
                }
                let moreCredits = following.contains { next in
                    let text = rowText(rows[next], source: source)
                    return sizes[next] >= sizes[start] * 0.86
                        && (isOrganization(text) || (resemblesNames(text) && text.contains(where: \.isNumber)))
                }
                if !moreCredits { break }
            }
            end = index + 1
        }
        guard end > start else { return nil }
        let range = start..<end
        let area = boxes[range].reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -1, dy: -1).intersection(crop)
        let data = rows[range].map { row in row.map { Field(line: $0, source: source, attributes: attributed) } }
        // Some PDFs report the text of an embedded figure interleaved with the real byline.
        // Do not expose those labels as author names or assign uncertain marks to a person.
        let interleaved = zip(range, range.dropFirst()).contains {
            boxes[$0].midY - boxes[$1].midY < min(sizes[$0], sizes[$1]) * 0.73
        }
        let unreliable = interleaved || data.joined().contains { !$0.reliable }
        return Self(rows: range, bounds: area, paragraphs: unreliable ? nil : readingOrder(data, pageWidth: crop.width))
    }

    func item(before sentences: [PDFSourceSentence]) -> PDFReadingIllustration? {
        guard let paragraphs else { return nil }
        let next = sentences.first { sentence in
            guard let b = sentence.rects.first, b.count == 4 else { return false }
            return b[1] + b[3] / 2 < bounds.minY
        }
        return PDFReadingIllustration(
            id: "p0-byline", label: "作者与机构", pageIndex: 0, sourceBounds: bounds,
            insertBeforeSentenceID: next?.id, imagePNG: nil, originalText: .init(kind: .byline, paragraphs: paragraphs))
    }

    /// Conference papers often print numbered affiliations in a small footnote and finish
    /// with a contact address. Include wrapped lines in that column, keeping neighboring prose.
    static func affiliationFootnotes(in rows: [[Line]], on page: PDFPage, source: NSString) -> Set<Int> {
        let crop = page.bounds(for: .cropBox)
        let foot = rows.flatMap { $0 }.filter { $0.bounds.midY < crop.minY + crop.height * 0.36 }
        let contacts = foot.filter { PDFSentenceExtractor.content($0, source: source).contains("@") }
        guard !contacts.isEmpty, let attributes = page.attributedString, attributes.string == source as String else {
            return []
        }
        var excluded = Set<Int>()
        for contact in contacts {
            let lineSize = fontSize(of: contact, in: attributes)
            guard lineSize > 0 else { continue }
            let sameColumn = foot.filter {
                let overlap = min(contact.bounds.maxX, $0.bounds.maxX) - max(contact.bounds.minX, $0.bounds.minX)
                return overlap > 0 && abs(contact.bounds.minX - $0.bounds.minX) <= lineSize * 2
            }.sorted { $0.bounds.midY < $1.bounds.midY }
            var group = [contact]
            for previous in sameColumn where previous.bounds.midY > contact.bounds.midY {
                let pitch = previous.bounds.midY - group.last!.bounds.midY
                let size = fontSize(of: previous, in: attributes)
                guard pitch >= lineSize * 0.7, pitch <= lineSize * 1.6, abs(size - lineSize) <= lineSize * 0.10 else {
                    break
                }
                group.append(previous)
            }
            let text = group.reversed().map { PDFSentenceExtractor.content($0, source: source) }.joined(separator: " ")
            let marked =
                text.range(
                    of: #"^\s*(?:[\d*†‡∗]|equal\s+(?:contribution|advising)|correspondence\b)"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
            guard marked && (isOrganization(text) || text.localizedCaseInsensitiveContains("correspondence")) else {
                continue
            }
            excluded.formUnion(group.flatMap(\.runs).map(\.range.location))
        }
        return excluded
    }

    private static func rowText(_ row: [Line], source: NSString) -> String {
        row.map { PDFSentenceExtractor.content($0, source: source) }.joined(separator: " ")
    }

    private static func fontSize(of line: Line, in text: NSAttributedString) -> CGFloat {
        var largest: CGFloat = 0
        for run in line.runs {
            text.enumerateAttribute(.init(kCTFontAttributeName as String), in: run.range) { value, _, _ in
                guard let value, CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return }
                largest = max(largest, CTFontGetSize(value as! CTFont))
            }
        }
        return largest
    }

    private static func isSection(_ text: String) -> Bool {
        text.range(
            of:
                #"^\s*(?:(?:[1I][.)]?\s+)?(?:abstract|introduction|keywords|index terms)\b|(?:fig(?:ure)?|table)\.?\s+\d)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func resemblesNames(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter }).filter { !$0.isEmpty }
        let uppercase = words.filter { $0.first?.isUppercase == true }.count
        return words.count >= 2 && uppercase >= 2 && uppercase * 3 >= words.count * 2
    }

    private static func isOrganization(_ text: String) -> Bool {
        text.range(
            of:
                #"(?<!\p{L})(universit\w*|institut\w*|department|college|school|laborator\w*|labs?|research|team|centre|center)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isProse(_ text: String) -> Bool {
        if text.contains("@") || text.contains("://") { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        let lowercase = words.filter { $0.first?.isLowercase == true }.count
        let sentenceEnd = text.last.map { ".!?".contains($0) } == true
        guard words.count >= (sentenceEnd ? 4 : 6), lowercase * 3 >= words.count * 2 else { return false }
        let lower = text.lowercased()
        return !["correspond", "contribut", "internship", "work done", "listed alphabetically"].contains {
            lower.contains($0)
        } && !(isOrganization(text) && text.first?.isNumber == true)
    }

    private struct Field {
        let text: String
        let bounds: CGRect
        let reliable: Bool

        init(line: Line, source: NSString, attributes: NSAttributedString) {
            bounds = line.bounds
            var value = ""
            var previous: PDFSentenceExtractor.Run?
            var overlaps = false
            for run in line.runs {
                var part = ""
                attributes.enumerateAttribute(.init(kCTBaselineOffsetAttributeName as String), in: run.range) {
                    offset, range, _ in
                    let raw = source.substring(with: range)
                    if let points = offset as? NSNumber, points.doubleValue > 0.8 {
                        let digits = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
                        part += String(
                            raw.map { c in
                                guard c.isASCII, let digit = c.wholeNumberValue else { return c }
                                return digits[digit]
                            })
                    } else {
                        part += raw
                    }
                }
                if let previous {
                    if run.bounds.minX < previous.bounds.maxX - 2 { overlaps = true }
                    if NSMaxRange(previous.range) != run.range.location,
                        part.first.map({ !",.;:)]}".contains($0) }) == true
                    {
                        value += " "
                    }
                }
                value += part
                previous = run
            }
            text = value
            reliable =
                !overlaps
                && !value.unicodeScalars.contains {
                    $0.value == 0xfffd || $0.properties.generalCategory == .privateUse
                }
        }
    }

    private static func readingOrder(_ rows: [[Field]], pageWidth: CGFloat) -> [String]? {
        guard !rows.isEmpty else { return nil }
        if let cards = authorCards(rows, pageWidth: pageWidth) { return cards }
        // Keep printed shared affiliation and contact lines separate. Joining a wrapped name
        // list avoids splitting one person's first and last names between separate paragraphs.
        var result = [String]()
        var previousNames = false
        for row in rows {
            let text = row.map(\.text).joined(separator: " ")
            let names =
                resemblesNames(text) && !isOrganization(text) && !text.contains("@") && text.first?.isNumber == false
            if names && previousNames {
                result[result.count - 1] += " " + text
            } else {
                result.append(text)
            }
            previousNames = names
        }
        return result
    }
    private static func authorCards(_ rows: [[Field]], pageWidth: CGFloat) -> [String]? {
        let heads = rows[0]
        guard rows.count >= 2, heads.count >= 2, heads.allSatisfy({ resemblesNames($0.text) }),
            zip(heads, heads.dropFirst()).allSatisfy({ $1.bounds.minX - $0.bounds.maxX > pageWidth * 0.05 })
        else { return nil }
        let gutters = zip(heads, heads.dropFirst()).map { ($0.bounds.midX + $1.bounds.midX) / 2 }
        var columns = Array(repeating: [String](), count: heads.count)
        var result = [String]()
        let pitches = zip(rows, rows.dropFirst()).map { $0[0].bounds.midY - $1[0].bounds.midY }.sorted()
        let pitch = pitches[pitches.count / 2]
        func finishCards() -> Bool {
            guard
                columns.allSatisfy({ lines in
                    lines.count >= 2 && lines.dropFirst().contains { $0.contains("@") || isOrganization($0) }
                })
            else { return false }
            result += columns.map { $0.joined(separator: "\n") }
            columns = Array(repeating: [], count: heads.count)
            return true
        }
        for (index, row) in rows.enumerated() {
            if index > 0, row.count == heads.count, rows[index - 1][0].bounds.midY - row[0].bounds.midY > pitch * 1.45,
                row.allSatisfy({ resemblesNames($0.text) && !isOrganization($0.text) }),
                !finishCards()
            {
                return nil
            }
            var occupied = Set<Int>()
            for field in row {
                // A shared affiliation spanning a gutter belongs to the whole list.
                guard !gutters.contains(where: { field.bounds.minX < $0 && field.bounds.maxX > $0 }) else { return nil }
                let column = gutters.firstIndex(where: { $0 > field.bounds.midX }) ?? gutters.count
                guard occupied.insert(column).inserted else { return nil }
                columns[column].append(field.text)
            }
        }
        return finishCards() ? result : nil
    }

}
