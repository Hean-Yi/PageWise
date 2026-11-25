import Foundation
import PaperReaderKit

struct LocalPassagePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let noteID: UUID
    let title: String
    let location: String
    let before: String
    let quote: String
    let after: String
    var readingNoteID: UUID?
    var noteMarkdown: String?
}

extension ReaderModel {
    func makeLocalPassageCitation(evidence: Evidence, quote: String) async throws -> LocalPassageCitation {
        guard let paperID = evidence.paperID, evidence.notePath == nil, !quote.isEmpty, quote.utf8.count <= 8_000
        else { throw ReaderError.message("请选择本地论文中的一段原文。") }
        if let id = evidence.readingNoteID {
            guard let paper = state.papers.first(where: { $0.id == paperID }),
                let note = referencedReadingNote(id: id, paperID: paperID),
                evidence.text.contains(quote), ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(quote)
            else { throw ReaderError.message("这段引文与书库笔记的当前内容不符。") }
            return LocalPassageCitation(note: note, digest: paper.digest, quote: quote)
        }
        let scope = try discussionNoteScope(for: paperID)
        let location = try await verifiedDiscussionLocation(in: scope, sources: [(evidence, quote)])
        return LocalPassageCitation(
            paperID: paperID, digest: scope.digest, contentVersion: location.version,
            anchors: location.anchors, quote: quote)
    }

