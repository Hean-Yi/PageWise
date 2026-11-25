import Foundation
import PaperReaderKit

/// Track all supplied note versions, including background the model paraphrases without a link.
@MainActor private final class CloseReadingBackground {
    private(set) var versions = ChatSourceVersions()

    func retrieve(_ query: String, paperID: UUID, reader: ReaderModel) async throws -> [Evidence] {
        let hits = try await reader.readingNoteEvidence(query: query, excluding: paperID, limit: 5)
        try check(in: reader)
        return hits.filter { evidence in
            guard let note = reader.referencedReadingNote(for: evidence) else { return false }
            versions.include(note)
            return true
        }
    }

    func check(in reader: ReaderModel) throws {
        try reader.validateAssistantBackground(versions)
    }
}

extension ReaderModel {
    func closeReadingVersion(for scope: DiscussionNoteScope) -> String {
        scope.htmlReading?.readingNoteVersion(digest: scope.digest) ?? scope.digest + ":original-0"
    }

    func existingCloseReading(for paperID: UUID, focus: String = "") -> ChatTurn? {
        guard !pendingImportIDs.contains(paperID),
            let document = paperID == selectedPaperID ? paper : state.papers.first(where: { $0.id == paperID })
        else { return nil }
        let version =
            document.htmlReading?.readingNoteVersion(digest: document.digest) ?? document.digest + ":original-0"
        return state.chats.last {
            $0.paperID == paperID && $0.closeReadingVersion == version && (focus.isEmpty || $0.question == focus)
                && $0.backgroundSources?.isCurrent(in: state, excluding: pendingImportIDs) != false
        }
    }

    func showCloseReading(_ paperID: UUID, focus: String = "", regenerate: Bool = false) async {
        do {
            let existing = existingCloseReading(for: paperID, focus: focus)
            let turn = try await runCloseReading(paperID, focus: focus, regenerate: regenerate)
            if existing != nil {
                let ids = [turn.readingNoteID].compactMap { $0 } + (turn.closeReadingNoteIDs ?? [])
                let notes = currentReadingNotes
                if let note = ids.lazy.compactMap({ id in notes.first { $0.id == id } }).first {
                    openReadingNote(note)
                } else {
                    message = "这次精读的笔记已删除。"
                }
            }
        } catch is CancellationError {
        } catch { message = error.localizedDescription }
    }

