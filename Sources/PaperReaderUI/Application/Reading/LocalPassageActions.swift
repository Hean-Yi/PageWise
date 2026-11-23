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
}

extension ReaderModel {
    func makeLocalPassageCitation(evidence: Evidence, quote: String) async throws -> LocalPassageCitation {
        guard let paperID = evidence.paperID, evidence.notePath == nil, !quote.isEmpty, quote.utf8.count <= 8_000
        else { throw ReaderError.message("请选择本地论文中的一段原文。") }
        let scope = try discussionNoteScope(for: paperID)
        let location = try await verifiedDiscussionLocation(in: scope, sources: [(evidence, quote)])
        return LocalPassageCitation(
            paperID: paperID, digest: scope.digest, contentVersion: location.version,
            anchors: location.anchors, quote: quote)
    }

    func makeLocalPassageCitation(choice: LocalPassageChoice) async throws -> LocalPassageCitation {
        let citation: LocalPassageCitation
        if let id = choice.evidence.paperID, let index = choice.evidence.sourcePage, !choice.pdfRanges.isEmpty {
            let scope = try discussionNoteScope(for: id)
            let located = try await PDFReadingNoteLocator().locate(
                quote: choice.quote, pageIndex: index,
                in: root.appendingPathComponent(scope.originalPath), selectedRanges: choice.pdfRanges)
            try validateDiscussionScope(scope)
            citation = LocalPassageCitation(
                paperID: id, digest: scope.digest, contentVersion: scope.digest + ":original-0",
                anchors: located.map(\.anchor), quote: choice.quote)
        } else {
            citation = try await makeLocalPassageCitation(evidence: choice.evidence, quote: choice.quote)
        }
        verifiedPassageChoices = Array(verifiedPassageChoices.suffix(15)) + [citation]
        return citation
    }

    func validateNoteCitations(_ citations: [LocalPassageCitation], markdown: String) async throws {
        guard citations.count <= 16 else { throw ReaderError.message("一条笔记最多可引用十六个原文片段。") }
        var authorized = Set<String>()
        for citation in citations {
            let url = citation.url.absoluteString.lowercased()
            guard authorized.insert(url).inserted, markdown.localizedCaseInsensitiveContains(url) else {
                throw ReaderError.message("笔记中的引文与登记的本地来源不符。")
            }
            _ = try await resolvedLocalPassage(citation)
        }
        // Links in prose, including pasted and simulated tool output, cannot name another note's destination.
        for match in markdown.matches(of: /(?i)paperreader:[^\s)<>\]]*/) {
            guard authorized.contains(String(match.output).lowercased()) else {
                throw ReaderError.message("笔记含有未登记的本地引用，请从书库插入原文。")
            }
        }
    }

    func insertLocalPassageCitation(
        _ citation: LocalPassageCitation, noteID: UUID, anchors: [NoteAnchor], markdown: String
    ) throws {
        try validateLocalPassageTargets([citation])
        guard markdown.localizedCaseInsensitiveContains(citation.url.absoluteString)
        else { throw ReaderError.message("目标引文已不可用，请重新选择。") }
        let registered = currentReadingNotes.first { $0.id == noteID }?.citations ?? []
        guard verifiedPassageChoices.contains(citation) || registered.contains(citation) else {
            throw ReaderError.message("请选择书库中核对过的原文片段。")
        }
        var used = registered.filter { markdown.localizedCaseInsensitiveContains($0.url.absoluteString) }
        if !used.contains(citation) { used.append(citation) }
        guard used.count <= 16 else {
            throw ReaderError.message("一条笔记最多可引用十六个原文片段。")
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
        else { throw ReaderError.message("这条笔记没有登记该原文链接。") }
        return citation
    }

    func previewLocalPassage(noteID: UUID, citationID: UUID) async throws -> LocalPassagePreview {
        let citation = try registeredLocalPassage(noteID: noteID, citationID: citationID)
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
            context = try await HTMLReadingStore().citationContext(for: citation, artifact: html, root: root)
            location = "源码第 \(position.index + 1) 段"
        }
        try validateLocalPassageTargets([citation])
        return (paper.title, location, context.before, context.after)
    }
}

extension ReaderModel {
    func localPassageChoices(paperID: UUID, query: String, pageIndex: Int? = nil) async throws -> [LocalPassageChoice] {
        guard let paper = state.papers.first(where: { $0.id == paperID }), !pendingImportIDs.contains(paperID)
        else { throw ReaderError.message("论文已不在本地书库。") }
        return try await LocalPassageSearch.choices(paper: paper, root: root, query: query, pageIndex: pageIndex)
    }

    func relatedLocalPassages(query: String, excluding paperID: UUID, limit: Int = 6) async throws -> [Evidence] {
        let candidates = state.papers.filter { $0.id != paperID && !pendingImportIDs.contains($0.id) }
        return try await LocalPassageSearch.related(query: query, papers: candidates, root: root, limit: limit)
    }
}
