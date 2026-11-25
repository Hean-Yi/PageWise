import Foundation

struct TitleSearch {
    let raw: [Substring]
    let display: [Substring]

    init(_ query: String) {
        raw = query.split(whereSeparator: \.isWhitespace)
        display = PaperTitle.display(query).split(whereSeparator: \.isWhitespace)
    }

    func matches(_ rawTitle: String, displayTitle: @autoclosure () -> String) -> Bool {
        if raw.allSatisfy({ rawTitle.localizedStandardContains($0) }) { return true }
        let title = displayTitle()
        guard title != rawTitle || raw != display else { return false }
        return display.allSatisfy { title.localizedStandardContains($0) }
    }
}

/// A suggestion snapshot carries no PDF blocks, annotations or reflow artifacts.
public actor LibraryTitleIndex {
    public struct Document: Equatable, Sendable {
        public let id: UUID
        public let title: String

        public init(_ paper: Paper) {
            id = paper.id
            title = paper.title
        }
    }

    public struct Match: Identifiable, Sendable {
        public let id: UUID
        public let displayTitle: String
    }

    private var source: [Document] = []
    private var ordered: [(document: Document, match: Match)] = []

    public init() {}

    public func search(_ query: String, in documents: [Document]) throws -> [Match] {
        let search = TitleSearch(query)
        guard !search.raw.isEmpty else { return [] }
        try Task.checkCancellation()
        if source != documents {
            var rows: [(document: Document, match: Match)] = []
            for document in documents {
                try Task.checkCancellation()
                rows.append((document, Match(id: document.id, displayTitle: PaperTitle.display(document.title))))
            }
            try rows.sort {
                try Task.checkCancellation()
                let order = $0.match.displayTitle.localizedStandardCompare($1.match.displayTitle)
                return order == .orderedSame
                    ? $0.document.id.uuidString < $1.document.id.uuidString : order == .orderedAscending
            }
            source = documents
            ordered = rows
        }
        var matches: [Match] = []
        for row in ordered {
            try Task.checkCancellation()
            if search.matches(row.document.title, displayTitle: row.match.displayTitle) { matches.append(row.match) }
        }
        return matches
    }
}
