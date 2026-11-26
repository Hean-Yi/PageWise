import Foundation
import PaperReaderKit

extension ReaderModel {
    public func updateMemory(id: UUID, text: String) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }),
            state.memories[index].correct(to: text)
        else { return }
        Task { await save() }
    }
    public func deleteMemory(_ id: UUID) {
        guard let index = state.memories.firstIndex(where: { $0.id == id }),
            state.memories[index].forget()
        else { return }
        Task { await save() }
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
            let index = state.memories.firstIndex(where: { $0.id == memory.id }), state.memories[index].forget()
        {
            Task { await save() }
            return "已忘掉这条研究记忆。"
        }
        func replacement(_ value: String) -> String {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！ "))
        }
        if let groups = capture(moveRevisionPattern), groups.count == 2, let memory = match(groups[0]),
            let index = state.memories.firstIndex(where: { $0.id == memory.id }),
            state.memories[index].correct(to: replacement(groups[1]))
        {
            Task { await save() }
            return "已更正这条研究记忆。"
        }
        if let groups = capture(revisePattern), groups.count == 2, let memory = match(groups[0]),
            let index = state.memories.firstIndex(where: { $0.id == memory.id }),
            state.memories[index].correct(to: replacement(groups[1]))
        {
            Task { await save() }
            return "已更正这条研究记忆。"
        }
        return nil
    }
}
