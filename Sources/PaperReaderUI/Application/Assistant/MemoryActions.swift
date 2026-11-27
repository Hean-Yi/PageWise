import Foundation
import PaperReaderKit

struct MemoryRecordMutation {
    enum Operation {
        case revise(
            id: UUID, statement: String, expectedRevision: String? = nil, allowUserEdited: Bool = false,
            replacementID: UUID = UUID(), at: Date = Date())
        case forget(id: UUID, expectedRevision: String? = nil, allowUserEdited: Bool = false)
        case supersede(oldID: UUID, replacementID: UUID, at: Date = Date())
    }

    let operation: Operation
    let auditTrigger: String?

    var memoryID: UUID {
        switch operation {
        case .revise(let id, _, _, _, _, _), .forget(let id, _, _), .supersede(let id, _, _): id
        }
    }

    var replacementID: UUID? {
        switch operation {
        case .revise(_, _, _, _, let replacementID, _): replacementID
        case .supersede(_, let replacementID, _): replacementID
        case .forget: nil
        }
    }

    var auditAction: String {
        switch operation {
        case .revise: "revise"
        case .forget: "forget"
        case .supersede: "supersede"
        }
    }

    func apply(to state: inout LibraryState) -> Bool {
        switch operation {
        case .revise(let id, let statement, let expectedRevision, let allowUserEdited, let replacementID, let date):
            guard let index = state.memories.firstIndex(where: { $0.id == id }),
                state.memories[index].isActive,
                allowUserEdited || !state.memories[index].userEdited,
                expectedRevision == nil || state.memories[index].matchesRevision(expectedRevision!)
            else { return false }
            let cleaned = MemoryItem.strippedPrefix(statement)
            guard !cleaned.isEmpty else { return false }
            if state.memories[index].userEdited {
                return state.memories[index].correct(to: cleaned)
            }
            guard cleaned != MemoryItem.strippedPrefix(state.memories[index].text) else { return false }
            let replacement = MemoryItem.revisedAutomatic(
                from: state.memories[index], id: replacementID, statement: cleaned, at: date)
            guard state.memories[index].supersede(by: replacement.id, at: date) else { return false }
            state.memories.append(replacement)
            return true
        case .forget(let id, let expectedRevision, let allowUserEdited):
            guard let index = state.memories.firstIndex(where: { $0.id == id }),
                state.memories[index].isActive,
                allowUserEdited || !state.memories[index].userEdited,
                expectedRevision == nil || state.memories[index].matchesRevision(expectedRevision!)
            else { return false }
            return state.memories[index].forget()
        case .supersede(let oldID, let replacementID, let date):
            guard let index = state.memories.firstIndex(where: { $0.id == oldID }),
                state.memories.contains(where: { $0.id == replacementID && $0.isActive }),
                state.memories[index].isActive, !state.memories[index].userEdited
            else { return false }
            return state.memories[index].supersede(by: replacementID, at: date)
        }
    }
}

extension ReaderModel {
    /// Strict directive gate required to touch a `userEdited == true` memory. Common ML/academic
    /// vocabulary ("不是…而是", "修改", "调整", "更新", "update", "change", "instead") never
    /// unlocks reader-edited memories unless the reader explicitly targets a memory or tracking item.
    static func hasExplicitMemoryRevisionDirective(_ question: String) -> Bool {
        question.range(
            of:
                #"(?i)(?:更正|改正|纠正|修正|修改|更新|改成|改为|替换).{0,18}(?:记忆|记录|关注点|研究方向|研究问题|这条|那条|刚才记)|(?:记忆|记录|关注点|研究方向|研究问题|这条|那条|刚才记).{0,18}(?:更正|改正|纠正|修正|修改|更新|改成|改为|替换)|请把.{1,30}(?:改成|改为|更新成|更新为|修正为|修正成)|\b(?:correct|revise|update|change|replace)\b.{0,24}\b(?:memory|memories|record|focus|direction|preference)\b"#,
            options: .regularExpression) != nil
    }

