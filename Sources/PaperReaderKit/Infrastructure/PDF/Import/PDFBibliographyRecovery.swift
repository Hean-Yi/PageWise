import Foundation
import PDFKit
import SwiftSoup

/// Restores full PDF citation details when HTML abbreviates authors or publication metadata.
/// Entry identities must match one-to-one before replacing anything; links keep their original anchors.
enum PDFBibliographyRecovery {
    static func restore(in blocks: [TextBlock], document: PDFDocument) throws -> [TextBlock] {
        guard
            let index = blocks.firstIndex(where: {
                $0.richContent?.html.contains("id=\"ref-bib.") == true
                    || $0.richContent?.html.contains("id='ref-bib.") == true
            }),
            let markup = blocks[index].richContent?.html
        else { return blocks }
        let parsed = try SwiftSoup.parseBodyFragment(markup)
        let items = try parsed.select("li[id]").filter { try $0.attr("id").hasPrefix("ref-bib.") }
        guard !items.isEmpty, let citations = citations(in: document), citations.count == items.count else {
            return blocks
        }
        let normalizedCitations = citations.map { normalized($0.text) }
        var matched = Set<Int>()
        var replacements: [(Element, Int)] = []
        for item in items {
            let candidates = try item.select("span").map { normalized(try $0.text()) }.filter { $0.count >= 16 }
            let uniqueMatches = Set(
                candidates.compactMap { candidate -> Int? in
                    let matches = normalizedCitations.indices.filter { normalizedCitations[$0].contains(candidate) }
                    return matches.count == 1 ? matches.first : nil
                })
            guard uniqueMatches.count == 1, let match = uniqueMatches.first, matched.insert(match).inserted else {
                return blocks
            }
            replacements.append((item, match))
        }
        for (item, match) in replacements {
            let links = try item.select("a[href]").map { link -> String in
                let href = try link.attr("href")
                return "<a href='\(HTMLPaperParser.escape(href))'>\(href.hasPrefix("#") ? "↩" : "来源")</a>"
            }.joined(separator: " ")
            try item.html(HTMLPaperParser.escape(citations[match].text) + (links.isEmpty ? "" : " " + links))
        }
        // Preserve source order rather than an exporter-specific ordering of the bibliography.
        if let list = items.first?.parent() {
            for (item, _) in replacements.sorted(by: { $0.1 < $1.1 }) { try list.appendChild(item) }
        }
        var result = blocks
        result[index].text = citations.map(\.text).joined(separator: "\n\n")
        result[index].richContent?.html = try parsed.body()?.html() ?? markup
        result[index].richContent?.translationInput = ""
        return result
    }

    private struct Citation {
        var text: String
    }

    private static func citations(in document: PDFDocument) -> [Citation]? {
        var active = false
        var result: [Citation] = []
        var left: CGFloat?
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let extraction = PDFProcessor.positionedLines(on: page)
            var sourceLines: [PDFProcessor.TextLine] = extraction.rows.flatMap { $0 }
            sourceLines.sort { lhs, rhs in
                if abs(lhs.bounds.midY - rhs.bounds.midY) > 1 { return lhs.bounds.midY > rhs.bounds.midY }
                return lhs.bounds.minX < rhs.bounds.minX
            }
            var selected: [PDFProcessor.TextLine] = []
            var ended = false
            for line in sourceLines {
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if ["references", "bibliography"].contains(text.lowercased()) {
                    active = true
                    continue
                }
                guard active else { continue }
                if text.range(of: #"^(?:(?i:Appendix)(?:\s|$)|[A-Z]\s+[A-Z])"#, options: .regularExpression) != nil,
                    text.count < 100, !result.isEmpty || !selected.isEmpty
                {
                    ended = true
                    break
                }
                selected.append(line)
            }
            if selected.isEmpty {
                if ended { return result }
                continue
            }
            let layout = PDFProcessor.orderedColumns(selected.map { [$0] }, pageBounds: bounds)
            guard layout.reliable else { return nil }
            for group in layout.groups {
                for line in group {
                    let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.bounds.minY < bounds.minY + 45 || line.bounds.maxY > bounds.maxY - 45 { continue }
                    if left == nil { left = line.bounds.minX }
                    if result.isEmpty || line.bounds.minX <= (left ?? line.bounds.minX) + 2 {
                        result.append(Citation(text: text))
                    } else {
                        result[result.count - 1].text += " " + text
                    }
                }
            }
            if ended { return result }
        }
        return active && !result.isEmpty ? result : nil
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
