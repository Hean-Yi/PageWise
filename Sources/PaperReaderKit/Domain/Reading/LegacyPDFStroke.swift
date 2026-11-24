import Foundation

/// Older palette writes appended one record per PDF run within the same synchronous insertion.
/// Near-simultaneous creation narrows the candidates. The original page must still verify every gap.
enum LegacyPDFStroke {
    static func batches(in marks: [Highlight]) -> [[Highlight]] {
        var batches: [[Highlight]] = []
        var batch: [Highlight] = []
        for mark in marks {
            if let previous = batch.last, let previousRange = previous.originalPDFTextRange,
                let range = mark.originalPDFTextRange, mark.strokeID == nil,
                previous.paperID == mark.paperID, previous.pageIndex == mark.pageIndex,
                previous.style == mark.style, previous.color == mark.color,
                mark.createdAt > previous.createdAt, mark.createdAt.timeIntervalSince(previous.createdAt) < 0.001,
                range.lowerBound >= previousRange.upperBound, range.lowerBound - previousRange.upperBound <= 4
            {
                batch.append(mark)
            } else {
                if batch.count > 1 { batches.append(batch) }
                batch = mark.strokeID == nil && mark.originalPDFTextRange != nil ? [mark] : []
            }
        }
        if batch.count > 1 { batches.append(batch) }
        return batches
    }
}

extension LibraryState {
    /// v13 adds a display hint for unambiguous old fragment notes without accessing files during library load.
    mutating func recordLegacyStrokeMembers() {
        let versions = Dictionary(
            papers.map { ($0.id, $0.digest + ":original-0") }, uniquingKeysWith: { first, _ in first })
        let candidates = readingNotes.indices.filter { index in
            let note = readingNotes[index]
            return note.contentVersion == versions[note.paperID] && note.deletedAt == nil && !note.isDocumentSummary
                && note.dimension == nil
                && note.anchors.count == 1 && note.anchors[0].pdfPageIndex != nil
        }
        let byPaper = Dictionary(grouping: candidates) { readingNotes[$0].paperID }
        guard !byPaper.isEmpty else { return }
        let marksByPaper = Dictionary(grouping: highlights.filter { byPaper[$0.paperID] != nil }, by: \.paperID)
        for (paperID, indices) in byPaper {
            let notes = Dictionary(grouping: indices) { readingNotes[$0].anchors[0] }
            for batch in LegacyPDFStroke.batches(in: marksByPaper[paperID] ?? []) {
                let matches = batch.flatMap { mark in
                    (mark.pdfReadingAnchor.flatMap { notes[$0] } ?? []).filter {
                        readingNotes[$0].createdAt >= mark.createdAt
                    }
                    .map { (index: $0, member: mark.id) }
                }
                if matches.count == 1, let match = matches.first {
                    readingNotes[match.index].legacyStrokeMemberID = match.member
                }
            }
        }
    }
}

extension Highlight {
    public var isHistoricalPDFInk: Bool {
        strokeID == nil && (hasOnlyOriginalPDFGeometry || originalPDFTextRange != nil)
    }
}
