import Foundation
import Testing

@testable import PaperReaderKit

@Test func researchMemoryRespectsCorrectionsAndSuppressesRepeatedDeletedQuestions() async throws {
    let index = ResearchMemory()
    let paper = Paper(
        title: "Budget", digest: "d", originalPath: "unused.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    let turn = ChatTurn(paperID: paper.id, question: "长期追踪预算匹配", selection: "", answer: "", evidence: [])
    var state = LibraryState()
    state.papers = [paper]
    state.chats = [turn]
    #expect(ResearchMemory.candidate(" ", turn: turn, state: state) == nil)
    var item = try #require(ResearchMemory.candidate("排查预算混杂", turn: turn, state: state))
    state.memories = [item]
    #expect(try await index.relevant(to: "预算", paperID: paper.id, state: state).map(\.id) == [item.id])
    #expect(try await index.relevant(to: "photosynthesis", paperID: paper.id, state: state).isEmpty)
    var repeated = turn
    repeated.id = UUID()
    item.text = "我只比较预算相同的实验"
    item.userEdited = true
    state.memories = [item]
    #expect(ResearchMemory.candidate("新措辞", turn: repeated, state: state) == nil)
    state.memories[0].deleted = true
    state.memories[0].text = ""
    #expect(try await index.relevant(to: "预算", paperID: paper.id, state: state).isEmpty)
    #expect(ResearchMemory.candidate("重新提取", turn: repeated, state: state) == nil)
}

@Test func researchMemoryProtectsTheOriginalPropositionAcrossQuestionsCorrectionsAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let first = ChatTurn(paperID: UUID(), question: "你会先核对什么？", selection: "", answer: "", evidence: [])
    let second = ChatTurn(paperID: UUID(), question: "这次实验有哪些混杂因素？", selection: "", answer: "", evidence: [])
    let original = "优先核对 RAG 的计算预算。"
    var state = LibraryState()
    state.chats = [first, second]
    var item = try #require(ResearchMemory.candidate(original, turn: first, state: state))
    let fingerprint = try #require(item.originalFingerprint)
    #expect(fingerprint.count == 64)
    let corrected = item.correct(to: "优先核对数据泄漏")
    #expect(corrected)
    #expect(item.originalFingerprint == fingerprint)
    state.memories = [item]
    #expect(ResearchMemory.candidate("优先核对   ｒａｇ 的计算预算！", turn: second, state: state) == nil)
    #expect(ResearchMemory.candidate(item.text, turn: second, state: state) == nil)
    #expect(ResearchMemory.candidate("优先核对 RAG 的推理延时。", turn: second, state: state) != nil)
    let forgotten = state.memories[0].forget()
    let staleEdit = state.memories[0].correct(to: "stale editor")
    #expect(forgotten && !staleEdit)
    try await store.save(state)
    let reopened = try await LibraryStore(directory: root).load()
    #expect(reopened.memories.first?.text == "" && reopened.memories.first?.originalFingerprint == fingerprint)
    let encoded = try #require(String(data: JSONEncoder().encode(reopened.memories[0]), encoding: .utf8))
    #expect(!encoded.contains("计算预算") && !encoded.contains("数据泄漏"))
    #expect(ResearchMemory.candidate(original, turn: second, state: reopened) == nil)
    #expect(ResearchMemory.candidate("优先核对数据泄漏", turn: second, state: reopened) == nil)
}

