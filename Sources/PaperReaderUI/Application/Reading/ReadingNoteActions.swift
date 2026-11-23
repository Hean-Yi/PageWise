import Foundation
import PaperReaderKit

extension ReaderModel {
    public var currentReadingNotes: [ReadingNote] {
        state.readingNotes.filter { $0.paperID == selectedPaperID && $0.deletedAt == nil }
    }

    @discardableResult
    func updateReadingNote(id: UUID, anchors: [NoteAnchor], markdown: String) -> Bool {
        guard let paper, usesHTMLReading, !anchors.isEmpty,
            anchors.allSatisfy({
                pageKeys.contains($0.key) && $0.start >= 0 && $0.end > $0.start
                    && $0.end - $0.start == $0.text.utf16.count
            })
        else { return false }
        if let index = state.readingNotes.firstIndex(where: { $0.id == id }) {
            guard state.readingNotes[index].paperID == paper.id, state.readingNotes[index].anchors == anchors,
                state.readingNotes[index].deletedAt == nil
            else { return false }
            guard state.readingNotes[index].markdown != markdown else { return true }
            state.readingNotes[index].markdown = markdown
            state.readingNotes[index].modifiedAt = Date()
        } else {
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            state.readingNotes.append(
                ReadingNote(
                    id: id, paperID: paper.id,
                    contentVersion: paper.digest + ":" + (pageKeys.first ?? ""), anchors: anchors, markdown: markdown))
        }
        noteRevision += 1
        noteSaveFailed = false
        noteSaveTask?.cancel()
        noteSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await self?.flushReadingNotes()
        }
        return true
    }

    public func flushReadingNotes() async {
        noteSaveTask?.cancel()
        noteSaveTask = nil
        let revision = noteRevision
        guard revision > savedNoteRevision else { return }
        if await save() {
            savedNoteRevision = max(savedNoteRevision, revision)
            noteSaveFailed = false
        } else {
            noteSaveFailed = true
        }
    }

    public func deleteReadingNote(_ id: UUID) {
        guard let index = state.readingNotes.firstIndex(where: { $0.id == id && $0.paperID == selectedPaperID }) else {
            return
        }
        state.readingNotes[index].deletedAt = Date()
        lastDeletedNoteID = id
        noteRevision += 1
        Task { await flushReadingNotes() }
    }

    public func undoReadingNoteDeletion() {
        guard let id = lastDeletedNoteID, let index = state.readingNotes.firstIndex(where: { $0.id == id }) else {
            return
        }
        state.readingNotes[index].deletedAt = nil
        lastDeletedNoteID = nil
        noteRevision += 1
        Task { await flushReadingNotes() }
    }

    public func openReadingNote(_ note: ReadingNote) {
        guard note.paperID == selectedPaperID, let first = note.anchors.first else { return }
        if let current = state.papers.first(where: { $0.id == note.paperID }) {
            retainedReadingID =
                current.readingPages.contains(where: { $0.id.uuidString == first.key })
                ? nil
                : current.retainedReadings?.first(where: { $0.readingPages.contains { $0.id.uuidString == first.key } }
                )?.id
        }
        guard let paper, let position = PaperPageLocator.resolve(pageKey: first.key, in: paper) else { return }
        mode = position.mode
        navigateToPage(position.pageIndex)
        requestedReadingNote = note.id
        readingNoteNavigationToken = UUID()
    }
}
