import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

@Test func onlyExplicitPaperNoteRequestsGrantWritePermission() {
    let positive = [
        "帮我把这个想法记到论文对应的位置", "把刚才的观点记在对应原文旁",
        "请在论文里标出支持这个结论的原句，并写下我们的看法", "可以帮我把刚才这条记成笔记吗？",
        "把为什么会过拟合的讨论记在原文旁",
        "请把刚才的观点记为阅读笔记，并标画对应原文。", "在原文旁帮我记一条笔记",
        "帮我标画这句话并写个笔记。", "把这条推论记下来", "帮我记个笔记：这个结论为什么成立，还值得验证。",
        "请把刚才这条结论整理成笔记并标注原文。", "Please save this as a note.", "Write a reading note about our conclusion.",
    ]
    let negative = [
        "请在论文里不要把我的想法记下来", "把这段记下来需要多久", "请做笔记，但操作前先问我", "别记下来", "他建议我写笔记", "你会记笔记吗？", "可以帮我解释如何记笔记吗？",
        "如何将刚才讨论的观点记为阅读笔记？", "先别记笔记。", "不用实际保存，请先草拟一份笔记。", "写笔记和写总结有什么区别",
        "原文说“请将这项结论记为笔记”。这是什么意思？", "他说把这个词记下来", "请告诉我做笔记的步骤",
        "Explain what ‘save this as a note’ means.", "Don't write a note.", "如果需要，我会让你记笔记",
    ]
    for input in positive { #expect(ReadingNoteIntent.isRequested(input), "\(input)") }
    for input in negative { #expect(!ReadingNoteIntent.isRequested(input), "\(input)") }
}

@Test func onlyRequestedSourcePassagesAreTakenFromReaderQuotes() {
    #expect(
        ReadingNoteIntent.requestedQuotations(
            in: "请把观点“先看原文”记成笔记，在论文里标出 “A complete paragraph comes directly from the source.” 这句原文。") == [
                "A complete paragraph comes directly from the source."
            ])
    #expect(ReadingNoteIntent.requestedQuotations(in: "请标出“primary”，写笔记并引用另一篇里的“预算控制”。") == ["primary"])
    #expect(ReadingNoteIntent.requestedQuotations(in: "写笔记，引用本篇原文“primary”。") == ["primary"])
    #expect(ReadingNoteIntent.requestedQuotations(in: "标记“a”和“b”，笔记内容写“我们的看法”。") == ["a", "b"])
    #expect(ReadingNoteIntent.requestedQuotations(in: "请把「a」和「b」这两句高亮，再写笔记。") == ["a", "b"])
    #expect(ReadingNoteIntent.requestedQuotations(in: "把“看清边界条件”这一点记为笔记。").isEmpty)
    #expect(ReadingNoteIntent.requestedQuotations(in: "在原文中标记对应位置，写下“需要更多数据”。").isEmpty)
    #expect(ReadingNoteIntent.requestedQuotations(in: "请高亮相应原句并写笔记“需要更多数据”。").isEmpty)
}

@Test func noteContextRemapsEarlierCitationsAndExcludesOtherPapers() throws {
    let paper = UUID()
    let another = UUID()
    let alpha = Evidence(
        id: "S1", title: "Discussion", text: "The first verified observation.", paperID: paper, sourcePage: 0)
    let beta = Evidence(
        id: "S1", title: "Discussion", text: "The second verified observation.", paperID: paper, sourcePage: 2)
    let foreign = Evidence(
        id: "S2", title: "Private", text: "irrelevant foreign content", paperID: another, sourcePage: 1)
    let first = ChatTurn(paperID: paper, question: "先前的问题", selection: "", answer: "第一点 [S1]", evidence: [alpha])
    let second = ChatTurn(
        paperID: paper, question: "最近的问题", selection: "", answer: "第二点 [S1] 和 [S2]", evidence: [beta, foreign])
    let context = PaperDiscussionNote(paperID: paper, selection: [], history: [first, second], retrieved: [foreign])
    let payload = try #require(
        try JSONSerialization.jsonObject(with: Data(context.prompt(paper: "Discussion", instruction: "做笔记").utf8))
            as? [String: Any])
    let exchanges = try #require(payload["discussion"] as? [[String: Any]])
    #expect(exchanges.map { $0["sources"] as? [String] } == [["S2"], ["S1"]])
    #expect(context.evidence.map(\.text) == [beta.text, alpha.text])
    #expect(throws: ReaderError.self) {
        try context.parse(#"{"markdown":"测试","references":[{"source":"S20","quote":"invented"}]}"#)
    }
    #expect(throws: ReaderError.self) { try context.parse(#"{"markdown":"测试","references":[]}"#) }
    #expect(!PaperDiscussionNote.dialogue([first, second], paperID: paper).contains("[S1]"))
    var selected = alpha
    selected.text = "The first"
    let selectedContext = PaperDiscussionNote(paperID: paper, selection: [selected], history: [], retrieved: [alpha])
    #expect(selectedContext.evidence.map(\.text) == [selected.text, alpha.text])
}

