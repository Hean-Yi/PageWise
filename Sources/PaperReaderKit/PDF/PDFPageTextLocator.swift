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
            if Self.contains(matchedText, in: text) { return page.id.uuidString }
        }
        return nil
    }

    static func contains(_ matchedText: String, in text: String) -> Bool {
        // PDFKit may insert line breaks inside a phrase, including between adjacent CJK characters.
        let query = matchedText.filter { !$0.isWhitespace }
        guard !query.isEmpty else { return false }
        return text.filter { !$0.isWhitespace }.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            != nil
    }
}
