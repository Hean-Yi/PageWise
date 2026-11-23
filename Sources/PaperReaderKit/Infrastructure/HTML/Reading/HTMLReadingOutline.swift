import Foundation
import SwiftSoup

extension HTMLReadingStore {
    public func navigationItems(for artifact: HTMLReadingArtifact, root: URL) throws -> [PaperNavigationItem] {
        let html = try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8)
        let document = try SwiftSoup.parse(html)
        let sections = Dictionary(artifact.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [PaperNavigationItem] = []
        var hasSection = false
        for element in try document.select("#reader > section[data-key]") {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: try element.attr("data-key")), let section = sections[id],
                let heading = element.children().first(where: {
                    $0.tagName() != "span" && !$0.hasClass("translation")
                })
            else { continue }
            // Source conversion reserves h1 for the paper title and h4–h6 for deeper sections.
            let title = try heading.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = heading.tagName()
            let isAbstract = tag == "h6" && title.caseInsensitiveCompare("Abstract") == .orderedSame
            guard tag == "h2" || (tag == "h3" && hasSection) || isAbstract, !title.isEmpty else { continue }
            let depth = tag == "h3" ? 1 : 0
            if depth == 0 { hasSection = true }
            items.append(
                PaperNavigationItem(
                    id: id.uuidString, title: title, sourcePage: section.sourcePage, depth: depth, isOutline: true,
                    readingSectionID: id))
        }
        return items
    }
}