@Test func legacyMemoriesCaptureOnlyKnownOriginalsAndPreserveMathematicalDistinctions() throws {
    let first = ChatTurn(paperID: UUID(), question: "阈值怎么定？", selection: "", answer: "", evidence: [])
    let second = ChatTurn(paperID: first.paperID, question: "继续比较模型", selection: "", answer: "", evidence: [])
    var state = LibraryState()
    state.chats = [first, second]
    let original = "保留 p < 0.05 的分析。"
    var legacy = try #require(ResearchMemory.candidate(original, turn: first, state: state))
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    json["originalFingerprint"] = nil
    let old = try JSONDecoder().decode(MemoryItem.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.originalFingerprint == nil)
    legacy = old
    legacy.correct(to: "用户的修改")
    state.memories = [legacy]
    #expect(ResearchMemory.candidate(original, turn: second, state: state) == nil)
    #expect(ResearchMemory.candidate("保留 p > 0.05 的分析。", turn: second, state: state) != nil)
    legacy = old
    legacy.forget()
    #expect(legacy.text.isEmpty && legacy.originalFingerprint != nil)
    json["deleted"] = true
    json["text"] = ""
    let tombstone = try JSONDecoder().decode(MemoryItem.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(tombstone.originalFingerprint == nil)
    state.memories = [tombstone]
    #expect(ResearchMemory.candidate("独立的分析", turn: first, state: state) == nil)
    #expect(ResearchMemory.candidate("独立的分析", turn: second, state: state) != nil)
}

@Test func deletingSourcePaperRetainsOnlyAnonymousRejectedPropositionsAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let paper = Paper(
        title: "Deleted deliberations", digest: "old-source", originalPath: "old.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    var state = LibraryState()
    state.papers = [paper]
    for (index, wording) in ["只认可静态评测", "只关注吞吐量", "普通观察"].enumerated() {
        let turn = ChatTurn(
            paperID: paper.id, question: "private question \(index)", selection: "", answer: "", evidence: [])
        var item = try #require(ResearchMemory.candidate(wording, turn: turn, state: state))
        if index == 0 { item.correct(to: "同时考虑交互评测") }
        if index == 1 { item.forget() }
        state.chats.append(turn)
        state.memories.append(item)
    }
    try await store.save(state)
    let ids = [paper.id] + state.memories.map(\.id) + state.chats.map(\.id)
    try state.removePaper(paper.id)
    try await store.save(state, deleting: paper)
    let restored = try await LibraryStore(directory: root).load()
    #expect(restored.papers.isEmpty && restored.chats.isEmpty && restored.memories.isEmpty)
    #expect(restored.suppressedMemoryFingerprints.count == 2)
    let json = String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
    #expect(ids.allSatisfy { !json.contains($0.uuidString) })
    #expect(
        ["旧", paper.title, "private question", "只认可静态评测", "同时考虑交互评测", "只关注吞吐量", "普通观察"].allSatisfy {
            !json.contains($0)
        })
    let later = ChatTurn(paperID: UUID(), question: "换一篇论文再讨论", selection: "", answer: "", evidence: [])
    #expect(ResearchMemory.candidate("只认可静态评测。", turn: later, state: restored) == nil)
    #expect(ResearchMemory.candidate("只关注吞吐量", turn: later, state: restored) == nil)
    #expect(ResearchMemory.candidate("普通观察", turn: later, state: restored) != nil)
}

