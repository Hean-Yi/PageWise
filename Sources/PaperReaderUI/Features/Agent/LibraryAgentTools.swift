import Foundation
import PaperReaderKit

struct AgentToolOutcome {
    var content: String
    var cards: [AgentCard]
    var truncated: Bool
    var message: String?
}

extension LibraryAgent {
    func execute(_ call: AgentToolCall, epoch: UUID, onSubject: (String) -> Void) async throws -> AgentToolOutcome {
        let arguments = try AgentToolArguments.parse(
            name: call.function.name, json: call.function.arguments, limits: limits)
        try check(epoch)
        switch arguments {
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
        case .readPaper(let id, let page):
            let paper = try registeredPaper(id, page: page)
            onSubject("\(paper.title) · 第 \(page) 页")
            let blocks = paper.blocks.filter { $0.sourcePage == page - 1 }
            let pairs = blocks.prefix(min(max(0, limits.maxResults), 20)).map { block -> (ToolRecord, AgentCard) in
                var card = AgentCard(kind: .evidence, title: paper.title)
                card.paperID = paper.id
                card.blockID = block.id
                card.sourcePage = page
                card.subtitle = "原文第 \(page) 页"
                card.excerpt = String(block.text.prefix(2_000))
                return (ToolRecord(card: card, pageCount: paper.pageCount), card)
            }
            return try result(
                pairs, truncated: blocks.count > pairs.count || blocks.contains { $0.text.count > 2_000 },
                message: blocks.isEmpty ? "这一页暂无已索引的正文。" : nil)
        case .searchOnline(let query):
            onSubject(query)
            guard limits.maxResults > 0 else { return try result([], truncated: true) }
            let found = try await discovery.search(query)
            try check(epoch)
            var seen: Set<String> = []
            let verified = found.prefix(40).compactMap(ArxivClient.verified).filter { seen.insert($0.id).inserted }
            let pairs = verified.prefix(min(limits.maxResults, 20)).map { candidate -> (ToolRecord, AgentCard) in
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

    static func errorResult(_ message: String, maxBytes: Int) throws -> String {
        let data = try JSONEncoder().encode(ToolPayload(ok: false, results: [], truncated: false, message: message))
        guard data.count <= maxBytes else { throw ReaderError.message("工具结果超过长度上限。") }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ToolPayload: Encodable {
    var ok: Bool
    var results: [ToolRecord]
    var truncated: Bool
    var message: String?
    let dataOnly = true
    enum CodingKeys: String, CodingKey {
        case ok, results, truncated, message
        case dataOnly = "data_only"
    }
}

private struct ToolRecord: Encodable {
    var paperID: String?
    var candidateID: String?
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
        self.authors = authors
        self.year = year
        paperID = card.paperID?.uuidString
        candidateID = card.candidateID
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
        case paperID = "paper_id"
        case candidateID = "candidate_id"
        case sourcePage = "source_page"
        case pageCount = "page_count"
        case blockID = "block_id"
        case sourceURL = "source_url"
        case importStatus = "import_status"
    }
}
