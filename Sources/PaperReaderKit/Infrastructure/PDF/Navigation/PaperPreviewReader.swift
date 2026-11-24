import Foundation
import SwiftSoup

public actor PaperPreviewReader {
    private struct PDFAbstract {
        let parts: [AbstractPassage.Part]
        let sentences: [PDFSourceSentence]
    }

    private var recent: [(digest: String, abstract: PDFAbstract)] = []

    public init() {}

    public func read(paper: Paper, root: URL, store: PDFSentenceTranslationStore, settings: ModelSettings) async throws
        -> PaperPreviewContent
    {
        try Task.checkCancellation()
        var source = publishedAbstract(in: paper, root: root)
        if let source, source.isChineseAbstract { return source }
        // Rebuilding an edition does not invalidate the same PDF's already published abstract.
        if let prior = paper.retainedReadings?.last {
            let older = publishedAbstract(in: prior.projecting(paper), root: root)
            if let older, older.isChineseAbstract { return older }
            source = source ?? older
        }
        let indexed = paper.onlineSource?.abstractText.map { AbstractPassage.withoutLabel($0) ?? $0 }
        if source == nil, let indexed, !indexed.isEmpty {
            source = .init(abstract: indexed, isChineseAbstract: AbstractPassage.containsChinese(indexed))
        }

        let limit = min(3, max(0, paper.pageCount))
        if let source, !(await store.hasSavedPage(documentHash: paper.digest, among: 0..<limit)) { return source }
        try Task.checkCancellation()
        let excerpt: PDFAbstract
        if let cached = recent.first(where: { $0.digest == paper.digest }) {
            excerpt = cached.abstract
        } else {
            excerpt = try extractPDF(url: root.appendingPathComponent(paper.originalPath), pages: limit)
            try Task.checkCancellation()
            recent.append((paper.digest, excerpt))
            if recent.count > 12 { recent.removeFirst() }
        }
        var translated: [String: String] = [:]
        for sentences in Dictionary(grouping: excerpt.sentences, by: \.pageIndex).values {
            try Task.checkCancellation()
            if let saved = try? await store.cached(documentHash: paper.digest, sentences: sentences, settings: settings)
            {
                translated.merge(saved) { first, _ in first }
            }
        }
        try Task.checkCancellation()
        let pdf = AbstractPassage.display(excerpt.parts, translated: translated)
        if let pdf, pdf.isChineseAbstract { return pdf }
        return source ?? pdf ?? .init()
    }

    private func publishedAbstract(in paper: Paper, root: URL) -> PaperPreviewContent? {
        let front = paper.blocks.prefix(80)
        guard front.contains(where: { AbstractPassage.withoutLabel($0.text) != nil }) else { return nil }
        let headings =
            paper.htmlReading.flatMap {
                try? headingKeys(at: root.appendingPathComponent($0.relativePath))
            } ?? []
        let parts = front.map {
            let key = $0.id.uuidString
            return AbstractPassage.Part(
                text: $0.text, paragraph: key, key: key, isSectionHeading: headings.contains(key))
        }
        guard let passage = AbstractPassage.locate(parts) else { return nil }
        if passage.closed { return AbstractPassage.display(passage.parts, translated: paper.translations) }
        guard paper.reflowJob?.finished == true, let first = passage.parts.first else { return nil }
        return AbstractPassage.display([first], translated: paper.translations)
    }

    /// Published blocks keep their text and translations in the snapshot. Heading tags stay in the immutable HTML.
    private func headingKeys(at url: URL) throws -> Set<String> {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let prefix = String(decoding: try file.read(upToCount: 128 * 1_024) ?? Data(), as: UTF8.self)
        guard let end = prefix.range(of: "</section>", options: .backwards) else { return [] }
        let document = try SwiftSoup.parse(String(prefix[..<end.upperBound]))
        return try Set(
            document.select("#reader > section[data-key]").compactMap { section in
                let heading = section.children().contains {
                    ["h1", "h2", "h3"].contains($0.tagName()) && !$0.hasClass("translation")
                }
                return heading ? try section.attr("data-key") : nil
            })
    }

    private func extractPDF(url: URL, pages: Int) throws -> PDFAbstract {
        var sentences: [PDFSourceSentence] = []
        var found: (parts: [AbstractPassage.Part], closed: Bool)?
        for page in 0..<pages {
            try Task.checkCancellation()
            let extraction = try? PDFSentenceExtractor.extractPage(url: url, pageIndex: page)
            sentences.append(contentsOf: extraction?.sentences ?? [])
            let parts = sentences.map {
                AbstractPassage.Part(text: $0.text, paragraph: $0.readingParagraphID, key: $0.id)
            }
            found = AbstractPassage.locate(parts)
            // A side column can force the sentence extractor to omit genuine prose. Use a
            // geometrically bounded column only when it can identify the following heading.
            if found?.closed != true || extraction?.notice != nil,
                let column = try PDFAbstractColumn.read(url: url, pageIndex: page)
            {
                let normalized = column.filter { $0.isLetter || $0.isNumber }
                let canonical = (found?.parts ?? []).map(\.text).joined().filter { $0.isLetter || $0.isNumber }
                if normalized != canonical {
                    return .init(parts: [.init(text: column, paragraph: "column", key: "column")], sentences: [])
                }
                found?.closed = true
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
}
