import Foundation
import PaperReaderKit

struct AgentToolOutcome: Sendable {
    var content: String
    var cards: [AgentCard]
    var truncated: Bool
    var message: String?
    var clarification: AgentClarification?
    var presentation: [AgentPresentedResult]?
    var versionCards: [AgentCard] = []
    var changedResearchOverview = false
}

struct AgentRecommendationSeed: Sendable {
    let title: String
    let sourceID: String?
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
        if card.removal != nil || card.localImportDestination != nil {
            self = .card(card.id)
        } else if let note = card.readingNoteID {
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
    func execute(
        _ call: AgentToolCall, epoch: UUID, noteRequest: AgentNoteRequest? = nil,
        recommendationSeed: AgentRecommendationSeed? = nil, organization: Set<String> = [],
        onSubject: @escaping @MainActor @Sendable (String) -> Void
    )
        async throws -> AgentToolOutcome
    {
        let arguments = try AgentToolArguments.parse(
            name: call.function.name, json: call.function.arguments, limits: limits)
        try check(epoch)
        let useMemory = activeTurn.map { ReaderPreference.permitsRecall($0.question) } ?? true
        if !useMemory,
            ["research_overview", "search_reading_notes", "propose_research_question"].contains(call.function.name)
        {
            throw ReaderError.message("本轮已跳过个人记忆。")
        }
        switch arguments {
        case .rememberPreference(let quote):
            guard let turn = activeTurn,
                let declared = ReaderPreference.declaredClauses(in: turn.question).first(where: {
                    ReaderPreference.sameStatement($0, quote)
                }),
                limits.availableToolNames?.contains(call.function.name) != false
            else {
                throw ReaderError.message("请仅引用读者本轮明确表达的长期偏好。")
            }
            if let change = try reader.preferenceChange(
                for: declared, turnID: turn.id,
                paperID: turn.referencedCardID.flatMap { card($0)?.paperID } ?? reader.selectedPaperID,
                paperTurn: false)
            {
                guard await reader.save(cancellable: true, preferenceChange: change) else {
                    throw ReaderError.message("偏好发生变化，请重新查看。")
                }
                try check(epoch)
                var versions = ChatSourceVersions()
                for saved in change.insertions { versions.include(saved) }
                remember(versions)
            }
            return AgentToolOutcome(content: #"{"ok":true}"#, cards: [], truncated: false, message: "回答偏好已保存。")
        case .researchOverview(let query, let scope):
            return try await researchOverview(query: query, scope: scope, epoch: epoch, onSubject: onSubject)
        case .proposeResearchQuestion(let question, let noteResult, let quote):
            guard let turn = activeTurn, permitsResearchProposal(in: turn),
                limits.availableToolNames?.contains(call.function.name) != false
            else { throw ReaderError.message("本轮没有新的可保存研究问题。请根据已取回的资料回答。") }
            var authorizedSource = ChatSourceVersions()
            func needsVerbatimSource() -> Bool {
                let sawOtherSource = turn.cards.contains { $0.id != noteResult }
                return turns.count > 1 || sawOtherSource
                    || (recalledSources.map { !$0.isEmpty && $0 != authorizedSource } ?? false)
            }
            let proposal: ResearchQuestionProposal
            if let noteResult {
                guard let card = turn.cards.first(where: { $0.id == noteResult && $0.kind == .evidence }),
                    let noteID = card.readingNoteID, let paperID = card.paperID,
                    let note = reader.referencedReadingNote(id: noteID, paperID: paperID, includeArchived: false),
                    note.modifiedAt == card.noteModifiedAt
                else { throw ReaderError.message("请先在本轮检索当前的个人阅读笔记。") }
                authorizedSource.include(note)
                proposal = try ResearchQuestionProposal(
                    question: question, quote: quote, registeredExcerpt: card.excerpt, note: note,
                    sourceOnly: needsVerbatimSource())
            } else {
                proposal = try ResearchQuestionProposal(
                    question: question, readerTurnID: turn.id, readerMessage: turn.question, quote: quote,
                    sourceOnly: needsVerbatimSource())
            }
            guard proposal.isEligible(in: reader.state, excluding: reader.pendingImportIDs) else {
                throw ReaderError.message("线索与既有记忆重复、已撤回，或来自派生笔记。")
            }
            guard await reader.save(cancellable: true, proposingQuestion: proposal) else {
                try check(epoch)
                throw ReaderError.message("来源已变化或保存失败，此次未记录新问题。")
            }
            try check(epoch)
            var versions = ChatSourceVersions()
            versions.include(proposal.item)
            remember(versions)
            onSubject("待核实的研究问题")
            var record = AgentCard(kind: .navigation, title: "待查研究问题")
            record.researchMemoryID = proposal.item.id
            return AgentToolOutcome(
                content: #"{"ok":true,"status":"ai_unverified"}"#, cards: [record], truncated: false,
                message: "待查研究问题已保存。")
        case .proposeMemory(let statement, let noteResult, let quote):
            guard let turn = activeTurn, ReaderPreference.permitsExtraction(turn.question),
                !ResearchQuestionProposal.isRecallRequest(turn.question),
                limits.availableToolNames?.contains(call.function.name) != false
            else { throw ReaderError.message("本轮不记录新的长期记忆。") }
            let proposal: MemoryStatementProposal
            if let noteResult {
                guard let card = turn.cards.first(where: { $0.id == noteResult && $0.kind == .evidence }),
                    let noteID = card.readingNoteID, let paperID = card.paperID,
                    let note = reader.referencedReadingNote(id: noteID, paperID: paperID, includeArchived: false),
                    note.modifiedAt == card.noteModifiedAt
                else { throw ReaderError.message("请先在本轮检索当前的个人阅读笔记。") }
                proposal = try MemoryStatementProposal(
                    statement: statement, quote: quote, registeredExcerpt: card.excerpt, note: note)
            } else {
                proposal = try MemoryStatementProposal(
                    statement: statement, readerTurnID: turn.id, readerMessage: turn.question, quote: quote)
            }
            guard
                MemoryStatementProposal.isEligible(
                    proposal.item, in: reader.state, excluding: reader.pendingImportIDs)
            else {
                throw ReaderError.message("线索与既有记忆重复、已撤回，或来自派生笔记。")
            }
            guard await reader.save(cancellable: true, proposingMemory: proposal) else {
                try check(epoch)
                throw ReaderError.message("来源已变化或保存失败，此次未记录新记忆。")
            }
            try check(epoch)
            var versions = ChatSourceVersions()
            versions.include(proposal.item)
            remember(versions)
            onSubject("待核实的研究记忆")
            return AgentToolOutcome(
                content: "{\"ok\":true,\"status\":\"ai_unverified\",\"memory_id\":\"\(proposal.item.id.uuidString)\"}",
                cards: [], truncated: false, message: nil)
        case .reviseMemory(let memoryID, let statement):
            guard let turn = activeTurn, ReaderPreference.permitsRecall(turn.question),
                Self.hasExplicitRevisionIntent(turn.question),
                limits.availableToolNames?.contains(call.function.name) != false,
                let current = reader.state.memories.first(where: { $0.id == memoryID }),
                !current.deleted, !current.userEdited
            else { throw ReaderError.message("本轮没有明确要求更正已有记忆。") }
            var probe = current
            guard probe.correct(to: statement) else {
                throw ReaderError.message("新的记忆措辞没有变化。")
            }
            let mutation = MemoryRecordMutation(
                operation: .revise(id: memoryID, statement: statement), auditTrigger: turn.question)
            guard await reader.save(cancellable: true, memoryMutation: mutation) else {
                try check(epoch)
                throw ReaderError.message("来源已变化或保存失败，此次未修改记忆。")
            }
            try check(epoch)
            onSubject("研究记忆已静默修订")
            return AgentToolOutcome(
                content: "{\"ok\":true,\"memory_id\":\"\(memoryID.uuidString)\"}", cards: [], truncated: false,
                message: nil)
        case .forgetMemory(let memoryID):
            guard let turn = activeTurn, ReaderPreference.permitsRecall(turn.question),
                turn.question.range(
                    of: #"(?i)忘掉|忘记|删除|移除|撤回|forget|remove|delete"#, options: .regularExpression) != nil,
                limits.availableToolNames?.contains(call.function.name) != false,
                let target = reader.state.memories.first(where: { $0.id == memoryID }),
                !target.deleted, !target.userEdited
            else { throw ReaderError.message("本轮没有明确要求删除这条记忆。") }
            let ignored: Set<String> = ["的", "了", "在", "和", "与", "及", "这", "那", "个", "记录", "记忆", "旧", "新"]
            let questionTerms = Retriever.tokens(turn.question).subtracting(ignored)
            let scored = reader.state.memories.compactMap { item -> (MemoryItem, Int)? in
                guard !item.deleted, !item.isResponsePreference else { return nil }
                let overlap = Retriever.tokens(item.text).subtracting(ignored).intersection(questionTerms).count
                return overlap > 0 ? (item, overlap) : nil
            }.sorted { $0.1 > $1.1 }
            let topOverlap = scored.first?.1 ?? 0
            let uniqueTop = scored.filter { $0.1 == topOverlap }
            guard
                turn.question.localizedCaseInsensitiveContains(target.text)
                    || (topOverlap > 0 && uniqueTop.count == 1 && uniqueTop.first?.0.id == target.id)
            else { throw ReaderError.message("记忆删除目标不唯一或与请求不匹配。") }
            let mutation = MemoryRecordMutation(operation: .forget(id: target.id), auditTrigger: turn.question)
            guard await reader.save(cancellable: true, memoryMutation: mutation) else {
                try check(epoch)
                throw ReaderError.message("来源已变化或保存失败，此次未删除记忆。")
            }
            try check(epoch)
            onSubject("研究记忆已静默删除")
            return AgentToolOutcome(
                content: "{\"ok\":true,\"memory_id\":\"\(memoryID.uuidString)\"}", cards: [], truncated: false,
                message: nil)
        case .library(let operation):
            guard call.function.name == "list_library" || organization.contains(call.function.name),
                limits.availableToolNames?.contains(call.function.name) != false
            else { throw ReaderError.message("本次提问未授权该书库操作。") }
            var outcome = try await organize(operation, onSubject: onSubject)
            switch operation {
            case .createShelf, .renameShelf, .movePapers:
                if let previous = lastResearchBrief {
                    if !reader.isResearchBriefCurrent(previous) {
                        lastResearchBrief = nil
                        outcome.changedResearchOverview = true
                        var receipt =
                            (try? JSONSerialization.jsonObject(with: Data(outcome.content.utf8))) as? [String: Any]
                            ?? [:]
                        receipt["research_overview_changed"] = true
                        if let bytes = try? JSONSerialization.data(withJSONObject: receipt),
                            bytes.count <= limits.maxToolResultBytes
                        {
                            outcome.content = String(decoding: bytes, as: UTF8.self)
                        }
                    }
                }
            default: break
            }
            return outcome
        case .closeReadPaper(let raw):
            let paper = try registeredPaper(raw, page: nil)
            guard let request = noteRequest, CloseReadingIntent.isRequested(request.instruction),
                request.openedPaper == reader.selectedPaperID, request.target == nil || request.target == paper.id
            else { throw ReaderError.message("需要读者明确要求精读这篇本地论文。") }
            onSubject(paper.displayTitle)
            let report = try await reader.runCloseReading(paper.id, focus: request.instruction)
            let ids = [report.readingNoteID].compactMap { $0 } + (report.closeReadingNoteIDs ?? [])
            let cards = ids.compactMap { id -> AgentCard? in
                guard let note = reader.referencedReadingNote(id: id, paperID: paper.id, includeArchived: false) else {
                    return nil
                }
                let title = note.isDocumentSummary ? "文末总结" : note.dimension?.title ?? "阅读笔记"
                var item = AgentCard(kind: .navigation, title: title)
                item.paperID = paper.id
                item.readingNoteID = id
                item.sourcePage = note.anchors.first?.readingPageIndex.map { $0 + 1 }
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
            var scope = try request.scope ?? reader.discussionNoteScope(for: paperID)
            scope.backgroundSources = recalledSources ?? ChatSourceVersions()
            onSubject(evidence.displayTitle)
            let links = try references.map { reference -> NoteLinkRequest in
                guard useMemory, let registered = card(reference.passage.resultID), registered.kind == .evidence,
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
            item.sourcePage = note.anchors.first?.readingPageIndex.map { $0 + 1 }
            // The mutation has committed. Its receipt must fit even when the tool's excerpt budget is very small.
            return AgentToolOutcome(content: #"{"ok":true,"saved":true}"#, cards: [item], truncated: false)
        case .presentResults(let purpose, let items):
            var seen = Set<AgentSourceTarget>()
            var selected: [AgentPresentedResult] = []
            var cards: [AgentCard] = []
            for item in items {
                guard let card = card(item.id), card.removal == nil, card.localImportDestination == nil,
                    useMemory || (card.readingNoteID == nil && card.researchMemoryID == nil),
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
            let papers = reader.state.papers.filter { !reader.pendingImportIDs.contains($0.id) }
            let matches = try await reader.paperSearchIndex.search(query, papers: papers, limit: limit + 1)
            try check(epoch)
            let pageCounts = Dictionary(
                reader.state.papers.lazy.filter { !self.reader.pendingImportIDs.contains($0.id) }.map {
                    ($0.id, $0.pageCount)
                },
                uniquingKeysWith: { first, _ in first })
            let hits = matches.filter { pageCounts[$0.paperID] != nil }
            let pairs = hits.prefix(limit).map { hit -> (ToolRecord, AgentCard) in
                var card = AgentCard(
                    kind: hit.blockID == nil && hit.sourcePage == nil ? .localPaper : .evidence, title: hit.title)
                card.searchQuery = query
                card.paperID = hit.paperID
                card.blockID = hit.blockID
                card.sourcePage = hit.sourcePage
                card.excerpt = hit.excerpt
                card.subtitle = hit.sourcePage.map { "原文第 \($0) 页" } ?? "本地论文"
                return (
                    ToolRecord(card: card, pageCount: pageCounts[hit.paperID]),
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
                guard let note = reader.referencedReadingNote(for: hit) else { return nil }
                var card = AgentCard(kind: .evidence, title: hit.title)
                card.searchQuery = query
                card.paperID = hit.paperID
                card.readingNoteID = note.id
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
            onSubject("\(paper.displayTitle) · 第 \(page) 页")
            let blocks = paper.blocks.filter { $0.sourcePage == page - 1 }
            var passages: [(id: UUID?, text: String)] = blocks.map { ($0.id, $0.text) }
            if passages.isEmpty {
                let url = reader.root.appendingPathComponent(paper.originalPath)
                let sentences = await Task.detached(priority: .userInitiated) {
                    (try? PDFSentenceExtractor.extractPage(url: url, pageIndex: page - 1))?.sentences ?? []
                }.value
                try check(epoch)
                _ = try registeredPaper(id, page: page)
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
        case .searchOnline(let query, let requestedCount, let scope):
            onSubject(query)
            let limit = min(requestedCount ?? limits.maxResults, 20)
            guard limit > 0 else { return try result([], truncated: true) }
            let report = try await discovery.discover(query, scope: scope, limit: limit + 1) { [weak self] partial in
                guard !partial.candidates.isEmpty else { return }
                await MainActor.run {
                    guard self?.epoch == epoch, !Task.isCancelled else { return }
                    onSubject("\(query) · 已找到 \(min(limit, partial.candidates.count)) 篇")
                }
            }
            try check(epoch)
            onSubject(query)
            return try onlineResults(report.candidates, query: query, limit: limit, notice: report.notice)
        case .recommendRelated(let requestedCount):
            guard let seed = recommendationSeed else { throw ReaderError.message("请打开一篇论文，或从推荐卡片追问。") }
            let title = PaperTitle.display(seed.title)
            onSubject(title)
            let limit = min(requestedCount ?? limits.maxResults, 20)
            guard limit > 0 else { return try result([], truncated: true) }
            let found = try await discovery.related(title: seed.title, sourceID: seed.sourceID, limit: limit + 1)
            try check(epoch)
            return try onlineResults(
                found, limit: limit,
                notice: found.isEmpty ? "Semantic Scholar 未返回《\(String(title.prefix(300)))》的推荐。" : nil)
        case .prepareImport(let id):
            guard let candidate = candidates[id] else { throw ReaderError.message("候选ID不属于本次会话，请先在线检索。") }
            guard candidate.canAttemptDownload else { throw ReaderError.message("请在结果卡查看来源页，取得 PDF 后在同一卡片选择文件导入。") }
            onSubject(candidate.displayTitle)
            var card = candidateCard(candidate, id: id)
            if let reference = turns.last?.referencedCardID.flatMap({ self.card($0) }), reference.candidateID == id {
                card.searchQuery = reference.searchQuery
            }
            if card.importState == .unprepared { card.importState = .ready }
            let message: String
            switch card.importState {
            case .queued: message = "已排队，等待下载。"
            case .downloading: message = "正在获取全文。"
            case .importing: message = "正在解析并保存；已有导入任务。"
            case .imported: message = "候选已在书库，可打开已有论文。"
            case .failed: message = "上次导入失败，可在卡片重新下载或选择已取得的 PDF 入库。"
            case .cancelled: message = "上次导入已停止，等待用户点击重试。"
            case .unprepared, .ready: message = "读者可在卡片点击「下载并导入」。"
            }
            return try result(
                [(ToolRecord(card: card, authors: candidate.authors, year: candidate.year), card)],
                message: message)
        case .openPaper(let id, let page):
            let paper = try registeredPaper(id, page: page)
            onSubject(page.map { "\(paper.displayTitle) · 第 \($0) 页" } ?? paper.displayTitle)
            var card = AgentCard(kind: .navigation, title: paper.title)
            card.paperID = paper.id
            card.sourcePage = page
            card.subtitle = page.map { "前往原文第 \($0) 页" } ?? "打开论文"
            return try result([(ToolRecord(card: card, pageCount: paper.pageCount), card)])
        }
    }

    /// A new research statement belongs in `propose_memory`; an existing memory may only be
    /// overwritten when the reader explicitly asks to correct or replace it.
    static func hasExplicitRevisionIntent(_ question: String) -> Bool {
        question.range(
            of:
                #"(?i)更正|改正|纠正|修正|修改|改成|改为|更新|调整|记错|写错|说错|不是|而是|不再|correct|change|update|instead|no longer|replace"#,
            options: .regularExpression) != nil
    }

    func registeredPaper(_ id: String, page: Int?) throws -> Paper {
        guard let uuid = UUID(uuidString: id), paperRegistry.contains(uuid),
            let paper = reader.state.papers.first(where: { $0.id == uuid })
        else {
            throw ReaderError.message("论文ID不属于本次会话已检索的资料。")
        }
        if let page, page < 1 || page > paper.pageCount { throw ReaderError.message("原文页码超出这篇论文的范围。") }
        return paper
    }

    private func onlineResults(_ found: [PaperCandidate], query: String? = nil, limit: Int, notice: String?) throws
        -> AgentToolOutcome
    {
        var seen: Set<String> = []
        let verified = found.prefix(40).compactMap(\.verified).filter { seen.insert($0.id).inserted }
        var records: [UUID: PaperCandidate] = [:]
        var variants: [UUID: [AgentCard]] = [:]
        var ids: [String: String] = [:]
        func registeredCard(_ candidate: PaperCandidate) -> AgentCard {
            let id = candidateIDs[candidate.id] ?? ids[candidate.id] ?? UUID().uuidString
            ids[candidate.id] = id
            let best: PaperCandidate
            if !candidate.canDownload, let known = candidates[id],
                known.canDownload || (!candidate.canAttemptDownload && known.canAttemptDownload)
            {
                best = known
            } else {
                best = candidate
            }
            var card = candidateCard(best, id: id)
            card.searchQuery = query
            records[card.id] = best
            return card
        }
        let pairs = verified.prefix(limit).map { candidate -> (ToolRecord, AgentCard) in
            var card = registeredCard(candidate)
            let versions = candidate.alternateVersions.compactMap(\.verified).map(registeredCard)
            card.alternateVersionIDs = versions.map(\.id)
            variants[card.id] = versions
            var record = ToolRecord(card: card)
            if !versions.isEmpty {
                record.versions = versions.map { version in
                    var item: [String: String] = [:]
                    item["source"] = version.sourceName
                    item["year"] = version.year
                    item["candidate_id"] = version.canAttemptDownload ? version.candidateID : nil
                    item["import_status"] = version.toolImportStatus
                    return item
                }
            }
            return (record, card)
        }
        var outcome = try result(pairs, truncated: found.count > 40 || verified.count > pairs.count, message: notice)
        outcome.versionCards = outcome.cards.flatMap { variants[$0.id] ?? [] }
        for card in outcome.cards + outcome.versionCards {
            if let candidate = records[card.id], let id = card.candidateID {
                candidates[id] = candidate
                candidateIDs[candidate.id] = id
                if let paperID = card.paperID { paperRegistry.insert(paperID) }
            }
        }
        return outcome
    }

    private func candidateCard(_ candidate: PaperCandidate, id: String) -> AgentCard {
        var card = AgentCard(kind: .onlineCandidate, title: candidate.title)
        card.authors = candidate.authors
        card.year = candidate.year
        card.sourceName = candidate.source.label
        card.hasDownload = candidate.canDownload
        card.canLookUpFullText = !card.hasDownload && candidate.canAttemptDownload
        card.subtitle = [candidate.authors, candidate.year, candidate.source.label].filter { !$0.isEmpty }.joined(
            separator: " · ")
        card.candidateID = id
        card.sourceURL = candidate.landingURL
        if candidates[id] != nil,
            let previous = turns.reversed().lazy.compactMap({ $0.cards.last { $0.candidateID == id } }).first
        {
            card.searchQuery = previous.searchQuery
            if previous.importState != .imported {
                card.importState = previous.importState
                card.importError = previous.importError
            }
        }
        return currentImportCard(card, candidate: candidate)
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

    static func errorResult(
        _ message: String, seedTitle: String? = nil, canRefineQuery: Bool? = nil, maxBytes: Int
    ) throws -> String {
        let payload = ToolPayload(
            ok: false, results: [], truncated: false, message: message, canRefineQuery: canRefineQuery,
            seedTitle: seedTitle.map { String($0.prefix(300)) })
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
    var seedTitle: String?
    let dataOnly = true
    enum CodingKeys: String, CodingKey {
        case ok, results, truncated, message
        case dataOnly = "data_only"
        case canRefineQuery = "can_refine_query"
        case seedTitle = "seed_title"
    }
}

extension AgentCard {
    var toolImportStatus: String? {
        guard kind == .onlineCandidate else { return nil }
        if !hasDownload && [.unprepared, .ready].contains(importState) {
            return canLookUpFullText ? "lookup_open_pdf" : "select_local_pdf"
        }
        return importState.rawValue
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
    var source: String?
    var versions: [[String: String]]?
    init(card: AgentCard, pageCount: Int? = nil, authors: String? = nil, year: String? = nil) {
        resultID = card.id
        self.authors = authors ?? card.authors
        self.year = year ?? card.year
        source = card.sourceName
        paperID = card.paperID?.uuidString
        candidateID = card.canAttemptDownload ? card.candidateID : nil
        readingNoteID = card.readingNoteID
        title = card.title
        sourcePage = card.sourcePage
        self.pageCount = pageCount
        blockID = card.blockID?.uuidString
        text = card.excerpt.isEmpty ? nil : card.excerpt
        sourceURL = card.sourceURL?.absoluteString
        importStatus = card.toolImportStatus
    }
    enum CodingKeys: String, CodingKey {
        case title, text, authors, year, source, versions
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

extension LibraryAgent {
    private struct RecalledMemory: Encodable {
        enum CodingKeys: String, CodingKey {
            case memoryID = "memory_id"
            case paperID = "paper_id"
            case sourceTurnID = "source_turn_id"
            case sourceNoteID = "source_note_id"
            case status, text, origin
        }

        let memoryID: UUID
        let paperID: UUID?
        let sourceTurnID: UUID?
        let sourceNoteID: UUID?
        let origin: String
        let status: String
        let text: String
    }

    private struct MemoryOverview: Encodable {
        let overview: ResearchOverview
        let topics: [ResearchBrief.Topic]
        let memories: [RecalledMemory]
        let connections: [EffectiveResearchMemory.Entry]
        let sources: [SourceReference]
    }

    private struct SourceReference: Encodable {
        let paperID: UUID
        let noteID: UUID?
        let title: String
        let excerpt: String?
    }

    private func researchOverview(
        query: String?, scope: ResearchBrief.Scope, epoch: UUID,
        onSubject: @MainActor (String) -> Void
    ) async throws -> AgentToolOutcome {
        let scopePaperID: UUID?
        switch scope {
        case .library:
            scopePaperID = nil
        case .paper(let id):
            guard reader.state.papers.contains(where: { $0.id == id }) else {
                throw ReaderError.message("这篇论文已不在书库中。")
            }
            scopePaperID = id
        case .shelf(let id):
            guard reader.state.shelves.contains(where: { $0.id == id }) else {
                throw ReaderError.message("这个书架已不在书库中。")
            }
            scopePaperID = nil
        }
        var records: [RecalledMemory] = []
        var entries: [EffectiveResearchMemory.Entry] = []
        var sources: [MemoryItem] = []
        let brief = try await reader.researchBrief(
            matching: query, limit: min(4, limits.maxResults), scope: scope)
        try check(epoch)
        if let query {
            let scopeShelfID: UUID? =
                if case .shelf(let id) = scope { id } else { reader.activeShelfID }
            let found = try await reader.researchMemory.relevant(
                to: query, paperID: scopePaperID, shelfID: scopeShelfID, scope: scope, state: reader.state,
                excluding: reader.pendingImportIDs)
            try check(epoch)
            let effective = try await reader.effectiveSleepMemory(
                question: query, paperID: scopePaperID, recalled: found, scope: scope)
            try check(epoch)
            entries = effective.entries
            sources = effective.sources
            let origins = ResearchMemoryOrigins(state: reader.state, excluding: reader.pendingImportIDs)
            var versions = ChatSourceVersions()
            for source in sources { versions.include(source) }
            for memory in effective.originals.prefix(max(0, limits.maxResults)) {
                guard let origin = origins.resolve(memory) else { continue }
                let paperID: UUID? = if case .paper(let id) = origin { id } else { nil }
                let source: String
                switch memory.librarySource {
                case .reader: source = "library_reader"
                case .note: source = "personal_note_hypothesis"
                case .paper: source = "paper_reading"
                case nil: source = "paper_discussion"
                }
                records.append(
                    .init(
                        memoryID: memory.id, paperID: paperID,
                        sourceTurnID: ["library_reader", "paper_discussion"].contains(source) ? memory.sourceID : nil,
                        sourceNoteID: source == "personal_note_hypothesis" ? memory.sourceID : nil, origin: source,
                        status: memory.userEdited ? "user_edited" : "ai_unverified",
                        text: String(memory.text.prefix(400))))
            }
            guard versions.isCurrent(in: reader.state, excluding: reader.pendingImportIDs) else {
                throw ReaderError.message("长期记忆刚刚更新，请重新检索。")
            }
        }
        guard reader.isResearchBriefCurrent(brief) else {
            throw ReaderError.message("研究简报的来源刚刚更新，请重新检索。")
        }
        var overviewState = reader.state
        switch scope {
        case .library:
            break
        case .paper(let id):
            overviewState.papers = overviewState.papers.filter { $0.id == id }
        case .shelf(let id):
            overviewState.papers = overviewState.papers.filter {
                reader.state.paperShelfIDs[$0.id.uuidString] == id
            }
        }
        let overview = ResearchOverview(state: overviewState, excluding: reader.pendingImportIDs)
        let encoder = JSONEncoder()
        var topics = brief.topics
        func payload() throws -> Data {
            var seen = Set<String>()
            let sourceReferences = topics.flatMap(\.sources).compactMap { source -> SourceReference? in
                let key = source.noteID?.uuidString ?? source.paperID.uuidString
                guard seen.insert(key).inserted else { return nil }
                return SourceReference(
                    paperID: source.paperID, noteID: source.noteID, title: source.title, excerpt: source.excerpt)
            }
            return try encoder.encode(
                MemoryOverview(
                    overview: overview, topics: topics, memories: records, connections: entries,
                    sources: sourceReferences))
        }
        var bytes = try payload()
        var shortened = false
        while bytes.count > limits.maxToolResultBytes {
            if !topics.isEmpty {
                topics.removeLast()
            } else if !records.isEmpty {
                records.removeLast()
            } else if !entries.isEmpty {
                entries.removeLast()
            } else {
                throw ReaderError.message("研究概览超过本次工具容量。")
            }
            bytes = try payload()
            shortened = true
        }
        if !sources.isEmpty {
            var recalled = ChatSourceVersions()
            recalled.sleepRevision = reader.memorySleep.edition.revision
            for memory in sources { recalled.include(memory) }
            // Keep the earliest revision when two calls recall the same item in one transcript.
            remember(recalled)
            paperRegistry.formUnion(records.compactMap(\.paperID))
        }
        lastResearchBrief = brief
        onSubject(query == nil ? "研究方向锚点" : "长期研究记忆")
        return AgentToolOutcome(
            content: String(decoding: bytes, as: UTF8.self), cards: [],
            truncated: shortened || overview.shelfCount > overview.topics.count, message: nil)
    }
}
