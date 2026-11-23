import Foundation
import PaperReaderKit

struct AgentToolOutcome {
    var content: String
    var cards: [AgentCard]
    var truncated: Bool
    var message: String?
    var clarification: AgentClarification?
    var presentation: [AgentPresentedResult]?
}

struct AgentNoteRequest: Sendable {
    let id: UUID
    let instruction: String
    let openedPaper: UUID?
    let target: UUID?
    let scope: DiscussionNoteScope?
}

enum AgentSourceTarget: Hashable {
    case candidate(String)
    case readingNote(UUID)
    case block(UUID, UUID)
    case paper(UUID, Int?)
    case card(UUID)

    init(_ card: AgentCard) {
        if let note = card.readingNoteID {
            self = .readingNote(note)
        } else if let candidate = card.candidateID {
            self = .candidate(candidate)
        } else if let paper = card.paperID, let block = card.blockID {
            self = .block(paper, block)
        } else if let paper = card.paperID {
            self = .paper(paper, card.sourcePage)
        } else {
            self = .card(card.id)
        }
    }
}

extension LibraryAgent {
    func execute(_ call: AgentToolCall, epoch: UUID, noteRequest: AgentNoteRequest? = nil, onSubject: (String) -> Void)
        async throws -> AgentToolOutcome
    {
        let arguments = try AgentToolArguments.parse(
            name: call.function.name, json: call.function.arguments, limits: limits)
        try check(epoch)
        switch arguments {
        case .closeReadPaper(let raw):
            let paper = try registeredPaper(raw, page: nil)
            guard let request = noteRequest, CloseReadingIntent.isRequested(request.instruction),
                request.openedPaper == reader.selectedPaperID, request.target == nil || request.target == paper.id
            else { throw ReaderError.message("需要读者明确要求精读这篇本地论文。") }
            onSubject(paper.title)
            let report = try await reader.runCloseReading(paper.id, focus: request.instruction)
            let ids = [report.readingNoteID].compactMap { $0 } + (report.closeReadingNoteIDs ?? [])
            let cards = ids.compactMap { id -> AgentCard? in
                guard let note = reader.state.readingNotes.first(where: { $0.id == id && $0.deletedAt == nil }) else {
                    return nil
                }
                var item = AgentCard(kind: .navigation, title: note.dimension?.title ?? "全文论证骨架")
                item.paperID = paper.id
                item.readingNoteID = id
                item.sourcePage = note.anchors.first?.pdfPageIndex.map { $0 + 1 }
                return item
            }
            guard !cards.isEmpty else { throw ReaderError.message("此版论文的精读笔记已删除。") }
            return AgentToolOutcome(
                content: #"{"ok":true}"#, cards: cards, truncated: false, message: report.answer,
                presentation: cards.map { .init(id: $0.id, purpose: .readingNote) })
        case .createReadingNote(let markdown, let quotations, let references, let dimension):
            guard let request = noteRequest, request.openedPaper == reader.selectedPaperID else {
                throw ReaderError.message("需要读者在本轮明确要求为这篇论文记笔记。")
            }
            guard !CloseReadingIntent.isRequested(request.instruction) else {
                throw ReaderError.message("读者要求精读全文。请使用 close_read_paper。")
            }
            let sources = try quotations.map { part -> (evidence: Evidence, quote: String) in
                guard let source = card(part.resultID), source.kind == .evidence, source.readingNoteID == nil,
                    let evidence = evidence(for: source)
                else {
                    throw ReaderError.message("请先读取本地论文，再引用已登记的原文。")
                }
                return (evidence, part.quote)
            }
            guard let evidence = sources.first?.evidence, let paperID = evidence.paperID,
                sources.allSatisfy({ $0.evidence.paperID == paperID }),
                request.target == nil || request.target == paperID
            else { throw ReaderError.message("一条阅读笔记只能标在本轮目标论文上。") }
            let scope = try request.scope ?? reader.discussionNoteScope(for: paperID)
            onSubject(evidence.title)
            let links = try references.map { reference -> NoteLinkRequest in
                guard let registered = card(reference.passage.resultID), registered.kind == .evidence,
                    registered.readingNoteID != nil,
                    let evidence = self.evidence(for: registered)
                else { throw ReaderError.message("请先用 search_reading_notes 检索书库笔记，再引用笔记中的文字。") }
                return NoteLinkRequest(evidence: evidence, quote: reference.passage.quote, label: reference.label)
            }
            let linked = try await reader.attachNoteLinks(to: markdown, references: links)
            let note = try await reader.saveDiscussionNote(
                in: scope, sources: sources, markdown: linked.markdown,
                requestID: request.id, instruction: request.instruction, citations: linked.citations,
                dimension: dimension)
            var item = AgentCard(kind: .navigation, title: evidence.title)
            item.readingNoteID = note.id
            item.paperID = paperID
            item.excerpt = String(note.anchors.first?.text.prefix(300) ?? "")
            item.sourcePage = note.anchors.first?.pdfPageIndex.map { $0 + 1 }
            // The mutation has committed. Its receipt must fit even when the tool's excerpt budget is very small.
            return AgentToolOutcome(content: #"{"ok":true,"saved":true}"#, cards: [item], truncated: false)
        case .presentResults(let purpose, let items):
            var seen = Set<AgentSourceTarget>()
            var selected: [AgentPresentedResult] = []
            var cards: [AgentCard] = []
            for item in items {
                guard let card = card(item.id),
                    card.noteModifiedAt == nil || evidence(for: card) != nil
                else {
                    throw ReaderError.message("展示项中有未登记的结果，请使用工具返回的 result_id 重新选择。")
                }
                if seen.insert(AgentSourceTarget(card)).inserted {
                    selected.append(.init(id: card.id, purpose: purpose, reason: item.reason))
                    cards.append(card)
                }
            }
            var outcome = try result([], message: "已选出 \(selected.count) 项。")
            outcome.cards = cards
            outcome.presentation = selected
            return outcome
        case .askUser(let clarification):
            onSubject(clarification.question)
            let content = #"{"ok":true,"awaiting_user":true}"#
            guard content.utf8.count <= limits.maxToolResultBytes else { throw ReaderError.message("工具结果超出长度上限。") }
            return AgentToolOutcome(
                content: content, cards: [], truncated: false,
                clarification: clarification)
        case .searchLibrary(let query):
            onSubject(query)
            let limit = min(max(0, limits.maxResults), 20)
            let hits = LibraryAgentSearch.search(query, papers: reader.state.papers, limit: limit + 1)
            let pairs = hits.prefix(limit).map { hit -> (ToolRecord, AgentCard) in
                var card = AgentCard(kind: hit.blockID == nil ? .localPaper : .evidence, title: hit.title)
                card.paperID = hit.paperID
                card.blockID = hit.blockID
                card.sourcePage = hit.sourcePage
                card.excerpt = hit.excerpt
                card.subtitle = hit.sourcePage.map { "原文第 \($0) 页" } ?? "本地论文"
                return (
                    ToolRecord(card: card, pageCount: reader.state.papers.first { $0.id == hit.paperID }?.pageCount),
                    card
                )
            }
            let outcome = try result(pairs, truncated: hits.count > limit)
            paperRegistry.formUnion(outcome.cards.compactMap(\.paperID))
            return outcome
        case .searchReadingNotes(let query):
            onSubject(query)
            let limit = min(max(0, limits.maxResults), 20)
            let hits = try await reader.readingNoteEvidence(query: query, limit: limit + 1)
            try check(epoch)
            let pairs = hits.prefix(limit).compactMap { hit -> (ToolRecord, AgentCard)? in
                guard let id = hit.readingNoteID, let paperID = hit.paperID,
                    let note = reader.referencedReadingNote(id: id, paperID: paperID),
                    ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(hit.text)
                else { return nil }
                var card = AgentCard(kind: .evidence, title: hit.title)
                card.paperID = hit.paperID
                card.readingNoteID = id
                card.noteModifiedAt = note.modifiedAt
                card.sourcePage = hit.sourcePage.map { $0 + 1 }
                card.subtitle = "阅读笔记"
                card.excerpt = hit.text
                return (ToolRecord(card: card), card)
            }
            let outcome = try result(pairs, truncated: hits.count > limit)
            paperRegistry.formUnion(outcome.cards.compactMap(\.paperID))
            return outcome
        case .readPaper(let id, let page):
            let paper = try registeredPaper(id, page: page)
            onSubject("\(paper.title) · 第 \(page) 页")
            let blocks = paper.blocks.filter { $0.sourcePage == page - 1 }
            var passages: [(id: UUID?, text: String)] = blocks.map { ($0.id, $0.text) }
            if passages.isEmpty {
                let url = reader.root.appendingPathComponent(paper.originalPath)
                let sentences = await Task.detached(priority: .userInitiated) {
                    (try? PDFSentenceExtractor.extractPage(url: url, pageIndex: page - 1))?.sentences ?? []
                }.value
                try check(epoch)
                var prior: String?
                for sentence in sentences {
                    if prior == sentence.readingParagraphID, let last = passages.indices.last {
                        passages[last].text += " " + sentence.text
                    } else {
                        passages.append((nil, sentence.text))
                    }
                    prior = sentence.readingParagraphID
                }
            }
            let pairs = passages.prefix(min(max(0, limits.maxResults), 20)).map { block -> (ToolRecord, AgentCard) in
                var card = AgentCard(kind: .evidence, title: paper.title)
                card.paperID = paper.id
                card.blockID = block.id
                card.sourcePage = page
                card.subtitle = "原文第 \(page) 页"
                card.excerpt = String(block.text.prefix(2_000))
                return (ToolRecord(card: card, pageCount: paper.pageCount), card)
            }
            return try result(
                pairs, truncated: passages.count > pairs.count || passages.contains { $0.text.count > 2_000 },
                message: passages.isEmpty ? "这一页暂无已索引的正文。" : nil)
        case .searchOnline(let query, let requestedCount):
            onSubject(query)
            let limit = min(requestedCount ?? limits.maxResults, 20)
            guard limit > 0 else { return try result([], truncated: true) }
            let found = try await discovery.search(query, limit: limit + 1)
            try check(epoch)
            var seen: Set<String> = []
            let verified = found.prefix(40).compactMap(ArxivClient.verified).filter { seen.insert($0.id).inserted }
            let pairs = verified.prefix(limit).map { candidate -> (ToolRecord, AgentCard) in
                let id = candidateIDs[candidate.id] ?? UUID().uuidString
                var card = candidateCard(candidate, id: id)
                if let paperID = importedPapers[id], reader.state.papers.contains(where: { $0.id == paperID }) {
                    card.importState = .imported
                    card.paperID = paperID
                }
                return (ToolRecord(card: card, authors: candidate.authors, year: candidate.year), card)
            }
            let outcome = try result(pairs, truncated: found.count > 40 || verified.count > pairs.count)
            for (card, candidate) in zip(outcome.cards, verified) {
                if let id = card.candidateID {
                    candidates[id] = candidate
                    candidateIDs[candidate.id] = id
                }
            }
            return outcome
        case .prepareImport(let id):
            guard let candidate = candidates[id] else { throw ReaderError.message("候选ID不属于本次会话，请先在线检索。") }
            onSubject(candidate.title)
            var card = candidateCard(candidate, id: id)
            if let paperID = importedPapers[id], reader.state.papers.contains(where: { $0.id == paperID }) {
                card.importState = .imported
                card.paperID = paperID
            } else if card.importState == .unprepared {
                card.importState = .ready
            }
            let message: String
            switch card.importState {
            case .queued: message = "已排队，等待下载。"
            case .downloading: message = "正在下载；已有导入任务。"
            case .importing: message = "正在解析并保存；已有导入任务。"
            case .imported: message = "候选已在书库，可打开已有论文。"
            case .failed: message = "上次导入失败，等待用户点击重试。"
            case .cancelled: message = "上次导入已停止，等待用户点击重试。"
            case .unprepared, .ready: message = "等待用户点击确认；尚未下载。"
            }
            return try result(
                [(ToolRecord(card: card, authors: candidate.authors, year: candidate.year), card)],
                message: message)
        case .openPaper(let id, let page):
            let paper = try registeredPaper(id, page: page)
            onSubject(page.map { "\(paper.title) · 第 \($0) 页" } ?? paper.title)
            var card = AgentCard(kind: .navigation, title: paper.title)
            card.paperID = paper.id
            card.sourcePage = page
            card.subtitle = page.map { "前往原文第 \($0) 页" } ?? "打开论文"
            return try result([(ToolRecord(card: card, pageCount: paper.pageCount), card)])
        }
    }

    private func registeredPaper(_ id: String, page: Int?) throws -> Paper {
        guard let uuid = UUID(uuidString: id), paperRegistry.contains(uuid),
            let paper = reader.state.papers.first(where: { $0.id == uuid })
        else {
            throw ReaderError.message("论文ID不属于本次会话已检索的资料。")
        }
        if let page, page < 1 || page > paper.pageCount { throw ReaderError.message("原文页码超出这篇论文的范围。") }
        return paper
    }

    private func candidateCard(_ candidate: PaperCandidate, id: String) -> AgentCard {
        var card = AgentCard(kind: .onlineCandidate, title: candidate.title)
        card.authors = candidate.authors
        card.year = candidate.year
        card.subtitle = [candidate.authors, candidate.year, "arXiv"].filter { !$0.isEmpty }.joined(separator: " · ")
        card.candidateID = id
        card.sourceURL = URL(string: candidate.id)
        if candidates[id] != nil,
            let previous = turns.flatMap(\.cards).last(where: { $0.candidateID == id })
        {
            card.importState = previous.importState
            card.importError = previous.importError
            card.paperID = previous.paperID
        }
        return card
    }

    private func result(_ pairs: [(ToolRecord, AgentCard)], truncated: Bool = false, message: String? = nil) throws
        -> AgentToolOutcome
    {
        var pairs = pairs
        var truncated = truncated
        while true {
            let payload = ToolPayload(ok: true, results: pairs.map(\.0), truncated: truncated, message: message)
            let data = try JSONEncoder().encode(payload)
            if data.count <= limits.maxToolResultBytes {
                return AgentToolOutcome(
                    content: String(decoding: data, as: UTF8.self), cards: pairs.map(\.1), truncated: truncated,
                    message: message)
            }
            guard !pairs.isEmpty else { throw ReaderError.message("工具结果长度上限过小，无法提供结果。") }
            pairs.removeLast()
            truncated = true
        }
    }

    static func errorResult(_ message: String, canRefineQuery: Bool? = nil, maxBytes: Int) throws -> String {
        let payload = ToolPayload(
            ok: false, results: [], truncated: false, message: message, canRefineQuery: canRefineQuery)
        let data = try JSONEncoder().encode(payload)
        guard data.count <= maxBytes else { throw ReaderError.message("工具结果超过长度上限。") }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ToolPayload: Encodable {
    var ok: Bool
    var results: [ToolRecord]
    var truncated: Bool
    var message: String?
    var canRefineQuery: Bool?
    let dataOnly = true
    enum CodingKeys: String, CodingKey {
        case ok, results, truncated, message
        case dataOnly = "data_only"
        case canRefineQuery = "can_refine_query"
    }
}

private struct ToolRecord: Encodable {
    var resultID: UUID
    var paperID: String?
    var candidateID: String?
    var readingNoteID: UUID?
    var title: String
    var authors: String?
    var year: String?
    var sourcePage: Int?
    var pageCount: Int?
    var blockID: String?
    var text: String?
    var sourceURL: String?
    var importStatus: String?
    init(card: AgentCard, pageCount: Int? = nil, authors: String? = nil, year: String? = nil) {
        resultID = card.id
        self.authors = authors
        self.year = year
        paperID = card.paperID?.uuidString
        candidateID = card.candidateID
        readingNoteID = card.readingNoteID
        title = card.title
        sourcePage = card.sourcePage
        self.pageCount = pageCount
        blockID = card.blockID?.uuidString
        text = card.excerpt.isEmpty ? nil : card.excerpt
        sourceURL = card.sourceURL?.absoluteString
        importStatus = card.candidateID == nil ? nil : card.importState.rawValue
    }
    enum CodingKeys: String, CodingKey {
        case title, text, authors, year
        case resultID = "result_id"
        case paperID = "paper_id"
        case candidateID = "candidate_id"
        case readingNoteID = "reading_note_id"
        case sourcePage = "source_page"
        case pageCount = "page_count"
        case blockID = "block_id"
        case sourceURL = "source_url"
        case importStatus = "import_status"
    }
}
