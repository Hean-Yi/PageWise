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
