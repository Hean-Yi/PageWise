import Foundation
import PDFKit

public struct PDFReadingNoteFragment: Sendable {
    fileprivate let pageIndex: Int
    public let anchor: NoteAnchor
    public let rects: [[Double]]

    public func highlight(for paperID: UUID) -> Highlight {
        Highlight(paperID: paperID, pageKey: anchor.key, pageIndex: pageIndex, text: anchor.text, rects: rects)
    }
}

extension NoteAnchor {
    public var pdfPageIndex: Int? {
        guard target == "pdf", key.hasPrefix("original-"), let index = Int(key.dropFirst(9)), index >= 0,
            key == "original-\(index)"
        else { return nil }
        return index
    }
}

/// Resolves only locally verified text on the cited original page. PDFKit never leaves this actor.
public actor PDFReadingNoteLocator {
    public init() {}

    public func locate(quote: String, pageIndex: Int, in documentURL: URL, selectedRanges: [NSRange] = []) throws
        -> [PDFReadingNoteFragment]
    {
        let words = quote.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, quote.utf16.count <= 8_192 else { throw Self.notFound }
        let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        let expression = try NSRegularExpression(pattern: pattern)
        let document = try document(at: documentURL, pageIndex: pageIndex)
        defer { withExtendedLifetime(document) {} }
        guard let page = document.page(at: pageIndex) else { throw Self.notFound }
        guard let raw = page.string, raw.utf16.count == page.numberOfCharacters else { throw Self.notFound }
        let bounds = NSRange(location: 0, length: raw.utf16.count)
        var scope = IndexSet()
        for range in selectedRanges {
            guard range.location >= 0, range.location <= bounds.length, range.length > 0,
                range.length <= bounds.length - range.location
            else { throw Self.notFound }
            scope.insert(integersIn: range.location..<NSMaxRange(range))
        }
        func accepts(_ ranges: [NSRange]) -> Bool {
            scope.isEmpty || ranges.allSatisfy { scope.contains(integersIn: $0.location..<NSMaxRange($0)) }
        }
        func occurrences(in text: String, perform: (NSRange) throws -> Void) throws {
            let count = text.utf16.count
            var start = 0
            while start < count,
                let hit = expression.firstMatch(in: text, range: NSRange(location: start, length: count - start))
            {
                try perform(hit.range)
                start = hit.range.location + 1
            }
        }
        var rawMatch: NSRange?
        try occurrences(in: raw) { hit in
            if accepts([hit]) {
                guard rawMatch == nil else { throw Self.ambiguous }
                rawMatch = hit
            }
        }
        // The reading text may correct line-end hyphens and read interleaved columns in reading order.
        // Reuse the extractor's original character runs before deriving PDF rectangles.
        let sentences = try PDFSentenceExtractor.extractPage(url: documentURL, pageIndex: pageIndex).sentences
        var located: [NSRange]?
        for sentence in sentences {
            try Task.checkCancellation()
            try occurrences(in: sentence.text) { hit in
                let spans = try Self.project(hit, in: sentence, raw: raw as NSString)
                guard accepts(spans) else { return }
                guard located == nil else { throw Self.ambiguous }
                if let rawMatch, spans.contains(where: { NSIntersectionRange($0, rawMatch).length == 0 }) {
                    throw Self.ambiguous
                }
                located = spans
            }
        }
        guard let ranges = rawMatch.map({ [$0] }) ?? located else { throw Self.notFound }
        return try Self.fragments(page: page, pageIndex: pageIndex, ranges: ranges)
    }

    public func selected(ranges: [NSRange], pageIndex: Int, in documentURL: URL) throws -> [PDFReadingNoteFragment] {
        let document = try document(at: documentURL, pageIndex: pageIndex)
        defer { withExtendedLifetime(document) {} }
        guard let page = document.page(at: pageIndex) else { throw Self.notFound }
        return try Self.fragments(page: page, pageIndex: pageIndex, ranges: ranges)
    }

    /// Project offsets in the displayed sentence through its verified original character runs.
    public func selected(_ pieces: [(sentence: PDFSourceSentence, range: NSRange)], in url: URL) throws
        -> [PDFReadingNoteFragment]
    {
        guard let first = pieces.first else { throw Self.notFound }
        let document = try document(at: url, pageIndex: first.sentence.pageIndex)
        defer { withExtendedLifetime(document) {} }
        var fragments: [PDFReadingNoteFragment] = []
        var seen = Set<NoteAnchor>()
        for (sentence, range) in pieces {
            try Task.checkCancellation()
            let count = sentence.text.utf16.count
            guard range.location >= 0, range.location <= count, range.length > 0,
                range.length <= count - range.location, let page = document.page(at: sentence.pageIndex),
                let raw = page.string as NSString?, raw.length == page.numberOfCharacters
            else { throw Self.notFound }
            let spans = try Self.project(range, in: sentence, raw: raw)
            let located = try Self.fragments(page: page, pageIndex: sentence.pageIndex, ranges: spans)
            fragments.append(contentsOf: located.filter { seen.insert($0.anchor).inserted })
        }
        return fragments
    }

    private func document(at url: URL, pageIndex: Int) throws -> PDFDocument {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url), !document.isLocked, (0..<document.pageCount).contains(pageIndex)
        else { throw Self.notFound }
        return document
    }

    private static var notFound: ReaderError { .message("未能在所引原页核对这段文字，请选中原文或提供更准确的引文。") }
    private static var ambiguous: ReaderError { .message("这段文字在所引原页出现多次，请选中原文或提供更长的引文。") }

    private static func project(_ match: NSRange, in sentence: PDFSourceSentence, raw: NSString) throws -> [NSRange] {
        let text = sentence.text as NSString
        var offset = 0
        var ranges: [NSRange] = []
        for part in sentence.characterRanges {
            guard part.location >= 0, part.location <= raw.length, part.length > 0,
                part.length <= raw.length - part.location
            else { throw notFound }
            let original = raw.substring(with: part) as NSString
            let shortened = original.hasSuffix("-") || original.hasSuffix("‐") || original.hasSuffix("\u{00ad}")
            var length = part.length
            func matches() -> Bool {
                length > 0 && offset + length <= text.length
                    && text.substring(with: NSRange(location: offset, length: length)) == original.substring(to: length)
            }
            if !matches(), offset < text.length, text.character(at: offset) == 32 { offset += 1 }
            if !matches(), shortened { length -= 1 }
            guard matches() else { throw notFound }
            let covered = NSIntersectionRange(match, NSRange(location: offset, length: length))
            if covered.length > 0 {
                let tail = NSMaxRange(covered) == offset + length ? part.length - length : 0
                ranges.append(
                    NSRange(location: part.location + covered.location - offset, length: covered.length + tail))
            }
            offset += length
        }
        guard offset == text.length, !ranges.isEmpty else { throw notFound }
        return ranges
    }

    private static func fragments(page: PDFPage, pageIndex: Int, ranges: [NSRange]) throws -> [PDFReadingNoteFragment] {
        guard let raw = page.string as NSString?, raw.length == page.numberOfCharacters, !ranges.isEmpty else {
            throw notFound
        }
        return try ranges.map { range in
            guard range.location >= 0, range.location <= raw.length, range.length > 0,
                range.length <= raw.length - range.location,
                let selection = page.selection(for: range)
            else { throw notFound }
            let text = raw.substring(with: range)
            let rects = try selection.selectionsByLine().map { line -> [Double] in
                let rect = line.bounds(for: page)
                guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite, !rect.isEmpty
                else { throw notFound }
                return [rect.minX, rect.minY, rect.width, rect.height]
            }
            guard !rects.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw notFound }
            return PDFReadingNoteFragment(
                pageIndex: pageIndex,
                anchor: NoteAnchor(
                    key: "original-\(pageIndex)", target: "pdf", text: text, start: range.location,
                    end: NSMaxRange(range)), rects: rects)
        }
    }
}

extension PDFReadingNoteLocator {
    public func citationContext(for citation: LocalPassageCitation, documentURL: URL) throws -> (
        before: String, after: String
    ) {
        guard let first = citation.anchors.first, let index = first.pdfPageIndex, let last = citation.anchors.last,
            citation.anchors.allSatisfy({ $0.pdfPageIndex == index && $0.start >= 0 && $0.end > $0.start })
        else { throw Self.notFound }
        let ranges = citation.anchors.map { NSRange(location: $0.start, length: $0.end - $0.start) }
        let located = try locate(quote: citation.quote, pageIndex: index, in: documentURL, selectedRanges: ranges)
        guard located.map(\.anchor) == citation.anchors else { throw Self.notFound }
        let document = try document(at: documentURL, pageIndex: index)
        guard let raw = document.page(at: index)?.string as NSString?, first.start <= raw.length, last.end <= raw.length
        else { throw Self.notFound }
        return (String(raw.substring(to: first.start).suffix(120)), String(raw.substring(from: last.end).prefix(180)))
    }
}
