import Foundation

enum PDFAbstractExtractor {
    static func extract(url: URL, pages: Int) throws -> PDFAbstractRecord {
        var sentences: [PDFSourceSentence] = []
        var found: (parts: [AbstractPassage.Part], closed: Bool)?
        for page in 0..<max(0, min(3, pages)) {
            try Task.checkCancellation()
            let extraction = try PDFSentenceExtractor.extractPage(url: url, pageIndex: page)
            sentences.append(contentsOf: extraction.sentences)
            let parts = sentences.map { part(for: $0) }
            found = AbstractPassage.locate(parts)
            if found?.closed != true || extraction.notice != nil,
                let column = try PDFAbstractColumn.read(url: url, pageIndex: page)
            {
                // Keep the exact original sentence IDs when they cover the geometrically bounded text.
                // This lets a single import later show newly saved translations without opening the PDF.
                return record(for: column, sentences: extraction.sentences)
            }
            if found?.closed == true { break }
        }
        var selected = found?.parts ?? []
        // Without a recognizable end heading, keep only the paragraph attached to the label.
        if found?.closed != true, let first = selected.first {
            selected = Array(selected.prefix { $0.paragraph == first.paragraph })
        }
        let keys = Set(selected.map(\.key))
        return .init(parts: selected, sentences: sentences.filter { keys.contains($0.id) })
    }

    private static func part(for sentence: PDFSourceSentence) -> AbstractPassage.Part {
        .init(text: sentence.text, paragraph: sentence.readingParagraphID, key: sentence.id)
    }

    private static func record(for column: String, sentences: [PDFSourceSentence]) -> PDFAbstractRecord {
        if let parts = AbstractPassage.matching(column, in: sentences.map { part(for: $0) }) {
            let keys = Set(parts.map(\.key))
            return .init(parts: parts, sentences: sentences.filter { keys.contains($0.id) })
        }
        return .init(parts: [.init(text: column, paragraph: "column", key: "column")], sentences: [])
    }
}