    /// Strict directive gate required to delete a `userEdited == true` memory. Uses explicit word
    /// boundaries so terms like "dropout" or "early stopping" never match "drop" or "stop".
    static func hasExplicitMemoryForgetDirective(_ question: String) -> Bool {
        question.range(
            of:
                #"(?i)(?:忘掉|忘记|删除|移除|撤回).{0,24}(?:记忆|记录|关注点|研究方向|研究问题|这条|那条|关于|旧)|(?:记忆|记录|关注点|研究方向|研究问题|这条|那条).{0,18}(?:忘掉|忘记|删除|移除|撤回|不用再追|不再追|停止追|不用再记|不再记)|(?:不用再|无需再|不再|停止|取消)(?:追查|追踪|跟踪|关注|记录|记住)|\b(?:forget|erase)\b.{0,24}\b(?:memory|memories|record|that|it|this|old|my)\b|\b(?:remove|delete)\b.{0,24}\b(?:memory|memories|record|preference)\b|\b(?:stop tracking|no longer track|drop\s+(?:this|that|the|my)\s+(?:memory|record|topic))\b"#,
            options: .regularExpression) != nil
    }

    /// Broader natural shift signal permitted ONLY for revising automatic (`userEdited == false`)
    /// memories; never unlocks reader-edited records.
    static func hasExplicitRevisionIntent(_ question: String) -> Bool {
        hasExplicitMemoryRevisionDirective(question)
            || question.range(
                of:
                    #"(?i)更正|改正|纠正|修正|改变主意|改主意|其实我现在更在意|我现在更在意|放后面|现在只看|现在只关注|改关注|重心放到|转向.{0,12}(?:研究|关注|比较)|改成|改为|说错了|记错了|前提不对|其实(?:是|应该)|换个方向|不再看|\bchanged my mind\b|\bnow focus(?:ing)? on\b|\bno longer (?:track|focus|study|care)\b|\bstop tracking\b|\bactually.{0,24}(?:wrong|instead|focus)\b|\bswitch(?:ed|ing)?\s+(?:my\s+)?focus\b"#,
                options: .regularExpression) != nil
    }

    /// Natural forget signal for automatic memories, still guarded by word boundaries.
    static func hasExplicitForgetIntent(_ question: String) -> Bool {
        hasExplicitMemoryForgetDirective(question)
            || question.range(
                of:
                    #"(?i)忘掉|忘记|\bforget\b|\bstop tracking\b|\bno longer track\b|(?:不用再|无需再|不再)(?:追查|追踪|关注)"#,
                options: .regularExpression) != nil
    }

    /// Shared validator for both LibraryAgent and Paper Assistant declarative `revise_memory`.
    /// Explicit memory-targeted reader directives may update `userEdited` memories; automatic
    /// memories use bi-temporal supersedence (`userEdited == false`) and never escalate provenance.
    func buildMemoryRevisionMutation(
        memoryID: UUID, statement: String, expectedRevision: String?, question: String
    ) throws -> MemoryRecordMutation {
        guard ReaderPreference.permitsRecall(question),
            let current = state.memories.first(where: { $0.id == memoryID }), current.isActive
        else { throw ReaderError.message("本轮没有明确要求更正已有记忆。") }
        if let expectedRevision, !current.matchesRevision(expectedRevision) {
            throw ReaderError.message("这条研究记忆已更新，请重新核对最新版本。")
        }
        let explicitDirective = Self.hasExplicitMemoryRevisionDirective(question)
        let naturalShift = Self.hasExplicitRevisionIntent(question)
        if current.userEdited {
            guard explicitDirective else {
                throw ReaderError.message("读者手动修订的记忆仅在明确指令下才可修改。")
            }
        } else {
            guard naturalShift else {
                throw ReaderError.message("本轮没有明确要求更正已有记忆。")
            }
        }
        let cleaned = MemoryItem.strippedPrefix(statement)
        guard !cleaned.isEmpty, cleaned != MemoryItem.strippedPrefix(current.text) else {
            throw ReaderError.message("新的记忆措辞没有变化。")
        }
        return MemoryRecordMutation(
            operation: .revise(
                id: memoryID, statement: cleaned, expectedRevision: expectedRevision,
                allowUserEdited: explicitDirective),
            auditTrigger: question)
    }

