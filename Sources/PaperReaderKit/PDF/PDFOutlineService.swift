import Foundation
import PDFKit

/// Creates and traverses its own PDFKit objects away from the UI actor.
public actor PDFOutlineService {
    public init() {}

    public func items(for paper: Paper, root: URL) throws -> [PaperNavigationItem] {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: root.appendingPathComponent(paper.originalPath)), !document.isLocked
        else { throw ReaderError.message("原始 PDF 无法打开，已显示本地页面导航。") }
        guard let outline = document.outlineRoot else { return PaperNavigationItem.pages(for: paper) }
        var items: [PaperNavigationItem] = []
        var visited = 0
        func visit(_ parent: PDFOutline, depth: Int, path: String) throws {
            guard depth <= 64, visited < 10_000 else { return }
            for index in 0..<parent.numberOfChildren {
                try Task.checkCancellation()
                guard visited < 10_000 else { return }
                guard let child = parent.child(at: index) else { continue }
                visited += 1
                let childPath = path + "-\(index)"
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                    let page = destination?.page
                {
                    let pageIndex = document.index(for: page)
                    if pageIndex >= 0 && pageIndex < min(document.pageCount, paper.pageCount) {
                        items.append(
                            PaperNavigationItem(
                                id: "\(paper.id.uuidString)-outline\(childPath)", title: title, sourcePage: pageIndex,
                                depth: depth, isOutline: true))
                    }
                }
                try visit(child, depth: depth + 1, path: childPath)
            }
        }
        try visit(outline, depth: 0, path: "")
        return items.isEmpty ? PaperNavigationItem.pages(for: paper) : items
    }
}
