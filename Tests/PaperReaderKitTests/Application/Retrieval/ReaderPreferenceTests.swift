import Foundation
import Testing

@testable import PaperReaderKit

@Test func readerPreferenceScopesAreDistinctAndLegacyItemsRemainUnclassified() throws {
    var state = LibraryState()
    var legacy = MemoryItem(text: "我喜欢短回答", sourceID: UUID())
    legacy.correct(to: "User corrected a legacy hypothesis")
    state.memories = [legacy]
    let data = try JSONEncoder().encode(state)
    var representation = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    representation["version"] = 14
    let migrated = try JSONDecoder().decode(
        LibraryState.self, from: JSONSerialization.data(withJSONObject: representation))
    #expect(migrated.version == LibraryState.currentVersion)
    #expect(migrated.memories == [legacy])
    #expect(ReaderPreference.active(in: migrated, paperID: nil, shelfID: nil).isEmpty)
    let shelf = try Shelf(name: "Methods")
    state.shelves = [shelf]
    let text = "在这个书架默认先讲结论"
    let metadata = try #require(ReaderPreference.classify(text, paperID: nil, shelfID: shelf.id))
    let item = MemoryItem(preference: metadata, statement: text, sourceID: UUID(), libraryTurn: true)
    let change = ReaderPreferenceChange(previous: [], insertions: [item])
    #expect(change.apply(to: &state))
    #expect(ReaderPreference.active(in: state, paperID: nil, shelfID: shelf.id) == [item])
    #expect(ReaderPreference.active(in: state, paperID: nil, shelfID: UUID()).isEmpty)
    #expect(!change.apply(to: &state))
    let position = try #require(state.memories.firstIndex { $0.id == item.id })
    state.memories[position].correct(to: "短标题优先")
    #expect(state.memories[position].preference?.aspect == .structure)
}

@Test func readerPreferenceStatementsRespectTemporaryRequestsQuotationAndCreditedRoles() {
    #expect(ReaderPreference.statement(in: "以后先讲结论。") != nil)
    #expect(ReaderPreference.statement(in: "I prefer concise answers.") != nil)
    #expect(ReaderPreference.declaredClauses(in: "以后先讲结论。解释一下方差？") == ["以后先讲结论"])
    for text in [
        "这次详细推导。", "作者说：以后先讲结论。", "For example: I prefer concise answers.",
        "以后别记这些偏好。", "以后帮我下载论文。", "以后请保存我的 API key",
        "以后可不可以先讲结论？",
    ] {
        #expect(ReaderPreference.statement(in: text) == nil)
        #expect(ReaderPreference.declaredClauses(in: text).isEmpty)
    }
}

@Test func readerPreferenceUsesApplicableExperimentConditionAndRejectsUnrelatedQuestions() throws {
    let statement = "以后看实验，先说对照是否公平"
    #expect(try #require(ReaderPreference.classify(statement, paperID: nil, shelfID: nil)).conditional)
    #expect(ReaderPreference.conditionMatches(statement, query: "这张表说明什么？"))
    #expect(!ReaderPreference.conditionMatches(statement, query: "帮我翻译这句话"))
    #expect(!ReaderPreference.permitsRecall("这次别用我的记忆，看看原文怎么说。"))
    #expect(ReaderPreference.temporaryOverrides(in: "这次做组会，给英文一句话。") == [.language, .detail])
    #expect(!ReaderPreference.isReview("What are my research questions?"))
    let compound = "以后默认用中文，术语保留英文。"
    let components = try #require(ReaderPreference.classify(compound, paperID: nil, shelfID: nil)).components(
        of: compound)
    #expect(components.map { $0.0.aspect } == [.language, .terminology])
    #expect(components.map { $0.1 } == ["以后默认用中文", "术语保留英文。"])
}

@Test func noteDeferralKeepsConversationAvailableWithoutOverridingAnExplicitNonRetentionRequest() {
    let noteOnly = "这个结论如何理解？先不要记笔记。"
    #expect(!ResearchMemory.permitsAutomaticWrite(for: noteOnly))
    #expect(ResearchMemory.permitsConversationHistory(for: noteOnly))
    #expect(ResearchMemory.permitsConversationHistory(for: "Explain the result. Don't save a note yet."))
    for text in ["这段别记。", "先不要记笔记，也不要保存这段讨论。", "不要保存笔记里的私人信息。", "Don't save a note. Off the record."] {
        #expect(!ResearchMemory.permitsConversationHistory(for: text))
    }
}

@Test func chatSourcedPreferenceRequiresAPersistedOriginatingTurn() throws {
    var state = LibraryState()
    let text = "以后默认用中文回答。"
    let metadata = try #require(ReaderPreference.classify(text, paperID: nil, shelfID: nil))
    let sourceID = UUID()
    let item = MemoryItem(preference: metadata, statement: text, sourceID: sourceID, libraryTurn: false)
    let change = ReaderPreferenceChange(previous: [], insertions: [item])
    #expect(!change.apply(to: &state))

    let paper = Paper(
        title: "Preference source", digest: "preference", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    var turn = ChatTurn(paperID: paper.id, question: text, selection: "", answer: "", evidence: [])
    turn.id = sourceID
    state.papers = [paper]
    state.chats = [turn]
    #expect(change.apply(to: &state))
    #expect(state.memories.contains { $0.id == item.id })
}