    func validateNoteCitations(_ citations: [LocalPassageCitation], markdown: String, documentEnd: Bool = false)
        async throws
    {
        let limit = documentEnd ? LocalPassageCitation.notebookLimit : LocalPassageCitation.marginLimit
        guard citations.count <= limit else { throw ReaderError.message("这条笔记最多可登记 " + String(limit) + " 个引用。") }
        var authorized = Set<String>()
        for citation in citations {
            let url = citation.url.absoluteString.lowercased()
            guard authorized.insert(url).inserted, markdown.localizedCaseInsensitiveContains(url) else {
                throw ReaderError.message("笔记中的引文与登记的本地来源不符。")
            }
            if citation.readingNoteID == nil {
                _ = try await resolvedLocalPassage(citation)
            } else {
                try validateLocalPassageTargets([citation])
            }
        }
        // Links in prose, including pasted and simulated tool output, cannot name another note's destination.
        for match in markdown.matches(of: /(?i)paperreader:[^\s)<>\]]*/) {
            guard authorized.contains(String(match.output).lowercased()) else {
                throw ReaderError.message("笔记含有未登记的本地引用，请从书库选择笔记。")
            }
        }
    }

    func insertLocalPassageCitation(
        _ citation: LocalPassageCitation, noteID: UUID, anchors: [NoteAnchor], markdown: String
    ) throws {
        try validateLocalPassageTargets([citation])
        guard markdown.localizedCaseInsensitiveContains(citation.url.absoluteString)
        else { throw ReaderError.message("目标引文已不可用，请重新选择。") }
        let current = currentReadingNotes.first { $0.id == noteID }
        let registered = current?.citations ?? []
        guard let target = citation.readingNoteID, target != noteID else {
            throw ReaderError.message("请选择另一条书库笔记。")
        }
        var used = registered.filter { markdown.localizedCaseInsensitiveContains($0.url.absoluteString) }
        if !used.contains(citation) { used.append(citation) }
        let limit =
            current?.placement == .documentEnd ? LocalPassageCitation.notebookLimit : LocalPassageCitation.marginLimit
        guard used.count <= limit else {
            throw ReaderError.message("这条笔记最多可登记 " + String(limit) + " 个引用。")
        }
        guard updateReadingNote(id: noteID, anchors: anchors, markdown: markdown),
            let index = state.readingNotes.firstIndex(where: { $0.id == noteID && $0.deletedAt == nil })
        else { throw ReaderError.message("笔记位置已变化，请重新打开后插入原文。") }
        if registered != used {
            state.readingNotes[index].citations = used
            state.readingNotes[index].modifiedAt = Date()
            noteRevision += 1
            noteSaveTask?.cancel()
            noteSaveTask = Task { [weak self] in await self?.flushReadingNotes() }
        }
    }

    func validateLocalPassageTargets(_ citations: [LocalPassageCitation]) throws {
        for citation in citations {
            if let target = citation.readingNoteID {
                guard let note = referencedReadingNote(id: target, paperID: citation.paperID),
                    let paper = state.papers.first(where: { $0.id == note.paperID && $0.digest == citation.digest }),
                    !citation.quote.isEmpty,
                    ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(citation.quote),
                    LocalPassageCitation(note: note, digest: paper.digest, quote: citation.quote) == citation
                else { throw ReaderError.message("引用的书库笔记或摘录已变化。") }
                continue
            }
            let unavailable = ReaderError.message("引用的本地原文或阅读版本已不可用。")
            guard let paper = state.papers.first(where: { $0.id == citation.paperID && $0.digest == citation.digest }),
                !pendingImportIDs.contains(paper.id), let first = citation.anchors.first
            else { throw unavailable }
            if let page = first.pdfPageIndex {
                guard citation.contentVersion == paper.digest + ":original-0", (0..<paper.pageCount).contains(page),
                    citation.anchors.allSatisfy({ $0.pdfPageIndex == page })
                else { throw unavailable }
            } else {
                guard paper.htmlPosition(version: citation.contentVersion, pageKeys: citation.anchors.map(\.key)) != nil
                else { throw unavailable }
            }
        }
    }

    private func registeredLocalPassage(noteID: UUID, citationID: UUID) throws -> LocalPassageCitation {
        guard let note = currentReadingNotes.first(where: { $0.id == noteID }),
            let citation = note.citations?.first(where: { $0.id == citationID }),
            note.markdown.localizedCaseInsensitiveContains(citation.url.absoluteString)
        else { throw ReaderError.message("这条笔记没有登记该链接。") }
        return citation
    }

    func previewLocalPassage(noteID: UUID, citationID: UUID) async throws -> LocalPassagePreview {
        let citation = try registeredLocalPassage(noteID: noteID, citationID: citationID)
        if let id = citation.readingNoteID {
            let (note, paper) = try noteTarget(citation, id: id)
            return LocalPassagePreview(
                id: citationID, noteID: noteID, title: paper.title, location: "阅读笔记",
                before: "", quote: ReadingNoteMemoryIndex.searchableBody(note.markdown), after: "",
                readingNoteID: note.id, noteMarkdown: note.markdown)
        }
        let result = try await resolvedLocalPassage(citation)
        guard try registeredLocalPassage(noteID: noteID, citationID: citationID) == citation else {
            throw ReaderError.message("笔记中的引用已变化。")
        }
        return LocalPassagePreview(
            id: citationID, noteID: noteID, title: result.title, location: result.location,
            before: result.before, quote: citation.quote, after: result.after)
    }

    func openLocalPassage(_ preview: LocalPassagePreview) async throws {
        let citation = try registeredLocalPassage(noteID: preview.noteID, citationID: preview.id)
        if let id = citation.readingNoteID {
            let (note, paper) = try noteTarget(citation, id: id)
            if selectedPaperID != paper.id { select(paper.id) }
            openReadingNote(note)
            return
        }
        _ = try await previewLocalPassage(noteID: preview.noteID, citationID: preview.id)
        guard let paper = state.papers.first(where: { $0.id == citation.paperID && $0.digest == citation.digest }),
            let first = citation.anchors.first
        else { throw ReaderError.message("引用的论文已不在本地书库。") }
        let page: Int
        let retained: UUID?
        let targetMode: String
        if let index = first.pdfPageIndex {
            page = index
            retained = nil
            targetMode = "original"
        } else if let position = paper.htmlPosition(
            version: citation.contentVersion, pageKeys: citation.anchors.map(\.key))
        {
            page = position.index
            retained = position.editionID
            targetMode = "translated"
        } else {
            throw ReaderError.message("找不到被引用的原文版本。")
        }
        if selectedPaperID != paper.id { select(paper.id) }
        pdfBilingual.close()
        pdfNoteEditor = nil
        requestedReadingNote = nil
        retainedReadingID = retained
        mode = targetMode
        navigateToPage(page)
        jumpPassageAnchors = citation.anchors
    }

    private func resolvedLocalPassage(_ citation: LocalPassageCitation) async throws -> (
        title: String, location: String, before: String, after: String
    ) {
        let unavailable = ReaderError.message("引用的本地原文或阅读版本已不可用。")
        guard let paper = state.papers.first(where: { $0.id == citation.paperID && $0.digest == citation.digest }),
            !pendingImportIDs.contains(paper.id), let first = citation.anchors.first
        else { throw unavailable }
        let context: (before: String, after: String)
        let location: String
        if let index = first.pdfPageIndex {
            guard citation.contentVersion == paper.digest + ":original-0", (0..<paper.pageCount).contains(index) else {
                throw unavailable
            }
            context = try await PDFReadingNoteLocator().citationContext(
                for: citation, documentURL: root.appendingPathComponent(paper.originalPath))
            location = "原文第 \(index + 1) 页"
        } else {
            guard
                let position = paper.htmlPosition(
                    version: citation.contentVersion, pageKeys: citation.anchors.map(\.key)),
                let html = position.editionID.flatMap({ id in paper.retainedReadings?.first { $0.id == id }?.html })
                    ?? paper.htmlReading
            else { throw unavailable }
            context = try await htmlNoteStore.citationContext(for: citation, artifact: html, root: root)
            location = "源码第 \(position.index + 1) 段"
        }
        try validateLocalPassageTargets([citation])
        return (paper.title, location, context.before, context.after)
    }
}

