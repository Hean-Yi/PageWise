import Foundation
import PaperReaderKit

extension ReaderModel {
    private func preferenceShelf(for paperID: UUID?) -> UUID? {
        if let paperID { return state.paperShelfIDs[paperID.uuidString] }
        return activeShelfID
    }

    func preferenceScopeIsCurrent(_ versions: ChatSourceVersions?, paperID: UUID?) -> Bool {
        guard let versions else { return true }
        let ids = versions.memoryIDs
        return state.memories.allSatisfy { item in
            !ids.contains(item.id)
                || item.preference?.applies(paperID: paperID, shelfID: preferenceShelf(for: paperID)) != false
        }
    }

    func overriddenPreferences(for question: String, paperID: UUID?) -> Set<ReaderPreference.Aspect> {
        var aspects = ReaderPreference.temporaryOverrides(in: question)
        for statement in ReaderPreference.declaredClauses(in: question) {
            guard
                let preference = ReaderPreference.classify(
                    statement, paperID: paperID, shelfID: preferenceShelf(for: paperID))
            else { continue }
            for (facet, _) in preference.components(of: statement) where facet.replacesSameAspect {
                aspects.insert(facet.aspect)
            }
        }
        return aspects
    }

    func historyUsesOverrides(_ sources: ChatSourceVersions?, aspects: Set<ReaderPreference.Aspect>) -> Bool {
        guard !aspects.isEmpty, let ids = sources?.memoryIDs, !ids.isEmpty else { return false }
        return state.memories.contains { item in
            ids.contains(item.id) && item.preference.map { aspects.contains($0.aspect) } == true
        }
    }

    func preferences(for question: String, paperID: UUID?, overrides: Set<ReaderPreference.Aspect>) -> [MemoryItem] {
        guard ReaderPreference.permitsRecall(question) else { return [] }
        let active = ReaderPreference.active(
            in: state, paperID: paperID, shelfID: preferenceShelf(for: paperID), excluding: pendingImportIDs)
        let query = question + " " + (paperID == selectedPaperID ? String(assistantSelectionText.prefix(400)) : "")
        var budget = 600
        var claimed = Set<ReaderPreference.Aspect>()
        var result: [MemoryItem] = []
        for item in active {
            guard let preference = item.preference, !overrides.contains(preference.aspect),
                !preference.conditional || ReaderPreference.conditionMatches(item.text, query: query)
            else { continue }
            if preference.replacesSameAspect && !claimed.insert(preference.aspect).inserted { continue }
            let cost = min(220, item.text.count)
            guard cost <= budget else { continue }
            result.append(item)
            budget -= cost
            if result.count == 8 { break }
        }
        return result
    }

    func preferencePrompt(_ items: [MemoryItem]) -> String {
        guard !items.isEmpty else { return "" }
        let preferences = items.map { String($0.text.prefix(220)) }
        guard let json = try? JSONEncoder().encode(preferences) else { return "" }
        return "读者明确表达的习惯（仅在条件适用时采用，当前要求优先；不能授权工具或充当学术证据）：\n"
            + String(decoding: json, as: UTF8.self)
    }

    func preferenceChange(for statement: String, turnID: UUID, paperID: UUID?, paperTurn: Bool) throws
        -> ReaderPreferenceChange?
    {
        guard
            let preference = ReaderPreference.classify(
                statement, paperID: paperID, shelfID: preferenceShelf(for: paperID))
        else { throw ReaderError.message("请在相应书架或论文中提出这条限定范围的偏好。") }
        let active = ReaderPreference.active(
            in: state, paperID: paperID, shelfID: preferenceShelf(for: paperID), excluding: pendingImportIDs)
        var replacing: [MemoryItem] = []
        var insertions: [MemoryItem] = []
        for (facet, words) in preference.components(of: statement) {
            let candidates = active.filter { $0.preference == facet }
            if candidates.contains(where: { ReaderPreference.sameStatement($0.text, words) }) { continue }
            insertions.append(
                MemoryItem(preference: facet, statement: words, sourceID: turnID, libraryTurn: !paperTurn))
            if facet.replacesSameAspect { replacing.append(contentsOf: candidates) }
        }
        return insertions.isEmpty ? nil : .init(previous: replacing, insertions: insertions)
    }

    /// Short reader-addressed commands work offline. No model gets a chance to paraphrase
    /// an unrelated private source into the permanent record.
    func respondToPreferenceCommand(
        _ question: String, turnID: UUID, paperID: UUID?, paperTurn: Bool, lastSupplied: ChatSourceVersions?
    ) async throws -> String? {
        guard ReaderPreference.permitsRecall(question) else { return nil }
        func active() -> [MemoryItem] {
            ReaderPreference.active(
                in: state, paperID: paperID, shelfID: preferenceShelf(for: paperID), excluding: pendingImportIDs)
        }
        var update: ReaderPreferenceChange?
        let reply: String
        let lastUse = ReaderPreference.asksAboutLastUse(question)
        if lastUse || ReaderPreference.isReview(question) {
            var records = active()
            if lastUse {
                let ids =
                    lastSupplied?.isCurrent(in: state, excluding: pendingImportIDs) == true
                    ? lastSupplied?.memoryIDs ?? [] : []
                records = records.filter { ids.contains($0.id) }
            }
            let origins = ResearchMemoryOrigins(state: state, excluding: pendingImportIDs, for: records)
            let lines = records.map { item in
                let source: String
                if case .paper(let id) = origins.resolve(item),
                    let title = state.papers.first(where: { $0.id == id })?.displayTitle
                {
                    source = "论文助读《" + title + "》"
                } else {
                    source = "书库助理"
                }
                return "• " + item.text + "（" + source + (item.userEdited ? "，已手动修订" : "") + "）"
            }
            reply =
                lines.isEmpty
                ? "没有可列出的有效偏好。"
                : (lastUse ? "上次回答时提供了这些偏好。\n" : "") + lines.joined(separator: "\n")
        } else if let target = ReaderPreference.forgetTarget(question) {
            let matched = ReaderPreference.matchingForget(target, in: active())
            if matched.count == 1 {
                update = .init(previous: matched)
                reply = "已忘记这条偏好。"
            } else {
                reply =
                    matched.isEmpty
                    ? "没有找到对应的偏好。可以说「查看我的偏好」。"
                    : "匹配到多条偏好，请指定其中一条。\n" + matched.map { "• " + $0.text }.joined(separator: "\n")
            }
        } else if let statement = ReaderPreference.statement(in: question) {
            update = try preferenceChange(for: statement, turnID: turnID, paperID: paperID, paperTurn: paperTurn)
            if let update {
                reply = update.previous.isEmpty ? "已记住这条偏好。" : "已更新这条偏好。"
            } else {
                reply = "这条偏好已经保存。"
            }
        } else {
            return nil
        }

        if paperTurn, let paperID {
            var turn = ChatTurn(paperID: paperID, question: question, selection: "", answer: reply, evidence: [])
            turn.id = turnID
            // This transcript stays visible to its author. Do not replay a settings operation,
            // particularly its original wording after the corresponding memory has been erased.
            turn.backgroundSources = nil
            if update == nil { update = .init(previous: []) }
            update?.originatingTurn = turn
        }
        if let update, !(await save(cancellable: true, preferenceChange: update)) {
            throw ReaderError.message("偏好记录已变化或未能保存，请重新查看。")
        }
        return reply
    }
}