@Test func researchOverviewCountsReadingActivityWithoutDoubleCountingAPaper() throws {
    let paper = Paper(
        title: "Reading activity", digest: "d", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    let shelf = try Shelf(name: "Read")
    var state = LibraryState()
    state.papers = [paper]
    state.shelves = [shelf]
    state.paperShelfIDs[paper.id.uuidString] = shelf.id
    let first = Date(timeIntervalSinceReferenceDate: 100)
    let second = Date(timeIntervalSinceReferenceDate: 200)
    state.reading = [
        ReadingEntry(paperID: paper.id, start: first, end: first.addingTimeInterval(30)),
        ReadingEntry(paperID: paper.id, start: second, end: second.addingTimeInterval(60)),
    ]
    let overview = ResearchOverview(state: state)
    let topic = try #require(overview.topics.first { $0.shelf == "Read" })
    #expect(topic.papersRead == 1)
    #expect(topic.lastReadAt == second.addingTimeInterval(60))
}

@Test func memoryDedupKeyCanonicalizesCommonResearchPhrasingWithoutLosingNumbers() {
    let a = MemoryDedupKey.key("匹配训练算力后，方法 A 的准确率更高。")
    let b = MemoryDedupKey.key("在相同 compute budget 下，方法 A 的准确率更高。")
    #expect(a != b)  // 训练算力仍是条件的一部分，不能把两个不同实验问题合并
    #expect(MemoryDedupKey.key("匹配计算预算后，方法 A 的准确率更高。") == MemoryDedupKey.key("在相同 compute budget 下，方法 A 的准确率更高。"))
    #expect(MemoryDedupKey.key("提升 3.2 个点。") != MemoryDedupKey.key("提升 5.0 个点。"))
    #expect(MemoryDedupKey.key("没有提升。") != MemoryDedupKey.key("有提升。"))
    // Word-boundary safety: multi-character Chinese words must not be corrupted by particle stripping.
    #expect(MemoryDedupKey.key("上下文窗口长度") != MemoryDedupKey.key("上文窗口长度"))
    #expect(MemoryDedupKey.key("性能下降明显") != MemoryDedupKey.key("性能降明显"))
    #expect(MemoryDedupKey.key("不等式推导") != MemoryDedupKey.key("notequal式推导"))
    #expect(MemoryDedupKey.key("保留 p < 0.05") != MemoryDedupKey.key("保留 p > 0.05"))
}

@Test func deletedMemorySuppressesBilingualCanonicalParaphraseResurrection() throws {
    let first = ChatTurn(paperID: UUID(), question: "比较方法", selection: "", answer: "", evidence: [])
    let second = ChatTurn(paperID: first.paperID, question: "换个说法继续问", selection: "", answer: "", evidence: [])
    var state = LibraryState()
    state.chats = [first, second]
    var item = try #require(ResearchMemory.candidate("匹配计算预算后比较方法。", turn: first, state: state))
    let forgotten = item.forget()
    #expect(forgotten)
    state.memories = [item]
    #expect(ResearchMemory.candidate("在相同 compute budget 下比较方法。", turn: second, state: state) == nil)
    #expect(ResearchMemory.candidate("提升 5.0 个点。", turn: second, state: state) != nil)
}

@Test func memoryStatementProposalRejectsAParaphrasedActiveMemory() throws {
    let turn = ChatTurn(paperID: UUID(), question: "记住匹配预算的比较", selection: "", answer: "", evidence: [])
    var state = LibraryState()
    state.papers = [
        Paper(
            id: turn.paperID, title: "Budget", digest: "d", originalPath: "unused.pdf", pageCount: 1, blocks: [],
            warnings: [], canReflow: false)
    ]
    state.chats = [turn]
    let existing = MemoryItem(
        agentStatement: "匹配计算预算后比较方法。", sourceID: turn.id, source: .reader(quote: "记住匹配预算的比较"))
    state.memories = [existing]
    let proposal = try MemoryStatementProposal(
        statement: "在相同 compute budget 下比较方法。", readerTurnID: turn.id,
        readerMessage: turn.question, quote: "记住匹配预算的比较")
    #expect(!MemoryStatementProposal.isEligible(proposal.item, in: state, excluding: []))
}

@Test func researchMemoryFiltersPaperAndShelfScopeBeforeRankingTopResults() async throws {
    let targetShelf = try Shelf(name: "Target")
    let otherShelf = try Shelf(name: "Other")
    let targetPaper = Paper(
        title: "Target", digest: "target", originalPath: "target.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    let otherPaper = Paper(
        title: "Other", digest: "other", originalPath: "other.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    var state = LibraryState()
    state.papers = [targetPaper, otherPaper]
    state.shelves = [targetShelf, otherShelf]
    state.paperShelfIDs[targetPaper.id.uuidString] = targetShelf.id
    state.paperShelfIDs[otherPaper.id.uuidString] = otherShelf.id
    let target = MemoryItem(
        agentStatement: "预算", sourceID: targetPaper.id, source: .paper(paperID: targetPaper.id))
    let crowded = (0..<6).map { index in
        MemoryItem(
            agentStatement: "预算 预算 实验 对比 结论 \(index)", sourceID: otherPaper.id,
            source: .paper(paperID: otherPaper.id))
    }
    state.memories = [target] + crowded
    let index = ResearchMemory()
    let paperHits = try await index.relevant(
        to: "预算", paperID: targetPaper.id, scope: .paper(targetPaper.id), state: state)
    #expect(paperHits.map(\.id) == [target.id])
    let shelfHits = try await index.relevant(
        to: "预算", scope: .shelf(targetShelf.id), state: state)
    #expect(shelfHits.map(\.id) == [target.id])
    let libraryHits = try await index.relevant(to: "预算", scope: .library, state: state)
    #expect(libraryHits.count == 5)
}

@Test func bitemporalSupersedingExcludesObsoleteMemoriesAndInvalidatesSourceVersions() async throws {
    let paper = Paper(
        title: "Temporal", digest: "temp", originalPath: "unused.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    let turn = ChatTurn(paperID: paper.id, question: "预算实验", selection: "", answer: "", evidence: [])
    var old = MemoryItem(agentStatement: "优先比较吞吐量", sourceID: turn.id, source: .reader(quote: "优先比较吞吐量"))
    let newer = MemoryItem(
        agentStatement: "改为优先比较等算力下的准确率", sourceID: turn.id, source: .reader(quote: "改为优先比较等算力下的准确率"))
    let oldRevision = old.revisionFingerprint
    #expect(old.matchesRevision(oldRevision))
    #expect(old.matchesRevision(String(oldRevision.prefix(8))))
    #expect(!old.matchesRevision("deadbeef"))

    var versions = ChatSourceVersions()
    versions.include(old)
    var state = LibraryState()
    state.papers = [paper]
    state.chats = [turn]
    state.memories = [old, newer]
    #expect(versions.isCurrent(in: state, excluding: []))

    let superseded = old.supersede(by: newer.id, at: Date(timeIntervalSinceReferenceDate: 2_000))
    #expect(superseded)
    #expect(!old.isActive)
    #expect(old.supersededBy == newer.id)
    #expect(!old.matchesRevision(oldRevision))
    state.memories = [old, newer]
    #expect(!versions.isCurrent(in: state, excluding: []))

    let index = ResearchMemory()
    let hits = try await index.relevant(to: "比较", state: state)
    #expect(hits.map(\.id) == [newer.id])
    #expect(MemorySleepEdition.eligible(state).map(\.id) == [newer.id])

    // User-edited memories cannot be superseded automatically.
    var protected = newer
    let didEdit = protected.correct(to: "读者手改结论")
    let blockedSupersede = protected.supersede(by: UUID())
    #expect(didEdit)
    #expect(!blockedSupersede)
}

@Test func salienceDecayRanksFreshAndProtectedMemoriesAboveStaleAutomaticClues() async throws {
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    var stale = MemoryItem(agentStatement: "比较等算力蒸馏效果", sourceID: UUID(), source: .reader(quote: "比较等算力蒸馏效果"))
    stale.createdAt = now.addingTimeInterval(-180 * 86_400)
    var fresh = MemoryItem(agentStatement: "比较等算力蒸馏效果（新）", sourceID: UUID(), source: .reader(quote: "比较等算力蒸馏效果（新）"))
    fresh.createdAt = now.addingTimeInterval(-2 * 86_400)
    var edited = MemoryItem(agentStatement: "比较等算力蒸馏效果（手改）", sourceID: UUID(), source: .reader(quote: "比较等算力蒸馏效果（手改）"))
    edited.createdAt = now.addingTimeInterval(-240 * 86_400)
    let didEdit = edited.correct(to: "比较等算力蒸馏效果（手改）")
    #expect(didEdit)

    #expect(stale.salienceWeight(at: now) < 0.5)
    #expect(fresh.salienceWeight(at: now) > 0.9)
    #expect(edited.salienceWeight(at: now) == 1.0)

    var state = LibraryState()
    state.memories = [stale, fresh, edited]
    let hits = try await ResearchMemory().relevant(to: "等算力 蒸馏", state: state, now: now)
    #expect(hits.first?.id == edited.id)
    #expect(hits.last?.id == stale.id)
}
