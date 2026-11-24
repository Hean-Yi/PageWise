import Foundation
import PaperReaderKit

extension Paper {
    func htmlPosition(version: String, pageKeys: [String]) -> (editionID: UUID?, index: Int)? {
        guard let first = pageKeys.first else { return nil }
        let editions: [(id: UUID?, html: HTMLReadingArtifact?)] =
            [(nil, htmlReading)] + (retainedReadings ?? []).map { ($0.id, $0.html) }
        for edition in editions {
            guard let html = edition.html, html.readingNoteVersion(digest: digest) == version,
                Set(pageKeys).isSubset(of: Set(html.sections.map { $0.id.uuidString })),
                let index = html.sections.firstIndex(where: { $0.id.uuidString == first })
            else { continue }
            return (edition.id, index)
        }
        return nil
    }
}

extension ReaderModel {
    public var currentReadingNotes: [ReadingNote] {
        state.readingNotes.filter { $0.paperID == selectedPaperID && $0.deletedAt == nil }
    }

    var currentDocumentSummary: ReadingNote? {
        guard let paper else { return nil }
        let pdf = paper.digest + ":original-0"
        let html = paper.htmlReading?.readingNoteVersion(digest: paper.digest)
        let versions = [html, retainedReadingID == nil ? pdf : nil].compactMap { $0 }
        let notes = currentReadingNotes.filter { $0.isDocumentSummary && versions.contains($0.contentVersion) }
        if let requested = notes.first(where: { $0.id == requestedReadingNote }) { return requested }
        for version in versions {
            if let note = notes.last(where: { $0.contentVersion == version }) { return note }
        }
        return nil
    }

    /// Past runs remain in the notes list and in citations. On the page show the latest
    /// run for each focus, together with manual notes and any earlier notes the reader edited.
    var inlineReadingNotes: [ReadingNote] {
        guard let paperID = selectedPaperID else { return [] }
        let archived = archivedCloseReadingNoteIDs(for: paperID)
        return currentReadingNotes.filter {
            !$0.isDocumentSummary
                && (!archived.contains($0.id) || $0.modifiedAt != $0.createdAt || $0.id == requestedReadingNote)
        }
    }

    private func archivedCloseReadingNoteIDs(for paperID: UUID) -> Set<UUID> {
        var all = Set<UUID>()
        var visible = Set<UUID>()
        var seen = Set<[String]>()
        for report in state.chats.reversed() where report.paperID == paperID {
            guard let version = report.closeReadingVersion, let ids = report.closeReadingNoteIDs else { continue }
            all.formUnion(ids)
            if seen.insert([version, report.question]).inserted { visible.formUnion(ids) }
        }
        return all.subtracting(visible)
    }

    var displayedHTMLReadingNotes: [ReadingNote] {
        guard usesHTMLReading, let paper, let version = paper.htmlReading?.readingNoteVersion(digest: paper.digest)
        else { return [] }
        return inlineReadingNotes.filter { $0.contentVersion == version && $0.anchors.first?.pdfPageIndex == nil }
    }

    @discardableResult
    func updateDocumentSummary(id: UUID, markdown: String) -> Bool {
        guard let summary = presentedDocumentSummary ?? currentDocumentSummary, summary.id == id,
            let index = state.readingNotes.firstIndex(where: { $0.id == id })
        else { return false }
        guard summary.markdown != markdown else { return true }
        state.readingNotes[index].markdown = markdown
        state.readingNotes[index].modifiedAt = Date()
        scheduleReadingNoteSave()
        return true
    }

