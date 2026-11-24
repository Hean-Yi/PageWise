import Foundation
import SwiftSoup

public actor PaperPreviewReader {
    private var libraries: [URL: PaperAbstractStore] = [:]

    public init() {}

    /// New imports and old-library backfill prepare the same records that the preview reads.
    public func prepare(paper: Paper, root: URL) async throws {
        _ = try await material(for: paper, root: root, translationStore: nil)
    }

    public func read(paper: Paper, root: URL, store: PDFSentenceTranslationStore, settings: ModelSettings) async throws
        -> PaperPreviewContent
    {
        let material = try await material(for: paper, root: root, translationStore: store)
        if let published = material.published, published.isChineseAbstract { return published }
        var translated: [String: String] = [:]
        for sentences in Dictionary(grouping: material.pdf?.sentences ?? [], by: \.pageIndex).values {
            try Task.checkCancellation()
            if let values = try? await store.cached(
                documentHash: paper.digest, sentences: sentences, settings: settings)
            {
                translated.merge(values) { first, _ in first }
            }
        }
        try Task.checkCancellation()
        let pdf = material.pdf.flatMap { AbstractPassage.display($0.parts, translated: translated) }
        if let pdf, pdf.isChineseAbstract { return pdf }
        if let indexed = material.indexed, indexed.isChineseAbstract { return indexed }
        return material.published ?? material.indexed ?? pdf ?? .init()
    }

    private struct Material {
        let pdf: PDFAbstractRecord?
        let published: PaperPreviewContent?
        let indexed: PaperPreviewContent?
    }

    private func material(for paper: Paper, root: URL, translationStore: PDFSentenceTranslationStore?) async throws
        -> Material
    {
        try Task.checkCancellation()
        let cache = libraries[root] ?? PaperAbstractStore(root: root)
        libraries[root] = cache
        let indexed = paper.onlineSource?.abstractText.flatMap { raw -> PaperPreviewContent? in
            let text = (AbstractPassage.withoutLabel(raw) ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .init(abstract: text, isChineseAbstract: AbstractPassage.containsChinese(text))
        }
        var pdf: PDFAbstractRecord?
        var pdfFailure: (any Error)?
        if paper.pageCount > 0 {
            let file = root.appendingPathComponent(paper.originalPath)
            do {
                let key = PaperAbstractStore.Source.pdf(digest: paper.digest)
                let pages = min(3, paper.pageCount)
                if indexed != nil {
                    // The verified edition's abstract is already in the library. Only add PDF anchors
                    // when an existing on-device PDF translation can actually use them.
                    pdf = try await cache.cached(key)
                }
                let needsAnchors =
                    indexed == nil
                    ? true : await translationStore?.hasSavedPage(documentHash: paper.digest, among: 0..<pages) == true
                if pdf == nil && needsAnchors {
                    pdf = try await cache.record(for: key) { try PDFAbstractExtractor.extract(url: file, pages: pages) }
                }
            } catch {
                try Task.checkCancellation()
                pdfFailure = error
            }
        }
        let reference =
            pdf.flatMap { AbstractPassage.display($0.parts, translated: [:])?.abstract } ?? indexed?.abstract
        var published = try await publishedAbstract(in: paper, root: root, reference: reference, cache: cache)
        if published?.isChineseAbstract != true, let prior = paper.retainedReadings?.last {
            let older = try await publishedAbstract(
                in: prior.projecting(paper), root: root, reference: reference, cache: cache)
            if older?.isChineseAbstract == true || published == nil { published = older ?? published }
        }
        if let pdfFailure, indexed == nil, published == nil { throw pdfFailure }
        return .init(pdf: pdf, published: published, indexed: indexed)
    }

    private func publishedAbstract(in paper: Paper, root: URL, reference: String?, cache: PaperAbstractStore)
        async throws
        -> PaperPreviewContent?
    {
        let front = paper.blocks.prefix(80)
        guard let first = front.first, let last = front.last else { return nil }
        // Published blocks are immutable. A newly appended front section or rebuilt edition can reveal an abstract.
        let revision = [
            paper.htmlReading?.editionID?.uuidString ?? "", first.id.uuidString, last.id.uuidString,
            String(front.count),
            paper.reflowJob?.finished == true ? "finished" : "open", reference ?? "",
        ].joined(separator: "|")
        do {
            let record = try await cache.record(for: .publication(digest: paper.digest, revision: revision)) {
                let parts = front.map {
                    AbstractPassage.Part(text: $0.text, paragraph: $0.id.uuidString, key: $0.id.uuidString)
                }
                var passage: (parts: [AbstractPassage.Part], closed: Bool)?
                var headingFailure: (any Error)?
                if parts.contains(where: { AbstractPassage.withoutLabel($0.text) != nil }) {
                    var headings: Set<String> = []
                    if let html = paper.htmlReading {
                        do { headings = try Self.headingKeys(at: root.appendingPathComponent(html.relativePath)) } catch
                        { headingFailure = error }
                    }
                    let marked = parts.map { part in
                        var part = part
                        part.isSectionHeading = headings.contains(part.key)
                        return part
                    }
                    passage = AbstractPassage.locate(marked)
                    if let passage, passage.closed, !passage.parts.isEmpty {
                        return .init(parts: passage.parts, sentences: [])
                    }
                }
                if let reference, let match = AbstractPassage.matching(reference, in: parts) {
                    return .init(parts: match, sentences: [])
                }
                if let headingFailure { throw headingFailure }
                if paper.reflowJob?.finished == true, let first = passage?.parts.first {
                    return .init(parts: [first], sentences: [])
                }
                return .init(parts: [], sentences: [])
            }
            return AbstractPassage.display(record.parts, translated: paper.translations)
        } catch {
            try Task.checkCancellation()
            // PDF or verified bibliographic text is still available while an HTML artifact is unavailable.
            return nil
        }
    }

    /// Published blocks keep their text and translations in the snapshot. Heading tags stay in the immutable HTML.
    private static func headingKeys(at url: URL) throws -> Set<String> {
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
}
