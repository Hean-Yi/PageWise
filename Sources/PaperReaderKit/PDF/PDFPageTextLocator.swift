import Foundation
import PDFKit

/// Reads immutable candidate artifacts in its own isolation domain; never rebuilds or writes a page.
public actor PDFPageTextLocator: FixedPageTextLocating {
    public init() {}

    public func pageKey(matching matchedText: String, in pages: [PageArtifact], root: URL) throws -> String? {
        for page in pages {
            try Task.checkCancellation()
            guard let document = PDFDocument(url: root.appendingPathComponent(page.relativePath)),
                !document.isLocked, document.pageCount == 1, let text = document.page(at: 0)?.string
            else { throw ReaderError.message("固定页面暂无法读取。") }
            if PaperTextSearch.containsLocationContext(matchedText, in: text) { return page.id.uuidString }
        }
        return nil
    }

}
