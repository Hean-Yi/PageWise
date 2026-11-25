import Foundation

/// Resolve both legacy paper discussions and attributed library proposals against one library snapshot.
public struct ResearchMemoryOrigins {
    public enum Origin: Equatable {
        case reader
        case paper(UUID)
    }

    private let papers: Set<UUID>
    private let chats: [UUID: UUID]
    private let notes: [UUID: ReadingNote]

    public init(state: LibraryState, excluding pending: Set<UUID> = [], for items: [MemoryItem]? = nil) {
        var chatSources = Set<UUID>()
        var noteSources = Set<UUID>()
        var paperSources = Set<UUID>()
        for item in items ?? state.memories where !item.deleted {
            switch item.librarySource {
            case nil: chatSources.insert(item.sourceID)
            case .note: noteSources.insert(item.sourceID)
            case .paper(let paperID): paperSources.insert(paperID)
            case .reader: break
            }
        }
        papers =
            chatSources.isEmpty && noteSources.isEmpty && paperSources.isEmpty
            ? [] : Set(state.papers.map(\.id)).subtracting(pending)
        chats =
            chatSources.isEmpty
            ? [:]
            : Dictionary(
                state.chats.lazy.filter { chatSources.contains($0.id) }.map { ($0.id, $0.paperID) },
                uniquingKeysWith: { first, _ in first })
        if noteSources.isEmpty {
            notes = [:]
            return
        }
        for turn in state.chats {
            if let id = turn.readingNoteID { noteSources.remove(id) }
            if let ids = turn.closeReadingNoteIDs { noteSources.subtract(ids) }
        }
        notes = Dictionary(
            state.readingNotes.lazy.filter { noteSources.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    public func resolve(_ item: MemoryItem) -> Origin? {
        guard !item.deleted, !item.text.isEmpty else { return nil }
        switch item.librarySource {
        case .reader(let quote):
            return quote.isEmpty ? nil : .reader
        case .note(let paperID, let modifiedAt):
            guard papers.contains(paperID), let note = notes[item.sourceID], note.paperID == paperID,
                note.modifiedAt == modifiedAt, note.deletedAt == nil, note.backgroundSources == nil
            else { return nil }
            return .paper(paperID)
        case .paper(let paperID):
            return papers.contains(paperID) ? .paper(paperID) : nil
        case nil:
            guard let paperID = chats[item.sourceID], papers.contains(paperID) else { return nil }
            return .paper(paperID)
        }
    }
}

/// The runtime supplies the actual turn or registered note. Model arguments never establish an origin.
public struct ResearchQuestionProposal: Sendable {
    public let item: MemoryItem

    public static func isOperational(_ text: String) -> Bool {
        let oneOff =
            #"(?i)^(?:(?:请你?|帮我|麻烦|给我|先|只要|只需|现在|这次|please|can you|could you)\s*)*(?:找|搜|查找|检索|下载|导入|收藏|打开|翻译|预览|移动|整理书架|find\b|search\b|download\b|import\b|open\b|translate\b|bookmark\b)"#
        return text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: oneOff, options: .regularExpression)
            != nil
            || !LibraryOrganizationIntent.tools(for: text).isEmpty
    }

    public static func isWriteRequest(_ message: String) -> Bool {
        message.range(
            of:
                #"(?i)(?:记下|记住|记录|保存|留下|收进|加入).{0,18}(?:研究问题|待查问题|研究线索|研究方向|研究记忆)|(?:remember|save|track)\s+(?:this|my|the|a)\s+(?:research )?question\b"#,
            options: .regularExpression) != nil
    }

    public static func isRecallRequest(_ message: String) -> Bool {
        let recall =
            #"(?i)回顾|回忆|(?:之前|以前|最近|过去|长期|一直).{0,10}(?:追问|在意|看过|关注|关心|记过|研究|讨论).{0,16}(?:哪|什么|吗)|(?:已有|现有|本地).{0,12}(?:记忆|笔记).{0,18}(?:说明|回答|总结|列出)|what (?:have|was|did|do) i (?:been |previously |already )?(?:stud|explor|ask|writ|remember|care)|recall (?:my|what)"#
        return !isWriteRequest(message) && message.range(of: recall, options: .regularExpression) != nil
    }

    /// A request to remember a research question may also independently ask for a note at a passage.
    public static func alsoRequestsPaperNote(_ message: String) -> Bool {
        if !isWriteRequest(message) { return ReadingNoteIntent.isRequested(message) }
        let clauses = message.replacingOccurrences(
            of: #"并且|同时|然后|顺便|并(?=在|把|将|请|标|记|写)|(?i:\band\b)"#, with: "；", options: .regularExpression
        )
        .components(separatedBy: CharacterSet(charactersIn: "。！？；;\n"))
        return clauses.contains {
            !isWriteRequest($0) && ReadingNoteIntent.isRequested($0.trimmingCharacters(in: .whitespaces))
        }
    }

    public init(question: String, readerTurnID: UUID, readerMessage: String, quote: String, sourceOnly: Bool = false)
        throws
    {
        let unavailable =
            #"(?ms)^\s*>[^\n]*(?:\n|$)|`{3}.*?(?:`{3}|$)|“[^”]*(?:”|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|"[^"]*(?:"|$)|‘[^’]*(?:’|$)|`[^`]*(?:`|$)"#
        let ownWords = readerMessage.replacingOccurrences(of: unavailable, with: "■", options: .regularExpression)
        let statement = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        func boundary(_ character: Character?) -> Bool {
            guard let character else { return true }
            return character.isNewline || "。！？?!；;.:：".contains(character)
        }
        let attribution =
            #"(?i)(?:作者|论文|原文|他们|她|他)(?:说|写|表示|认为|宣称)|(?:the |a )?(?:author|paper)s? (?:say|claim|state)s?\b"#
        guard ResearchMemory.permitsAutomaticWrite(for: readerMessage), (6...240).contains(statement.count),
            !statement.contains("■"), !Self.isOperational(statement), let range = ownWords.range(of: statement),
            boundary(ownWords[..<range.lowerBound].trimmingCharacters(in: .whitespaces).last),
            boundary(statement.last)
                || boundary(ownWords[range.upperBound...].trimmingCharacters(in: .whitespaces).first),
            statement.range(of: attribution, options: .regularExpression) == nil,
            ownWords[..<range.lowerBound].components(separatedBy: CharacterSet(charactersIn: "。!！?？;.\n")).last?.range(
                of: attribution, options: .regularExpression) == nil
        else { throw ReaderError.message("请引用读者本轮表达的完整研究问题或想法。") }
        item = try Self.make(
            question, evidence: statement, id: readerTurnID, source: .reader(quote: statement), sourceOnly: sourceOnly)
    }

    public init(question: String, quote: String, registeredExcerpt: String, note: ReadingNote, sourceOnly: Bool = false)
        throws
    {
        guard note.deletedAt == nil, note.backgroundSources == nil,
            (6...240).contains(quote.count), registeredExcerpt.contains(quote),
            ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(quote)
        else { throw ReaderError.message("需引用当前笔记结果中可核对的原句。") }
        item = try Self.make(
            question, evidence: quote, id: note.id, source: .note(paperID: note.paperID, modifiedAt: note.modifiedAt),
            sourceOnly: sourceOnly)
    }

    private static func make(
        _ question: String, evidence: String, id: UUID, source: MemoryItem.LibrarySource, sourceOnly: Bool
    ) throws
        -> MemoryItem
    {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...200).contains(question.count), let last = question.last, "?？".contains(last),
            !question.contains("\n"),
            !Retriever.tokens(question).subtracting(weakTerms)
                .isDisjoint(with: Retriever.tokens(evidence).subtracting(weakTerms))
        else { throw ReaderError.message("请将研究线索写成一个包含来源主题词的具体问题。") }
        // Another source may be revoked independently. Only the verified quotation can cross
        // the persistence boundary when a model has already read unrelated private material.
        let content = sourceOnly ? "待追查的原话「" + evidence + "」" : question
        return MemoryItem(question: content, sourceID: id, source: source, evidence: evidence)
    }

    private static let weakTerms: Set<String> = [
        "的", "什么", "这个", "研究", "关注", "如何", "问题", "我", "是", "了", "the", "a", "i", "to", "of", "what", "how",
        "is", "my", "research", "focus", "and", "in", "does", "this", "can", "why",
    ]

    public func isEligible(in state: LibraryState, excluding pending: Set<UUID>) -> Bool {
        guard ResearchMemoryOrigins(state: state, excluding: pending, for: [item]).resolve(item) != nil,
            let question = item.originalFingerprint, let evidence = item.evidenceFingerprint,
            state.suppressedMemoryFingerprints.isDisjoint(with: [question, evidence])
        else { return false }
        return !state.memories.contains {
            $0.sourceID == item.sourceID || $0.suppressesAutomaticProposition(question)
                || $0.evidenceFingerprint == evidence
        }
    }
}