    /// Shared validator for both LibraryAgent and Paper Assistant declarative `forget_memory`.
    func buildMemoryForgetMutation(
        memoryID: UUID, expectedRevision: String?, question: String, recalledIDs: Set<UUID>
    ) throws -> MemoryRecordMutation {
        guard ReaderPreference.permitsRecall(question),
            let target = state.memories.first(where: { $0.id == memoryID }), target.isActive
        else { throw ReaderError.message("本轮没有明确要求删除这条记忆。") }
        if let expectedRevision, !target.matchesRevision(expectedRevision) {
            throw ReaderError.message("这条研究记忆已更新，请重新核对最新版本。")
        }
        let explicitDirective = Self.hasExplicitMemoryForgetDirective(question)
        let naturalForget = Self.hasExplicitForgetIntent(question)
        if target.userEdited {
            guard explicitDirective else {
                throw ReaderError.message("读者手动修订的记忆仅在明确指令下才可删除。")
            }
        } else {
            guard naturalForget else {
                throw ReaderError.message("本轮没有明确要求删除这条记忆。")
            }
        }
        let ignored: Set<String> = ["的", "了", "在", "和", "与", "及", "这", "那", "个", "记录", "记忆", "旧", "新"]
        let questionTerms = Retriever.tokens(question).subtracting(ignored)
        let scored = state.memories.compactMap { item -> (MemoryItem, Int)? in
            guard item.isActive, !item.isResponsePreference else { return nil }
            let overlap = Retriever.tokens(item.text).subtracting(ignored).intersection(questionTerms).count
            return overlap > 0 ? (item, overlap) : nil
        }.sorted { $0.1 > $1.1 }
        let topOverlap = scored.first?.1 ?? 0
        let uniqueTop = scored.filter { $0.1 == topOverlap }
        let recalledThisTurn = recalledIDs.contains(target.id)
        let verifiedByRevision = expectedRevision.map { target.matchesRevision($0) } == true
        guard
            verifiedByRevision || recalledThisTurn || question.localizedCaseInsensitiveContains(target.text)
                || (topOverlap > 0 && uniqueTop.count == 1 && uniqueTop.first?.0.id == target.id)
        else { throw ReaderError.message("记忆删除目标不唯一或与请求不匹配。") }
        return MemoryRecordMutation(
            operation: .forget(id: target.id, expectedRevision: expectedRevision, allowUserEdited: explicitDirective),
            auditTrigger: question)
    }
}

