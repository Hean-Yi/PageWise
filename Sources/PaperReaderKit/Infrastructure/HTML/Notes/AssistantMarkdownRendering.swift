import Foundation
import SwiftSoup

public struct RenderedAssistantAnswer: Sendable {
    public let html: String
    public let citations: [String]
}

extension NoteMarkdownRenderer {
    /// Only literal markers in rendered prose can activate the corresponding local evidence.
    public func renderAssistant(_ markdown: String, citationIDs: Set<String> = []) throws -> RenderedAssistantAnswer {
        let document = try markdownDocument(markdown)
        var citations: [String] = []
        var seen = Set<String>()

        func annotate(_ parent: Node) throws {
            for child in parent.getChildNodes() {
                if let element = child as? Element {
                    if element.hasClass("note-math-error") { continue }
                    switch element.tagName() {
                    case "a", "code", "pre", "math": continue
                    default: try annotate(element)
                    }
                } else if let node = child as? TextNode {
                    let value = node.getWholeText()
                    var offset = value.startIndex
                    for match in value.matches(of: /\[(S[0-9]+)\]/) {
                        let id = String(match.1)
                        guard citationIDs.contains(id) else { continue }
                        if offset < match.range.lowerBound {
                            try node.before(TextNode(String(value[offset..<match.range.lowerBound]), ""))
                        }
                        let link = Element(try Tag.valueOf("a"), "")
                        try link.attr("data-citation", id).attr("href", "#source-" + id).text(String(match.0))
                        try node.before(link)
                        if seen.insert(id).inserted { citations.append(id) }
                        offset = match.range.upperBound
                    }
                    if offset > value.startIndex { node.text(String(value[offset...])) }
                }
            }
        }

        // Marked may emit anchors for URLs, raw HTML or reference-style links. Only the
        // anchors created here are actionable. Preserve the label of every other link.
        let modelLinks = try document.select("a").array()
        if !citationIDs.isEmpty, let body = document.body() { try annotate(body) }
        for link in modelLinks { try link.unwrap() }
        return RenderedAssistantAnswer(html: try document.body()?.html() ?? "", citations: citations)
    }
}