extension ReaderModel {
    /// Read live note state whenever a recalled result is used; an old tool result cannot revive a deleted note.
    func referencedReadingNote(id: UUID, paperID: UUID, includeArchived: Bool = true) -> ReadingNote? {
        guard !pendingImportIDs.contains(paperID), state.papers.contains(where: { $0.id == paperID }) else {
            return nil
        }
        guard
            let note = state.readingNotes.first(where: {
                $0.id == id && $0.paperID == paperID && $0.deletedAt == nil
                    && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { return nil }
        return includeArchived ? note : ChatSourceVersions.recalledNote(note, in: state, excluding: pendingImportIDs)
    }

    func referencedReadingNote(for evidence: Evidence, includeArchived: Bool = false) -> ReadingNote? {
        guard let id = evidence.readingNoteID, let paper = evidence.paperID, !evidence.text.isEmpty,
            let note = referencedReadingNote(id: id, paperID: paper, includeArchived: includeArchived),
            ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(evidence.text)
        else { return nil }
        return note
    }

    private func noteTarget(_ citation: LocalPassageCitation, id: UUID) throws -> (ReadingNote, Paper) {
        guard let paper = state.papers.first(where: { $0.id == citation.paperID && $0.digest == citation.digest }),
            let note = referencedReadingNote(id: id, paperID: paper.id),
            note.contentVersion == citation.contentVersion
        else { throw ReaderError.message("被引用的阅读笔记已删除或不在本地书库。") }
        return (note, paper)
    }

    func readingNoteEvidence(
        query: String, excluding: UUID? = nil, paperID: UUID? = nil, limit: Int = 6, includeArchived: Bool = false
    ) async throws -> [Evidence] {
        let hits = try await readingNoteIndex.search(
            query: query, state: state, pending: pendingImportIDs, excluding: excluding, paperID: paperID, limit: limit,
            includeArchived: includeArchived)
        try Task.checkCancellation()
        return hits.filter { referencedReadingNote(for: $0, includeArchived: includeArchived) != nil }
    }
}
