import Foundation
import SwiftSoup

/// Classifies front matter by meaning and document position; publisher classes are only hints.
/// Uncertain text and all body/abstract text stay in place. Metadata remains accessible in details.
enum HTMLFrontMatterNormalizer {
    static func normalize(_ article: Element) throws {
        var candidates: [Element] = []
        var reachedBody = false
        var reachedTitle = false
        func visit(_ node: Element) throws {
            guard !reachedBody else { return }
            let classes = try node.attr("class").lowercased()
            let text = try node.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if classes.contains("abstract") { return }
            if node.tagName() == "h1" {
                reachedTitle = true
                return
            }
            if node.hasClass("ltx_section") || node.tagName() == "section"
                || ["h2", "h3"].contains(node.tagName())
            {
                reachedBody = true
                return
            }
            let roles = [
                "ltx_authors", "ltx_role_author", "ltx_role_affiliation", "ltx_role_correspondence", "ltx_role_date",
                "ltx_role_email", "ltx_role_thanks", "ltx_date", "ltx_dates",
            ]
            if roles.contains(where: { node.hasClass($0) }) || isMetadata(text, beforeTitle: !reachedTitle) {
                candidates.append(node)
                return
            }
            // Only structural wrappers are traversed; do not split an ordinary prose paragraph.
            if ["div", "header", "span"].contains(node.tagName()) {
                for child in node.children() { try visit(child) }
            }
        }
        for child in article.children() { try visit(child) }
        guard let first = candidates.first else { return }
        let names = try candidates.flatMap { try $0.select(".ltx_personname").map { try $0.text() } }
        var details = ""
        for node in candidates {
            try node.select(".ltx_note_mark").remove()
            // Affiliation logos are metadata, not paper figures; do not download them or
            // let an unavailable publisher logo reject the document body.
            try node.select("img,svg,object,embed").remove()
            details += "<div>" + (try node.outerHtml()) + "</div>"
        }
        let summary = names.isEmpty ? "" : "<p>" + HTMLPaperParser.escape(names.joined(separator: " · ")) + "</p>"
        try first.before(
            "<div class='ltx_authors'>" + summary + "<details><summary>作者与机构</summary>" + details + "</details></div>")
        for node in candidates { try node.remove() }
    }

    private static func isMetadata(_ text: String, beforeTitle: Bool) -> Bool {
        guard !text.isEmpty, text.count <= (beforeTitle ? 5_000 : 600) else { return false }
        let value = text.replacingOccurrences(of: #"\\[A-Za-z]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^[†‡*\s]+"#, with: "", options: .regularExpression)
        if beforeTitle,
            value.range(
                of:
                    #"(?i)\b(?:university|institute|affiliation|corresponding authors?|co-first authors?|equal contribution|this work was done|submitted|publication date)\b"#,
                options: .regularExpression) != nil
        {
            return true
        }
        if beforeTitle,
            value.range(of: #"(?i)^\s*\[\s*(?:code|project|website|model|data)\s*\]"#, options: .regularExpression)
                != nil
        {
            return true
        }
        let patterns = [
            #"(?i)^(?:date|published|publication date|received|accepted|updated|correspondence|corresponding author|contact|e-?mail|affiliations?)\s*[:：].*$"#,
            #"(?i)^(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4}\.?$"#,
            #"^\d{4}[-/]\d{1,2}[-/]\d{1,2}$"#,
            #"^[\w.+%{}\\,;\s-]+@[\w.-]+\.[A-Za-z]{2,}(?:[\s,;]+[\w.+%{}\\,;\s-]+@[\w.-]+\.[A-Za-z]{2,})*$"#,
            #"(?i)^(?:these authors contributed equally|equal contribution|joint first authors|joint senior authors)[.\s]*$"#,
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}
