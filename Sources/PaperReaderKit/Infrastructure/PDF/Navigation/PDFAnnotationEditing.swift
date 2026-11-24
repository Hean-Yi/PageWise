import Foundation
import PDFKit

extension PDFReadingNoteLocator {
    /// Reopen a stored mark at its verified range, including old ink with only a quotation and line rects.
    public func locatedHighlight(_ mark: Highlight, in url: URL) throws -> [PDFReadingNoteFragment] {
        guard mark.isOriginalPDFInk, !mark.text.isEmpty else { throw Self.notFound }
        let document = try document(at: url, pageIndex: mark.pageIndex)
        defer { withExtendedLifetime(document) {} }
        return try Self.locatedHighlight(mark, in: document)
    }

    /// Reuse one PDF document for the loaded reading window. Ambiguous or outdated rectangles have no text projection.
    public func historicalInkAnchors(_ marks: [Highlight], in url: URL) throws -> [UUID: [NoteAnchor]] {
        guard let first = marks.first else { return [:] }
        let document = try document(at: url, pageIndex: first.pageIndex)
        defer { withExtendedLifetime(document) {} }
        var result: [UUID: [NoteAnchor]] = [:]
        for mark in marks where mark.hasOnlyOriginalPDFGeometry {
            try Task.checkCancellation()
            if let fragments = try? Self.locatedHighlight(mark, in: document) {
                result[mark.id] = fragments.map(\.anchor)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func locatedHighlight(_ mark: Highlight, in document: PDFDocument) throws -> [PDFReadingNoteFragment]
    {
        guard let page = document.page(at: mark.pageIndex), let raw = page.string as NSString?,
            raw.length == page.numberOfCharacters
        else { throw Self.notFound }
        let start = try mark.pdfTextStart ?? Self.legacyStart(for: mark, on: page, raw: raw)
        guard let start, start >= 0, start <= raw.length, mark.text.utf16.count <= raw.length - start else {
            throw Self.notFound
        }
        let range = NSRange(location: start, length: mark.text.utf16.count)
        guard raw.substring(with: range) == mark.text else { throw Self.notFound }
        return try Self.fragments(page: page, pageIndex: mark.pageIndex, ranges: [range])
    }

    /// Includes geometry-only historical ink when both the actual characters and their rects agree.
    public func appearance(
        for fragments: [PDFReadingNoteFragment], in highlights: [Highlight], paperID: UUID, documentURL: URL
    ) throws -> PDFAnnotationAppearance {
        guard let first = fragments.first?.anchor.pdfPageIndex else { return .init() }
        let document = try document(at: documentURL, pageIndex: first)
        defer { withExtendedLifetime(document) {} }
        let ranges = try Self.selectionRanges(fragments, in: document)
        let projected = try Self.projectedInk(highlights, for: paperID, fragments: fragments, document: document)
        return AnnotationRangeEditor.pdfAppearance(for: ranges, paperID: paperID, in: projected)
    }

    public func applying(
        _ fragments: [PDFReadingNoteFragment], to highlights: [Highlight], paperID: UUID,
        color: AnnotationColor, style: AnnotationStyle, removing: Bool = false, in url: URL
    ) throws -> [Highlight] {
        guard let first = fragments.first?.anchor.pdfPageIndex else { return highlights }
        let document = try document(at: url, pageIndex: first)
        defer { withExtendedLifetime(document) {} }
        let ranges = try Self.selectionRanges(fragments, in: document)
        let cuts = ranges.mapValues { parts in
            parts.reduce(into: IndexSet()) { $0.insert(integersIn: $1.location..<NSMaxRange($1)) }
        }
        let projected = try Self.projectedInk(highlights, for: paperID, fragments: fragments, document: document)
        let appearance = AnnotationRangeEditor.pdfAppearance(for: ranges, paperID: paperID, in: projected)
        if !removing, appearance.color == color, appearance.style == style {
            // An explicit edit can also make a verified historical mark available to the reflow reader.
            return zip(highlights, projected).map { stored, located in
                guard stored.pdfTextStart == nil, let range = located.originalPDFTextRange,
                    cuts[located.pageIndex]?.intersects(integersIn: range) == true
                else { return stored }
                return located
            }
        }

        var result: [Highlight] = []
        for (stored, located) in zip(highlights, projected) {
            guard located.paperID == paperID, let range = located.originalPDFTextRange,
                let cut = cuts[located.pageIndex], cut.intersects(integersIn: range),
                let page = document.page(at: located.pageIndex)
            else {
                result.append(stored)
                continue
            }
            try Task.checkCancellation()
            var keptID = false
            for part in AnnotationRangeEditor.remainderRanges(of: range, excluding: cut) {
                var remainder = stored
                let source = try Self.fragments(
                    page: page, pageIndex: located.pageIndex, ranges: [NSRange(part)], keepingWhitespace: true)[0]
                remainder.text = source.anchor.text
                remainder.pdfTextStart = part.lowerBound
                remainder.rects = source.rects
                if keptID { remainder.id = UUID() }
                result.append(remainder)
                keptID = true
            }
        }
        guard !removing else { return result }
        for index in cuts.keys.sorted() {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let cut = cuts[index] else { throw Self.notFound }
            let parts = try Self.fragments(page: page, pageIndex: index, ranges: cut.rangeView.map(NSRange.init))
            for part in parts {
                var mark = part.highlight(for: paperID)
                mark.style = style
                mark.color = color
                result.append(mark)
            }
        }
        return result
    }

    private static func selectionRanges(_ fragments: [PDFReadingNoteFragment], in document: PDFDocument) throws
        -> [Int: [NSRange]]
    {
        var result: [Int: [NSRange]] = [:]
        for fragment in fragments {
            let anchor = fragment.anchor
            guard let index = anchor.pdfPageIndex, let page = document.page(at: index),
                let raw = page.string as NSString?,
                raw.length == page.numberOfCharacters, anchor.start >= 0, anchor.end > anchor.start,
                anchor.end <= raw.length
            else { throw notFound }
            let range = NSRange(location: anchor.start, length: anchor.end - anchor.start)
            guard range.length == anchor.text.utf16.count, raw.substring(with: range) == anchor.text else {
                throw notFound
            }
            result[index, default: []].append(range)
        }
        return result
    }

    private static func projectedInk(
        _ marks: [Highlight], for paperID: UUID, fragments: [PDFReadingNoteFragment], document: PDFDocument
    ) throws -> [Highlight] {
        let rects = Dictionary(grouping: fragments, by: { $0.anchor.pdfPageIndex }).mapValues {
            $0.flatMap(\.rects).compactMap(PDFHighlightCoverage.rectangle)
        }
        let ranges = Dictionary(grouping: fragments, by: { $0.anchor.pdfPageIndex }).mapValues {
            $0.map { $0.anchor.start..<$0.anchor.end }
        }
        return try marks.map { mark in
            guard mark.paperID == paperID, mark.isOriginalPDFInk, !mark.text.isEmpty,
                let selected = rects[mark.pageIndex],
                let page = document.page(at: mark.pageIndex), let raw = page.string as NSString?,
                raw.length == page.numberOfCharacters
            else { return mark }
            try Task.checkCancellation()
            var located = mark
            if let range = mark.originalPDFTextRange {
                guard ranges[mark.pageIndex]?.contains(where: { $0.overlaps(range) }) == true else { return mark }
                guard range.upperBound <= raw.length, raw.substring(with: NSRange(range)) == mark.text else {
                    throw notFound
                }
            } else if mark.pdfTextStart == nil,
                mark.rects.compactMap(PDFHighlightCoverage.rectangle).contains(where: { line in
                    selected.contains { !$0.intersection(line).isEmpty }
                })
            {
                located.pdfTextStart = try legacyStart(for: mark, on: page, raw: raw)
            }
            return located
        }
    }

    /// A quotation can appear more than once. Rectangles distinguish occurrences without moving a reader's old marks.
    private static func legacyStart(for mark: Highlight, on page: PDFPage, raw: NSString) throws -> Int? {
        var offset = 0
        var start: Int?
        while offset < raw.length {
            try Task.checkCancellation()
            let match = raw.range(
                of: mark.text, options: .literal, range: NSRange(location: offset, length: raw.length - offset))
            guard match.location != NSNotFound else { break }
            offset = match.location + 1
            guard let fragment = try? fragments(page: page, pageIndex: mark.pageIndex, ranges: [match]).first,
                fragment.rects.count == mark.rects.count,
                zip(fragment.rects, mark.rects).allSatisfy({ actual, saved in
                    actual.count == saved.count && zip(actual, saved).allSatisfy { abs($0 - $1) < 0.01 }
                })
            else { continue }
            guard start == nil else { return nil }
            start = match.location
        }
        return start
    }
}