extension ReaderModel {
    public func updateMemory(id: UUID, text: String) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }) else { return }
        let previous = state.memories[index]
        guard state.memories[index].correct(to: text) else { return }
        let appliedRevision = state.memories[index].correctionRevision
        Task {
            if !(await save()),
                let current = state.memories.firstIndex(where: { $0.id == id }),
                state.memories[current].correctionRevision == appliedRevision
            {
                state.memories[current] = previous
            }
        }
    }
    public func deleteMemory(_ id: UUID) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }) else { return }
        let previous = state.memories[index]
        guard state.memories[index].forget() else { return }
        Task {
            if !(await save()),
                let current = state.memories.firstIndex(where: { $0.id == id }),
                state.memories[current].deleted
            {
                state.memories[current] = previous
            }
        }
    }

    /// A reading/translation observation creates one paper-grounded memory. The reader can
    /// delete it; a deleted paper memory is a tombstone and must not be recreated.
    func ensurePaperMemory(paperID: UUID) async {
        guard let paper = state.papers.first(where: { $0.id == paperID }),
            !state.memories.contains(where: { memory in
                if case .paper(let source) = memory.librarySource { return source == paperID }
                return false
            })
        else { return }
        var statement = "读过《" + String(paper.displayTitle.prefix(160)) + "》"
        let summary =
            paper.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? paper.onlineSource?.abstractText?.trimmingCharacters(in: .whitespacesAndNewlines) : paper.summary
        if let summary, !summary.isEmpty {
            statement += "：" + String(summary.prefix(220))
        }
        state.memories.append(MemoryItem(paperID: paperID, statement: statement))
        await save()
    }

    /// Update salience recall telemetry without disturbing research revisions or sleep signatures.
    func recordMemoryRecall(_ ids: Set<UUID>, at now: Date = Date()) {
        guard !ids.isEmpty else { return }
        var updatedIDs = Set<UUID>()
        for index in state.memories.indices {
            let item = state.memories[index]
            guard ids.contains(item.id), item.isActive, !item.userEdited, !item.isResponsePreference else { continue }
            if let last = item.lastRecalledAt, now.timeIntervalSince(last) < 60, item.recallCount != nil {
                continue
            }
            state.memories[index].recordRecall(at: now)
            updatedIDs.insert(item.id)
        }
        guard !updatedIDs.isEmpty, loaded else { return }
        let store = self.store
        Task(priority: .utility) {
            try? await store.recordMemoryRecall(updatedIDs, at: now)
        }
    }

    /// Materialize consolidated `superseded` sleep decisions onto the main `MemoryItem` records so
    /// direct retrieval and settings immediately reflect the bi-temporal `invalidAt` window.
    func applySleepSupersedence(_ edition: MemorySleepEdition, at now: Date = Date()) async {
        let superseded = edition.recallConnections(for: state.memories).filter {
            $0.kind == .superseded && $0.current != nil
        }
        guard !superseded.isEmpty else { return }
        for group in superseded {
            guard let currentID = group.current else { continue }
            for memberID in group.members where memberID != currentID {
                let mutation = MemoryRecordMutation(
                    operation: .supersede(oldID: memberID, replacementID: currentID, at: now),
                    auditTrigger: "memory_sleep:\(currentID.uuidString)")
                _ = await save(cancellable: true, memoryMutation: mutation)
            }
        }
    }
}

