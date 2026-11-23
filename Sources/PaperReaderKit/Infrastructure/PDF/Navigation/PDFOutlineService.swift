import Foundation
import PDFKit

/// Creates and traverses its own PDFKit objects away from the UI actor.
public actor PDFOutlineService {
    public init() {}

    public func items(for paper: Paper, root: URL) throws -> [PaperNavigationItem] {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: root.appendingPathComponent(paper.originalPath)), !document.isLocked
        else { throw ReaderError.message("原始 PDF 无法打开，已显示本地页面导航。") }
        var items: [PaperNavigationItem] = []
        var visited = 0
        func visit(_ parent: PDFOutline, depth: Int, path: String, nesting: Int) throws {
            guard depth < 2, nesting < 64, visited < 10_000 else { return }
            for index in 0..<parent.numberOfChildren {
                try Task.checkCancellation()
                guard visited < 10_000 else { return }
                guard let child = parent.child(at: index) else { continue }
                visited += 1
                let childPath = path + "-\(index)"
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                var childDepth = depth
                if let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                    let destination, let page = destination.page
                {
                    let isDocumentTitle =
                        nesting == 0 && parent.numberOfChildren == 1 && child.numberOfChildren > 0
                        && title.localizedCaseInsensitiveCompare(paper.title) == .orderedSame
                    let pageIndex = document.index(for: page)
                    if !isDocumentTitle, pageIndex >= 0 && pageIndex < min(document.pageCount, paper.pageCount) {
                        let box = page.bounds(for: .cropBox)
                        let target = destination.point
                        // A fit-page destination can leave one or both axes unspecified.
                        let point = CGPoint(
                            x: (box.minX...box.maxX).contains(target.x) ? target.x : box.minX,
                            y: (box.minY...box.maxY).contains(target.y) ? target.y : box.maxY)
                        items.append(
                            PaperNavigationItem(
                                id: "\(paper.id.uuidString)-outline\(childPath)", title: title, sourcePage: pageIndex,
                                depth: depth, isOutline: true, sourcePoint: point))
                        childDepth += 1
                    }
                }
                try visit(child, depth: childDepth, path: childPath, nesting: nesting + 1)
            }
        }
        if let outline = document.outlineRoot {
            try visit(outline, depth: 0, path: "", nesting: 0)
        }
        if items.isEmpty {
            items = try PDFPrintedOutline.items(in: document, paperID: paper.id, pageCount: paper.pageCount)
        }
        return items.isEmpty ? PaperNavigationItem.pages(for: paper) : items
    }
}
