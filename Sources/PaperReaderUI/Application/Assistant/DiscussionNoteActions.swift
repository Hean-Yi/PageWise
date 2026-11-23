import Foundation
import PaperReaderKit

/// Captured before a model request. Published HTML sections can be appended while a discussion is in flight.
struct DiscussionNoteScope {
    let paperID: UUID
    let digest: String
    let originalPath: String
    let pageCount: Int
    let htmlReading: HTMLReadingArtifact?
    let prefersHTML: Bool
    let selectedPaperID: UUID?
    let retainedID: UUID?
    let readingMode: String?
    let selection: [NoteAnchor]
    let pdfSelection: [Int: [NSRange]]
    let pdfSelectedText: [Int: String]
}

typealias DiscussionNoteSource = (evidence: Evidence, quote: String)

struct AnchoredNoteInsertion {
    let note: ReadingNote
    let highlights: [Highlight]
    let scope: DiscussionNoteScope?

    func existing(in notes: [ReadingNote]) throws -> ReadingNote? {
        if let same = notes.first(where: { $0.id == note.id }) {
            guard same.deletedAt == nil, same.paperID == note.paperID,
                same.contentVersion == note.contentVersion, same.anchors == note.anchors
            else { throw ReaderError.message("这次操作对应的笔记已删除或位置已变化。") }
            return same
        }
        return notes.first {
            $0.deletedAt == nil && $0.paperID == note.paperID && $0.contentVersion == note.contentVersion
                && $0.anchors == note.anchors && $0.markdown == note.markdown && $0.dimension == note.dimension
                && ($0.citations ?? []) == (note.citations ?? [])
        }
    }

    /// Add only uncovered ranges, so writing a note on a reader's colored mark preserves their styling.
    func newHighlights(in current: [Highlight]) -> [Highlight] {
        var additions: [Highlight] = []
        for mark in highlights {
            let overlaps = (current + additions).filter {
                $0.paperID == mark.paperID && $0.pageKey == mark.pageKey
                    && ($0.contentVersion == nil || $0.contentVersion == mark.contentVersion)
            }
            if mark.htmlTarget != nil {
                guard !overlaps.contains(where: { $0.htmlTarget == nil && $0.textRange != nil }) else { continue }
                let covering = overlaps.filter { $0.htmlTarget == mark.htmlTarget }
                additions += AnnotationRangeEditor.applying(
                    covering, to: [mark], color: .yellow, style: .highlight, removing: true)
            } else if let uncovered = mark.uncoveredPDFHighlight(against: overlaps) {
                additions.append(uncovered)
            }
        }
        return additions
    }
}

extension ReaderModel {
    func discussionNoteScope(for paperID: UUID) throws -> DiscussionNoteScope {
        guard let document = state.papers.first(where: { $0.id == paperID }), !pendingImportIDs.contains(paperID)
        else { throw ReaderError.message("这篇论文已不在本地书库。") }
        let active = selectedPaperID == paperID
        let reading = active ? (paper ?? document) : document
        let artifact = reading.htmlReading
        let selection =
            active && usesHTMLReading
            ? htmlSelection.map {
                NoteAnchor(key: $0.pageKey, target: $0.target, text: $0.text, start: $0.start, end: $0.end)
            } : []
        var ranges: [Int: [NSRange]] = [:]
        var selected: [Int: String] = [:]
        if active, mode == "original" {
            let sentences = pdfBilingual.selectedSourceSentences
            if !sentences.isEmpty {
                for (page, parts) in Dictionary(grouping: sentences, by: \.pageIndex) {
                    ranges[page] = parts.flatMap(\.characterRanges)
                    selected[page] = parts.map(\.text).joined(separator: " ")
                }
            } else if !pdfSelectionRanges.isEmpty {
                ranges[selectionPage] = pdfSelectionRanges
                selected[selectionPage] = selectionText
            }
        }
        return DiscussionNoteScope(
            paperID: paperID, digest: document.digest, originalPath: document.originalPath,
            pageCount: document.pageCount,
            htmlReading: artifact, prefersHTML: active ? usesHTMLReading : artifact != nil,
            selectedPaperID: selectedPaperID, retainedID: active ? retainedReadingID : nil,
            readingMode: active ? mode : nil, selection: selection, pdfSelection: ranges, pdfSelectedText: selected)
    }