extension ReaderModel {
    /// Explicit, unambiguous memory maintenance is local. The model is only used when the reader's
    /// wording or the target is ambiguous; this removes a full model round from common commands.
    func respondToMemoryCommand(_ question: String) -> String? {
        let memoryPattern =
            #"(?i)^\s*(?:请|帮我|麻烦你?)?\s*(?:忘掉|忘记|删除|移除|撤回|forget|remove|delete)\s*(?:一下|我的|这条|这个|关于)?\s*(.{2,80}?)\s*(?:这条)?(?:记忆|记录)?\s*[。.!！]?\s*$"#
        let revisePattern =
            #"(?i)^\s*(?:请|帮我|麻烦你?)?\s*(?:更正|改正|修改|改成|改为|correct|change|update)\s*(?:一下|我的|这条|这个|关于)?\s*(.{2,80}?)\s*(?:为|成|to)\s*(.{2,240})\s*[。.!！]?\s*$"#
        let moveRevisionPattern =
            #"(?i)^\s*(?:请|帮我|麻烦你?)?\s*(?:把|将)\s*(?:我的|这条|这个|关于)?\s*(.{2,80}?)\s*(?:更正|改正|修改|改成|改为)\s*(?:为|成|to)?\s*(.{2,240})\s*[。.!！]?\s*$"#
        func capture(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: question, range: NSRange(question.startIndex..., in: question))
            else { return nil }
            return (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: question).map { String(question[$0]) }
            }
        }
        let active = state.memories.filter { !$0.deleted && !$0.isResponsePreference && !$0.text.isEmpty }
        func match(_ target: String) -> MemoryItem? {
            let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let direct = active.filter {
                $0.text.localizedCaseInsensitiveContains(target)
                    || target.localizedCaseInsensitiveContains($0.text)
            }
            if direct.count == 1 { return direct[0] }
            let terms = Retriever.tokens(target)
            let scored = active.compactMap { memory -> (MemoryItem, Int)? in
                let overlap = Retriever.tokens(memory.text).intersection(terms).count
                return overlap >= 2 ? (memory, overlap) : nil
            }.sorted { $0.1 > $1.1 }
            guard let best = scored.first, scored.filter({ $0.1 == best.1 }).count == 1 else { return nil }
            return best.0
        }
        if let groups = capture(memoryPattern), let target = groups.first, let memory = match(target),
            let index = state.memories.firstIndex(where: { $0.id == memory.id })
        {
            let previous = state.memories[index]
            guard state.memories[index].forget() else { return nil }
            Task {
                if await save() {
                    try? await store.recordMemoryAudit(memoryID: memory.id, action: "forget", trigger: question)
                } else if let current = state.memories.firstIndex(where: { $0.id == memory.id }),
                    state.memories[current].deleted
                {
                    state.memories[current] = previous
                }
            }
            return "已忘掉这条研究记忆。"
        }
        func replacement(_ value: String) -> String {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！ "))
        }
        if let groups = capture(moveRevisionPattern), groups.count == 2, let memory = match(groups[0]),
            let index = state.memories.firstIndex(where: { $0.id == memory.id })
        {
            let previous = state.memories[index]
            guard state.memories[index].correct(to: replacement(groups[1])) else { return nil }
            let appliedRevision = state.memories[index].correctionRevision
            Task {
                if await save() {
                    try? await store.recordMemoryAudit(memoryID: memory.id, action: "revise", trigger: question)
                } else if let current = state.memories.firstIndex(where: { $0.id == memory.id }),
                    state.memories[current].correctionRevision == appliedRevision
                {
                    state.memories[current] = previous
                }
            }
            return "已更正这条研究记忆。"
        }
        if let groups = capture(revisePattern), groups.count == 2, let memory = match(groups[0]),
            let index = state.memories.firstIndex(where: { $0.id == memory.id })
        {
            let previous = state.memories[index]
            guard state.memories[index].correct(to: replacement(groups[1])) else { return nil }
            let appliedRevision = state.memories[index].correctionRevision
            Task {
                if await save() {
                    try? await store.recordMemoryAudit(memoryID: memory.id, action: "revise", trigger: question)
                } else if let current = state.memories.firstIndex(where: { $0.id == memory.id }),
                    state.memories[current].correctionRevision == appliedRevision
                {
                    state.memories[current] = previous
                }
            }
            return "已更正这条研究记忆。"
        }
        return nil
    }
}

extension ReaderModel {
    /// Explicit "remember this" commands do not need a model round. Source validation and dedup
    /// still run before the item is written; ambiguous or question-like wording falls back to the
    /// normal tool path.
    func respondToRememberCommand(_ question: String, turnID: UUID? = nil) -> String? {
        guard !question.contains("?"), !question.contains("？") else { return nil }
        let pattern =
            #"(?i)^\s*(?:请|帮我|麻烦你?)?\s*(?:记住|记下|记录|remember|save)\s*(?:一下|这个|这条)?\s*[：:，,\s]*(.{6,240})\s*[。.!！]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)),
            let range = Range(match.range(at: 1), in: question)
        else { return nil }
        let statement = String(question[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty, !ResearchQuestionProposal.isOperational(statement),
            ResearchMemory.permitsAutomaticWrite(for: question)
        else { return nil }
        // The explicit command is itself the source turn; a random UUID would be an unreferenced origin.
        let item = MemoryItem(
            agentStatement: statement, sourceID: turnID ?? UUID(), source: .reader(quote: statement))
        guard
            MemoryStatementProposal.isEligible(
                item, in: state, excluding: pendingImportIDs)
        else { return nil }
        state.memories.append(item)
        Task {
            if await save() {
                try? await store.recordMemoryAudit(memoryID: item.id, action: "remember", trigger: question)
            } else {
                state.memories.removeAll { $0.id == item.id }
            }
        }
        return "已记住这条研究记忆。"
    }
}
