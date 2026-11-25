import Foundation
import SwiftSoup

extension HTMLReadingStore {
    public func navigationItems(for artifact: HTMLReadingArtifact, root: URL) throws -> [PaperNavigationItem] {
        if let outline = artifact.outline { return outline }
        let html = try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8)
        let document = try SwiftSoup.parse(html)
        let sections = Dictionary(artifact.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [PaperNavigationItem] = []
        for element in try document.select("#reader > section[data-key]") {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: try element.attr("data-key")), let section = sections[id],
                let item = try Self.outlineItem(
                    in: element, id: id, page: section.sourcePage, hasSection: !items.isEmpty)
            else { continue }
            items.append(item)
        }
        return items
    }

    static func outlineItem(in container: Element, id: UUID, page: Int, hasSection: Bool) throws -> PaperNavigationItem?
    {
        guard let heading = container.children().first(where: { $0.tagName() != "span" && !$0.hasClass("translation") })
        else { return nil }
        // h1 is the paper title, h4–h6 are deeper headings, except for the source's Abstract.
        let tag = heading.tagName()
        guard tag == "h2" || (tag == "h3" && hasSection) || tag == "h6" else { return nil }
        let title = try heading.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, tag != "h6" || title.caseInsensitiveCompare("Abstract") == .orderedSame else {
            return nil
        }
        return PaperNavigationItem(
            id: id.uuidString, title: title, sourcePage: page, depth: tag == "h3" ? 1 : 0,
            isOutline: true, readingSectionID: id)
    }
}