    func validateDiscussionScope(_ scope: DiscussionNoteScope, usesHTMLAnchor: Bool = false) throws {
        guard selectedPaperID == scope.selectedPaperID,
            state.papers.contains(where: { $0.id == scope.paperID && $0.digest == scope.digest }),
            !pendingImportIDs.contains(scope.paperID)
        else { throw ReaderError.message("当前论文已切换，请回到要标记的论文重试。") }
        if scope.prefersHTML || usesHTMLAnchor, scope.htmlReading?.sections.first != nil {
            _ = try currentHTML(for: scope)
        }
        if let modeAtRequest = scope.readingMode {
            guard mode == modeAtRequest && retainedReadingID == scope.retainedID else {
                throw ReaderError.message("阅读版本已切换，请在该版本重新记笔记。")
            }
        }
    }

    private func currentHTML(for scope: DiscussionNoteScope) throws -> HTMLReadingArtifact {
        let reading = scope.paperID == selectedPaperID ? paper : state.papers.first { $0.id == scope.paperID }
        guard let original = scope.htmlReading, let current = reading?.htmlReading,
            !original.sections.isEmpty,
            original.readingNoteVersion(digest: scope.digest) == current.readingNoteVersion(digest: scope.digest),
            current.sections.starts(
                with: original.sections,
                by: { current, captured in
                    current.id == captured.id && current.blockIDs == captured.blockIDs
                        && current.sourcePage == captured.sourcePage
                })
        else { throw ReaderError.message("原文版式已变化，请在要标记的版本重新记笔记。") }
        var pinned = original
        pinned.relativePath = current.relativePath
        return pinned
    }

    func saveDiscussionNote(
        in scope: DiscussionNoteScope, sources proposed: [DiscussionNoteSource], markdown: String,
        requestID: UUID, instruction: String = "", citations: [LocalPassageCitation] = [],
        dimension: CloseReadingDimension? = nil
    ) async throws -> ReadingNote {
        let insertion = try await prepareDiscussionNote(
            in: scope, sources: proposed, markdown: markdown, requestID: requestID,
            instruction: instruction, citations: citations, dimension: dimension)
        return try await saveAnchoredDiscussionNote(insertion.note, highlights: insertion.highlights, scope: scope)
    }

    func prepareDiscussionNote(
        in scope: DiscussionNoteScope, sources proposed: [DiscussionNoteSource], markdown: String,
        requestID: UUID, instruction: String = "", citations: [LocalPassageCitation] = [],
        dimension: CloseReadingDimension? = nil
    ) async throws -> AnchoredNoteInsertion {
        try validateDiscussionScope(scope)
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.utf8.count <= 24_000, (1...8).contains(proposed.count) else {
            throw ReaderError.message("笔记需要正文和一至八处可核对的原文。")
        }
        guard citations.allSatisfy({ $0.readingNoteID != nil || $0.paperID == scope.paperID }) else {
            throw ReaderError.message("跨论文引用须选择书库中的阅读笔记。")
        }
        let sources = try Self.sourcesMatchingInstruction(instruction, proposed: proposed, scope: scope)
        if ReadingNoteIntent.requestsDocumentSummary(instruction) {
            var references = citations
            var links: [String] = []
            var version: String?
            for (evidence, quote) in sources {
                guard evidence.paperID == scope.paperID, evidence.readingNoteID == nil else {
                    throw ReaderError.message("全文总结需要来自这篇论文的依据。")
                }
                let source = try await makeLocalPassageCitation(evidence: evidence, quote: quote)
                version = version ?? source.contentVersion
                if !references.contains(source) {
                    references.append(source)
                    links.append(source.markdown(label: "原文依据 " + String(links.count + 1)))
                }
            }
            let text = ([body] + links).joined(separator: "\n\n")
            try await validateNoteCitations(references, markdown: text)
            try validateDiscussionScope(scope)
            var note = ReadingNote(
                id: requestID, paperID: scope.paperID, contentVersion: version ?? closeReadingVersion(for: scope),
                anchors: [], markdown: text)
            note.placement = .documentEnd
            note.citations = references
            return AnchoredNoteInsertion(note: note, highlights: [], scope: scope)
        }
        let (version, anchors, marks) = try await verifiedDiscussionLocation(in: scope, sources: sources)
        try await validateNoteCitations(citations, markdown: body)
        try validateDiscussionScope(scope)
        var note = ReadingNote(
            id: requestID, paperID: scope.paperID, contentVersion: version, anchors: anchors, markdown: body)
        note.citations = citations.isEmpty ? nil : citations
        note.dimension = dimension
        let highlights = marks.map { original in
            var mark = original
            if let dimension { mark.color = dimension.color }
            return mark
        }
        return AnchoredNoteInsertion(note: note, highlights: highlights, scope: scope)
    }

