import Foundation

/// Resolves saved runs and standalone document-end notes against their current editable content.
public struct PaperReadingNotebook: Identifiable, Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let focus: String
        public let note: ReadingNote
    }

    public let id: UUID
    public let title: String
    public let entries: [Entry]

    public static func notebooks(in library: LibraryState) -> [Self] {
        let summaries = Dictionary(
            library.readingNotes.lazy.filter { $0.isDocumentSummary && $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let reports = library.chats.reversed().compactMap { turn -> Entry? in
            guard turn.closeReadingVersion != nil, let id = turn.readingNoteID, let note = summaries[id],
                note.paperID == turn.paperID
            else { return nil }
            return Entry(id: turn.id, date: turn.createdAt, focus: turn.question, note: note)
        }
        let referenced = Set(reports.map(\.note.id))
        let standalone = library.readingNotes.reversed().compactMap { note -> Entry? in
            guard note.isDocumentSummary, note.deletedAt == nil, !referenced.contains(note.id) else { return nil }
            return Entry(id: note.id, date: note.createdAt, focus: "", note: note)
        }
        let ordered = (reports + standalone).sorted { $0.date > $1.date }
        let grouped = Dictionary(grouping: ordered, by: \.note.paperID)
        let titles = Dictionary(library.papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return ordered.compactMap { entry in
            let id = entry.note.paperID
            guard seen.insert(id).inserted, let title = titles[id], let entries = grouped[id] else { return nil }
            return Self(id: id, title: title, entries: entries)
        }
    }
}
