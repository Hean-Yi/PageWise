import Foundation
import PaperReaderKit

struct MemoryRecordMutation {
    enum Operation {
        case revise(id: UUID, statement: String, expectedRevision: String? = nil)
        case forget(id: UUID, expectedRevision: String? = nil)
    }

    let operation: Operation
    let auditTrigger: String?

    var memoryID: UUID {
        switch operation {
        case .revise(let id, _, _), .forget(let id, _): id
        }
    }

    var auditAction: String {
        switch operation {
        case .revise: "revise"
        case .forget: "forget"
        }
    }

    func apply(to state: inout LibraryState) -> Bool {
        switch operation {
        case .revise(let id, let statement, let expectedRevision):
            guard let index = state.memories.firstIndex(where: { $0.id == id }),
                state.memories[index].isActive, !state.memories[index].userEdited,
                expectedRevision == nil || state.memories[index].matchesRevision(expectedRevision!)
            else { return false }
            return state.memories[index].correct(to: statement)
        case .forget(let id, let expectedRevision):
            guard let index = state.memories.firstIndex(where: { $0.id == id }),
                state.memories[index].isActive, !state.memories[index].userEdited,
                expectedRevision == nil || state.memories[index].matchesRevision(expectedRevision!)
            else { return false }
            return state.memories[index].forget()
        }
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