    func runCloseReading(_ paperID: UUID, focus: String = "", regenerate: Bool = false) async throws -> ChatTurn {
        let existing = existingCloseReading(for: paperID, focus: focus)
        if let existing, !regenerate { return existing }
        let focus = focus.isEmpty && regenerate && existing?.question != "AI 精读" ? (existing?.question ?? focus) : focus
        guard closeReadingTask == nil, !busyAI else { throw ReaderError.message("助读正在处理请求，请稍后再试。") }
        let scope = try discussionNoteScope(for: paperID)
        guard let document = paperID == selectedPaperID ? paper : state.papers.first(where: { $0.id == paperID })
        else { throw ReaderError.message("这篇论文已不在书库中。") }
        busyAI = true
        closeReadingPaperID = paperID
        closeReadingProgress = "准备本地原文…"
        let task = Task {
            let config = modelSettings
            let key = try await modelKey(for: config)
            let background = CloseReadingBackground()
            let analysis = try await CloseReadingEngine.run(
                paper: document, root: root, focus: focus,
                retrieveNotes: { query in try await background.retrieve(query, paperID: paperID, reader: self) },
                progress: { [weak self] text in
                    await self?.setCloseReadingProgress(text)
                },
                complete: { [client] system, user in
                    try await background.check(in: self)
                    let result = try await client.complete(
                        settings: config, key: key, system: system, user: user, jsonOutput: true, maxOutputTokens: 8192)
                    try await background.check(in: self)
                    return result
                })
            var verifiedScope = scope
            verifiedScope.backgroundSources = background.versions
            try validateDiscussionScope(verifiedScope)
            return try await saveCloseReading(analysis, scope: verifiedScope, focus: focus)
        }
        closeReadingTask = task
        defer {
            busyAI = false
            closeReadingTask = nil
            closeReadingPaperID = nil
            closeReadingProgress = ""
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func setCloseReadingProgress(_ text: String) { closeReadingProgress = text }

    private func saveCloseReading(_ analysis: CloseReadingAnalysis, scope: DiscussionNoteScope, focus: String)
        async throws -> ChatTurn
    {
        var insertions: [AnchoredNoteInsertion] = []
        var skipped = 0
        var verified: [String: LocalPassageCitation] = [:]
        func citation(_ evidence: Evidence, _ quote: String) async throws -> LocalPassageCitation {
            let key = [
                evidence.paperID?.uuidString, evidence.readingNoteID?.uuidString, evidence.blockID?.uuidString,
                evidence.sourcePage.map(String.init), quote,
            ]
            .compactMap { $0 }.joined(separator: "\u{1F}")
            if let existing = verified[key] { return existing }
            let result = try await makeLocalPassageCitation(evidence: evidence, quote: quote)
            verified[key] = result
            return result
        }
        for (index, annotation) in analysis.annotations.enumerated() {
            try Task.checkCancellation()
            closeReadingProgress = "核对批注 \(index + 1) / \(analysis.annotations.count)"
            do {
                let source = (evidence: annotation.source, quote: annotation.quote)
                var refs: [LocalPassageCitation] = []
                var links: [String] = []
                for ref in annotation.references
                where ref.evidence.paperID == scope.paperID || ref.evidence.readingNoteID != nil {
                    let item = try await citation(ref.evidence, ref.quote)
                    if !refs.contains(where: { $0.id == item.id }) {
                        refs.append(item)
                        links.append(item.markdown(label: ref.label))
                    }
                }
                let body = ([annotation.markdown] + links).joined(separator: "\n\n")
                let insertion = try await prepareDiscussionNote(
                    in: scope, sources: [source], markdown: body,
                    requestID: UUID(), citations: refs, dimension: annotation.dimension)
                insertions.append(insertion)
            } catch is CancellationError { throw CancellationError() } catch {
                try validateDiscussionScope(scope)
                skipped += 1
            }
        }
        var sections: [String] = []
        var outlineRefs: [LocalPassageCitation] = []
        var omittedSections = 0
        var previousHeading: String?
        for item in analysis.sections {
            try Task.checkCancellation()
            var references: [LocalPassageCitation] = []
            var links: [String] = []
            for ref in item.references where ref.evidence.paperID == scope.paperID || ref.evidence.readingNoteID != nil
            {
                if let source = try? await citation(ref.evidence, ref.quote) {
                    references.append(source)
                    links.append(source.markdown(label: ref.label))
                }
            }
            guard !links.isEmpty, links.count == item.references.count,
                references.contains(where: { $0.paperID == scope.paperID && $0.readingNoteID == nil }),
                Set((outlineRefs + references).map(\.id)).count <= LocalPassageCitation.notebookLimit
            else {
                omittedSections += 1
                continue
            }
            for source in references where !outlineRefs.contains(where: { $0.id == source.id }) {
                outlineRefs.append(source)
            }
            if item.heading != previousHeading { sections.append("## " + item.heading) }
            previousHeading = item.heading
            sections.append(item.markdown + "\n\n" + links.joined(separator: " · "))
        }
        try Task.checkCancellation()
        try validateDiscussionScope(scope)
        guard !insertions.isEmpty || !sections.isEmpty else {
            throw ReaderError.message("没有批注或论证引文通过原文定位校验。可以选中一段原文，单独询问助读。")
        }
        let coverage =
            analysis.coverage + (skipped == 0 ? "" : " · \(skipped) 条批注未通过原文核对")
            + (omittedSections == 0 ? "" : " · \(omittedSections) 节未能完整登记可定位的引文")
        var report = ChatTurn(
            paperID: scope.paperID, question: focus.isEmpty ? "AI 精读" : focus, selection: "",
            answer: coverage, evidence: [])
        report.backgroundSources = scope.backgroundSources
        report.closeReadingVersion = closeReadingVersion(for: scope)
        report.closeReadingNoteIDs = insertions.map(\.note.id)
        if let version = outlineRefs.first(where: { $0.paperID == scope.paperID && $0.readingNoteID == nil })?
            .contentVersion
        {
            let body = sections.joined(separator: "\n\n")
            try await validateNoteCitations(outlineRefs, markdown: body, documentEnd: true)
            var note = ReadingNote(paperID: scope.paperID, contentVersion: version, anchors: [], markdown: body)
            note.backgroundSources = scope.backgroundSources
            note.placement = .documentEnd
            note.citations = outlineRefs
            report.readingNoteID = note.id
            insertions.append(AnchoredNoteInsertion(note: note, highlights: [], scope: scope))
        }
        guard await save(cancellable: true, closeReading: (insertions, report)),
            let saved = state.chats.first(where: { $0.id == report.id })
        else {
            try Task.checkCancellation()
            throw ReaderError.message("精读结果未能保存，请重试。")
        }
        return saved
    }
}