private actor DiscussionTransport: HTTPTransport {
    private(set) var notePrompts: [String] = []
    private(set) var ordinaryPrompts: [String] = []
    let excerpt = "A word can need different evidence in different sentences."
    struct Request: Decodable {
        struct Message: Decodable { let content: String }
        let messages: [Message]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let messages = try JSONDecoder().decode(Request.self, from: request.httpBody ?? Data()).messages
        let isNote = messages.first?.content.contains("selectedSources") == true
        let content: String
        if isNote {
            let input = try #require(messages.last?.content)
            notePrompts.append(input)
            let body = try #require(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let passages = try #require(body["passages"] as? [[String: String]])
            let id = try #require(passages.first { $0["text"]?.contains(excerpt) == true }?["id"])
            var proposal: [String: Any] = [
                "markdown": "讨论观点：语境改变了检索所需的证据。", "references": [["source": id, "quote": excerpt]],
            ]
            if let note = (body["readingNotes"] as? [[String: String]])?.first,
                let noteID = note["id"], let text = note["text"]
            {
                proposal["markdown"] = "比较条件需要核对。{{cite:1}}"
                proposal["citations"] = [["source": noteID, "quote": text, "label": "先前的审读意见"]]
            }
            content = String(decoding: try JSONSerialization.data(withJSONObject: proposal), as: UTF8.self)
        } else {
            content = #"{"memory":"复查上下文示例"}"#
        }
        let object = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        return (
            try JSONSerialization.data(withJSONObject: object),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        let messages = try JSONDecoder().decode(Request.self, from: request.httpBody ?? Data()).messages
        let prompt = messages.last?.content ?? ""
        ordinaryPrompts.append(prompt)
        let noteID = prompt.firstMatch(of: /\[(S[0-9]+)\] [^\n]*书库阅读笔记/)?.1
        let answer = noteID.map { "先前笔记指出蓝鲸偏差需要控制 [\($0)]。" } ?? "语境改变了检索所需的证据 [S1]。"
        let event: [String: Any] = ["choices": [["delta": ["content": answer], "finish_reason": "stop"]]]
        let message = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        try await onData(Data(("data: " + message + "\n\ndata: [DONE]\n\n").utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func paperDiscussionMarksTheVerifiedEarlierPageAndOpensANormalPersistedNote() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = DiscussionTransport()
    let model = try ReaderModel(root: root, client: ModelClient(transport: api), credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    let file = root.appendingPathComponent("discuss.pdf")
    try AttentionFixture.write(to: file)
    let paperID = try #require(await model.importURLs([file]).first)
    model.recordVisiblePage(1)
    await model.ask("这里为什么需要不同证据？")
    await model.ask("这个结论如何理解？先不要记笔记。")
    #expect(model.state.readingNotes.isEmpty && model.state.highlights.isEmpty)
    #expect(await api.notePrompts.isEmpty)
    #expect(await api.ordinaryPrompts.last?.contains("这里为什么需要不同证据？") == true)
    model.recordVisiblePage(0)
    await model.ask("把刚才讨论的结论整理为一条阅读笔记。")
    let turn = try #require(model.currentChats.last)
    let note = try #require(model.currentReadingNotes.first)
    #expect(turn.readingNoteID == note.id)
    #expect(await api.notePrompts.count == 1)
    #expect(await api.notePrompts.first?.contains("这个结论如何理解") == true)
    #expect(note.anchors.first?.key == "original-1")
    #expect(!model.currentHighlights.isEmpty && model.currentHighlights.allSatisfy { $0.pageKey == "original-1" })
    #expect(note.markdown.contains("语境改变"))
    let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reopened.load()
    reopened.select(paperID)
    #expect(reopened.currentChats.last?.readingNoteID == note.id)
    reopened.openReadingNote(note)
    #expect(reopened.visiblePage == 1)
    reopened.deleteReadingNote(note.id)
    #expect(reopened.currentReadingNotes.isEmpty)
}

@Test @MainActor func paperDiscussionRecallsAndLinksAnotherPapersSavedNoteAndForgetsItsDeletedContents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = DiscussionTransport()
    let model = try ReaderModel(root: root, client: ModelClient(transport: api), credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    let file = root.appendingPathComponent("current.pdf")
    try AttentionFixture.write(to: file)
    let primary = try #require(await model.importURLs([file]).first)
    let otherRaw = "依照原文，这是本篇独有的未批注灰鲸事实。"
    let other = Paper(
        title: "先前读过的实验", digest: "comparison", originalPath: "comparison.pdf", pageCount: 2,
        blocks: [TextBlock(sourcePage: 0, text: otherRaw)], warnings: [], canReflow: false)
    try AttentionFixture.write(to: root.appendingPathComponent(other.originalPath))
    try #require(await model.save(adding: other))
    let anchor = NoteAnchor(key: "original-0", target: "pdf", text: "Attention", start: 0, end: 9)
    let observation = "排查混杂时，蓝鲸偏差要求固定推理预算。"
    let memory = ReadingNote(
        paperID: other.id, contentVersion: other.digest + ":original-0", anchors: [anchor], markdown: observation)
    _ = try await model.saveAnchoredDiscussionNote(memory, highlights: [])
    model.select(primary)
    model.recordVisiblePage(1)
    await model.ask("我在其他论文的笔记里是如何排查混杂的？")
    let answer = try #require(model.currentChats.last)
    let source = try #require(answer.evidence.first { $0.readingNoteID == memory.id })
    #expect(source.paperID == other.id && source.text == observation)
    #expect(answer.answer.contains("[\(source.id)]") && answer.evidence.contains { $0.paperID == primary })
    let prompt = try #require(await api.ordinaryPrompts.last)
    #expect(prompt.contains(observation) && !prompt.contains(otherRaw))
    #expect(!answer.evidence.contains { $0.paperID == other.id && $0.readingNoteID == nil })
    let interest = try #require(model.state.memories.first { $0.sourceID == answer.id })
    #expect(interest.text.contains(answer.question) && !interest.text.contains("蓝鲸偏差"))
    #expect(model.jump(to: source))
    #expect(model.selectedPaperID == other.id && model.requestedReadingNote == memory.id)
    model.select(primary)
    model.recordVisiblePage(1)
    await model.ask("请把刚才关于排查混杂的讨论整理成笔记，并引用之前的观点。")
    let note = try #require(model.currentReadingNotes.first)
    let link = try #require(note.citations?.first)
    #expect(link.readingNoteID == memory.id && note.markdown.contains(link.markdown(label: "先前的审读意见")))
    #expect(note.paperID == primary && note.anchors.first?.key == "original-1")
    let raw = try #require(await api.notePrompts.last)
    let payload = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let recalled = try #require(payload["readingNotes"] as? [[String: String]])
    let anchors = try #require(payload["passages"] as? [[String: String]])
    #expect(recalled.count == 1 && recalled[0]["id"] == "L1" && recalled[0]["text"] == observation)
    #expect(anchors.allSatisfy { $0["id"]?.hasPrefix("S") == true && $0["text"] != observation })
    #expect(!raw.contains(otherRaw))
    let verified = try await model.previewLocalPassage(noteID: note.id, citationID: link.id)
    #expect(verified.readingNoteID == memory.id && verified.noteMarkdown == observation)
    model.select(other.id)
    model.deleteReadingNote(memory.id)
    model.select(primary)
    #expect(!model.jump(to: source))
    await model.ask("还有什么与排查混杂相关的旧笔记？")
    let next = try #require(model.currentChats.last)
    #expect(!next.evidence.contains { $0.readingNoteID == memory.id })
    let freshPrompt = try #require(await api.ordinaryPrompts.last)
    #expect(!freshPrompt.contains("蓝鲸偏差") && !freshPrompt.contains(otherRaw))
}

@Test func historicalChatsWithoutReadingNoteLinksStillDecode() throws {
    let old = ChatTurn(paperID: UUID(), question: "Q", selection: "", answer: "A", evidence: [])
    let data = try JSONEncoder().encode(old)
    #expect(!String(decoding: data, as: UTF8.self).contains("readingNoteID"))
    #expect(try JSONDecoder().decode(ChatTurn.self, from: data).readingNoteID == nil)
}

@Test @MainActor func noteResultCardSummarizesOnlyTheFirstMarkdownLine() {
    let markdown = "### **阅读策略**\n\n后续正文只在展开时阅读。"
    #expect(ReadingNoteSummary.text(markdown) == "阅读策略")
    #expect(ReadingNoteSummary.text("- **重点**与[依据](https://example.com)") == "重点与依据")
    #expect(ReadingNoteSummary.text(String(repeating: "x", count: 1_000)).count == 80)
}

@Test func onlyExplicitWholePaperNotesGoToTheEndOfTheDocument() {
    for command in ["把全文总结成笔记", "写一份全文总结笔记", "write a summary note for the paper"] {
        #expect(ReadingNoteIntent.requestsDocumentSummary(command))
    }
    for command in ["总结全文", "把这句话整理成笔记", "写笔记：说明全文总结中遗漏的对照。", "请标记“论文总结”并写笔记。", "不要保存全文总结笔记"] {
        #expect(!ReadingNoteIntent.requestsDocumentSummary(command))
    }
}