    @discardableResult
    func updateReadingNote(id: UUID, anchors: [NoteAnchor], markdown: String) -> Bool {
        if anchors.isEmpty { return updateDocumentSummary(id: id, markdown: markdown) }
        guard let paper, !anchors.isEmpty,
            usesHTMLReading
                || (pdfNoteEditor?.note.id == id && pdfNoteEditor?.note.paperID == paper.id
                    && pdfNoteEditor?.note.anchors == anchors),
            anchors.allSatisfy({
                pageKeys.contains($0.key) && $0.start >= 0 && $0.end > $0.start
                    && $0.end - $0.start == $0.text.utf16.count
            })
        else { return false }
        let version = htmlAnnotationVersion ?? (paper.digest + ":original-0")
        if let index = state.readingNotes.firstIndex(where: { $0.id == id }) {
            guard state.readingNotes[index].paperID == paper.id, state.readingNotes[index].contentVersion == version,
                state.readingNotes[index].anchors == anchors,
                state.readingNotes[index].deletedAt == nil
            else { return false }
            guard state.readingNotes[index].markdown != markdown else { return true }
            state.readingNotes[index].markdown = markdown
            state.readingNotes[index].modifiedAt = Date()
        } else {
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            if let draft = pdfNoteEditor, draft.note.id == id {
                let insertion = AnchoredNoteInsertion(note: draft.note, highlights: draft.marks, scope: nil)
                state.highlights.append(contentsOf: insertion.newHighlights(in: state.highlights))
            }
            state.readingNotes.append(
                ReadingNote(
                    id: id, paperID: paper.id,
                    contentVersion: version, anchors: anchors, markdown: markdown))
        }
        scheduleReadingNoteSave()
        return true
    }

    private func scheduleReadingNoteSave() {
        noteRevision += 1
        noteSaveFailed = false
        noteSaveTask?.cancel()
        noteSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await self?.flushReadingNotes()
        }
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
        if presentedSummaryID == id { closeDocumentSummary() }
        state.readingNotes[index].deletedAt = Date()
        if pdfNoteEditor?.id == id {
            pdfNoteEditor = nil
            requestedReadingNote = nil
        }
        lastDeletedNoteID = id
        noteRevision += 1
        Task { await flushReadingNotes() }
    }

    public func undoReadingNoteDeletion() {
        guard let id = lastDeletedNoteID, let index = state.readingNotes.firstIndex(where: { $0.id == id }) else {
            return
        }
        state.readingNotes[index].deletedAt = nil
        let note = state.readingNotes[index]
        if note.modifiedAt == note.createdAt, archivedCloseReadingNoteIDs(for: note.paperID).contains(id) {
            // The reader explicitly restored an archived machine note to its original passage.
            state.readingNotes[index].modifiedAt = Date()
        }
        lastDeletedNoteID = nil
        noteRevision += 1
        Task { await flushReadingNotes() }
    }

    var presentedDocumentSummary: ReadingNote? {
        guard let presentedSummaryID else { return nil }
        return currentReadingNotes.first { $0.id == presentedSummaryID && $0.isDocumentSummary }
    }

    func closeDocumentSummary() {
        guard let id = presentedSummaryID else { return }
        presentedSummaryID = nil
        if requestedReadingNote == id { requestedReadingNote = nil }
        Task { await flushReadingNotes() }
    }

    public func openReadingNote(_ note: ReadingNote) {
        guard note.paperID == selectedPaperID else { return }
        if note.isDocumentSummary {
            guard currentReadingNotes.contains(where: { $0.id == note.id && $0.isDocumentSummary }) else { return }
            pdfNoteEditor = nil
            presentedSummaryID = note.id
            requestedReadingNote = note.id
            return
        }
        guard let first = note.anchors.first else { return }
        closeDocumentSummary()
        if let index = first.pdfPageIndex {
            guard let current = currentEdition, note.contentVersion == current.digest + ":original-0",
                (0..<current.pageCount).contains(index), currentReadingNotes.contains(where: { $0.id == note.id })
            else { return }
            pdfBilingual.close()
            retainedReadingID = nil
            mode = "original"
            navigateToPage(index)
            pdfNoteEditor = PDFNoteEditorSession(note: note, marks: [])
            requestedReadingNote = note.id
            readingNoteNavigationToken = UUID()
            return
        }
        guard let current = currentEdition else { return }
        if let position = current.htmlPosition(version: note.contentVersion, pageKeys: note.anchors.map(\.key)) {
            pdfNoteEditor = nil
            retainedReadingID = position.editionID
            mode = "translated"
            navigateToPage(position.index)
            requestedReadingNote = note.id
            readingNoteNavigationToken = UUID()
            return
        }
        message = "无法在这条笔记对应的阅读版本中找到原文。"
    }
}