    func verifiedDiscussionLocation(in scope: DiscussionNoteScope, sources: [DiscussionNoteSource]) async throws
        -> (version: String, anchors: [NoteAnchor], highlights: [Highlight])
    {
        let document = scope.paperID == selectedPaperID ? paper : state.papers.first { $0.id == scope.paperID }
        let published = Set(scope.htmlReading?.sections.flatMap(\.blockIDs) ?? [])
        let located = await Self.linkPublishedSources(sources, scope: scope, document: document, published: published)
        let html =
            located.contains { $0.evidence.sourcePage == nil }
            || (scope.prefersHTML
                && located.allSatisfy {
                    $0.evidence.blockID.map(published.contains) == true
                })
        var anchors: [NoteAnchor] = []
        var marks: [Highlight] = []
        let artifact = html ? try currentHTML(for: scope) : nil
        let version: String
        if html {
            guard let stamp = artifact?.readingNoteVersion(digest: scope.digest) else {
                throw ReaderError.message("这处引用尚无可标记的已发布正文。")
            }
            version = stamp
        } else {
            version = scope.digest + ":original-0"
        }
        let store = HTMLReadingStore()
        let pdf = PDFReadingNoteLocator()
        for (evidence, quote) in located {
            try Task.checkCancellation()
            guard evidence.paperID == scope.paperID, evidence.notePath == nil, evidence.readingNoteID == nil,
                !quote.isEmpty,
                quote.utf8.count <= 12_000,
                Self.containsDiscussionQuote(quote, in: evidence.text)
            else { throw ReaderError.message("引文与这篇论文提供的证据不符，请选择原句。") }
            if let artifact {
                let parts = try await store.noteAnchors(
                    for: quote, evidence: evidence, paperID: scope.paperID, artifact: artifact,
                    root: root, selection: scope.selection)
                for part in parts where !anchors.contains(part) {
                    guard let index = artifact.sections.firstIndex(where: { $0.id.uuidString == part.key }) else {
                        throw ReaderError.message("原文位置与阅读版本不符。")
                    }
                    var mark = Highlight(
                        paperID: scope.paperID, pageKey: part.key, pageIndex: index, text: part.text, rects: [])
                    mark.contentVersion = version
                    mark.textRange = [part.start, part.end]
                    mark.htmlTarget = part.target
                    mark.color = .yellow
                    mark.style = .highlight
                    anchors.append(part)
                    marks.append(mark)
                }
            } else {
                guard let page = evidence.sourcePage, (0..<scope.pageCount).contains(page) else {
                    throw ReaderError.message("这条证据缺少可核对的 PDF 原页。")
                }
                let inSelection = Self.containsDiscussionQuote(quote, in: scope.pdfSelectedText[page] ?? "")
                let parts = try await pdf.locate(
                    quote: quote, pageIndex: page, in: root.appendingPathComponent(scope.originalPath),
                    selectedRanges: inSelection ? scope.pdfSelection[page] ?? [] : [])
                for part in parts where !anchors.contains(part.anchor) {
                    anchors.append(part.anchor)
                    marks.append(part.highlight(for: scope.paperID))
                }
            }
        }
        try Task.checkCancellation()
        try validateDiscussionScope(scope)
        if html { _ = try currentHTML(for: scope) }
        return (version, anchors, marks)
    }

