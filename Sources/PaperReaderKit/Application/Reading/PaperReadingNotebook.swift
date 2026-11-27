import Foundation

/// Resolves saved runs and standalone document-end notes against their current editable content.
public struct PaperReadingNotebook: Identifiable, Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let focus: String
        public let note: ReadingNote
        public let annotations: [ReadingNote]
    }

    public struct MarginNoteGroup: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let latestModifiedAt: Date
        public let notes: [ReadingNote]
    }

    public let id: UUID
    public let title: String
    public let entries: [Entry]

    public static func notebooks(in library: LibraryState) -> [Self] {
        let active = Dictionary(
            library.readingNotes.lazy.filter { $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let reports = library.chats.reversed().compactMap { turn -> Entry? in
            guard turn.closeReadingVersion != nil else { return nil }
            var seen = Set<UUID>()
            let annotations = (turn.closeReadingNoteIDs ?? []).compactMap { id -> ReadingNote? in
                guard seen.insert(id).inserted, let note = active[id], note.paperID == turn.paperID,
                    !note.isDocumentSummary
                else { return nil }
                return note
            }
            if let id = turn.readingNoteID, let note = active[id], note.paperID == turn.paperID,
                note.isDocumentSummary
            {
                return Entry(
                    id: turn.id, date: turn.createdAt, focus: turn.question, note: note, annotations: annotations)
            }
            guard let first = annotations.first else { return nil }
            return Entry(
                id: turn.id, date: turn.createdAt, focus: turn.question, note: first,
                annotations: Array(annotations.dropFirst()))
        }
        let referenced = Set(reports.map(\.note.id))
        let standalone = library.readingNotes.reversed().compactMap { note -> Entry? in
            guard note.isDocumentSummary, note.deletedAt == nil, !referenced.contains(note.id) else { return nil }
            return Entry(id: note.id, date: note.createdAt, focus: "", note: note, annotations: [])
        }
        let ordered = (reports + standalone).sorted { $0.date > $1.date }
        let grouped = Dictionary(grouping: ordered, by: \.note.paperID)
        let titles = Dictionary(
            library.papers.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return ordered.compactMap { entry in
            let id = entry.note.paperID
            guard seen.insert(id).inserted, let title = titles[id], let entries = grouped[id] else { return nil }
            return Self(id: id, title: title, entries: entries)
        }
    }

    /// Papers that have active margin/passage notes not already surfaced inside a close-reading
    /// notebook run, so readers who annotate offline without running AI close reading still find
    /// their notes in the library's Reading Notes section.
    public static func marginNoteGroups(in library: LibraryState) -> [MarginNoteGroup] {
        let coveredIDs = Set(
            notebooks(in: library).flatMap { notebook in
                notebook.entries.flatMap { [$0.note.id] + $0.annotations.map(\.id) }
            })
        let titles = Dictionary(
            library.papers.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        let remaining = library.readingNotes.filter {
            $0.deletedAt == nil && !coveredIDs.contains($0.id) && titles[$0.paperID] != nil
        }
        let grouped = Dictionary(grouping: remaining, by: \.paperID)
        return grouped.compactMap { paperID, notes -> MarginNoteGroup? in
            guard let title = titles[paperID], !notes.isEmpty else { return nil }
            let ordered = notes.sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            return MarginNoteGroup(
                id: paperID, title: title, latestModifiedAt: ordered[0].modifiedAt, notes: ordered)
        }.sorted {
            if $0.latestModifiedAt != $1.latestModifiedAt { return $0.latestModifiedAt > $1.latestModifiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