    private nonisolated static func sourcesMatchingInstruction(
        _ instruction: String, proposed: [DiscussionNoteSource], scope: DiscussionNoteScope
    ) throws -> [DiscussionNoteSource] {
        let requested = ReadingNoteIntent.requestedQuotations(in: instruction)
        guard requested.count <= 8 else { throw ReaderError.message("一条笔记最多可标画八处原文。") }
        guard !requested.isEmpty else { return proposed }
        return try requested.map { quote in
            let matches = proposed.map(\.evidence).filter {
                $0.paperID == scope.paperID && $0.notePath == nil
                    && Self.containsDiscussionQuote(quote, in: $0.text)
            }
            let selected = matches.filter { source in
                if let page = source.sourcePage,
                    Self.containsDiscussionQuote(quote, in: scope.pdfSelectedText[page] ?? "")
                {
                    return true
                }
                return scope.selection.contains { anchor in
                    guard Self.containsDiscussionQuote(quote, in: anchor.text) else { return false }
                    guard let block = source.blockID else { return source.sourcePage == nil }
                    return scope.htmlReading?.sections.contains {
                        $0.id.uuidString == anchor.key && $0.blockIDs.contains(block)
                    } == true
                }
            }
            let locations = selected.isEmpty ? matches : selected
            guard let first = locations.first,
                locations.allSatisfy({ $0.blockID == first.blockID && $0.sourcePage == first.sourcePage })
            else { throw ReaderError.message("无法唯一定位你指定的引文。可选中原句，再让我记录。") }
            return (evidence: first, quote: quote)
        }
    }

    private nonisolated static func linkPublishedSources(
        _ sources: [DiscussionNoteSource], scope: DiscussionNoteScope, document: Paper?, published: Set<UUID>
    ) async -> [DiscussionNoteSource] {
        // read_paper can return a physical PDF page for a TeX paper without a page-to-block index.
        // Keep the note in the open edition when its published source identifies a unique block.
        guard scope.prefersHTML else { return sources }
        return sources.map { source in
            var evidence = source.evidence
            if evidence.blockID == nil, evidence.sourcePage != nil {
                let blocks =
                    document?.blocks.filter {
                        published.contains($0.id) && Self.containsDiscussionQuote(source.quote, in: $0.text)
                    } ?? []
                if blocks.count == 1 { evidence.blockID = blocks[0].id }
            }
            return (evidence: evidence, quote: source.quote)
        }
    }

    private nonisolated static func containsDiscussionQuote(_ quote: String, in source: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if !quote.isEmpty, source.contains(quote) { return true }
        let text = normalized(quote)
        return !text.isEmpty && normalized(source).contains(text)
    }

    func saveAnchoredDiscussionNote(
        _ note: ReadingNote, highlights: [Highlight], scope: DiscussionNoteScope? = nil
    ) async throws -> ReadingNote {
        try Task.checkCancellation()
        guard note.isDocumentSummary || !note.anchors.isEmpty,
            !note.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ReaderError.message("没有可保存的笔记正文或原文位置。")
        }
        let insertion = AnchoredNoteInsertion(note: note, highlights: highlights, scope: scope)
        if let existing = try insertion.existing(in: state.readingNotes) { return existing }
        guard await save(cancellable: true, insertingNote: insertion) else {
            try Task.checkCancellation()
            throw ReaderError.message("笔记和标画未能保存，请重试。")
        }
        guard let saved = try insertion.existing(in: state.readingNotes) else {
            throw ReaderError.message("未找到刚保存的笔记。")
        }
        return saved
    }
}
