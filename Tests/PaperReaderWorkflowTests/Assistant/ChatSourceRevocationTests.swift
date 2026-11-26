import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

private actor RevocationTransport: HTTPTransport {
    var prompts: [String] = []
    var notePrompts: [String] = []
    var memoryExtractionRequests = 0
    var pauseNext = false
    var paused: CheckedContinuation<Void, Never>?

    func holdNextAnswer() { pauseNext = true }
    func resume() {
        paused?.resume()
        paused = nil
    }

    private func prompt(_ request: URLRequest) throws -> (String, String) {
        let json = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let joined = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        return (messages.first?["content"] as? String ?? "", joined)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (system, user) = try prompt(request)
        let content: String
        if system.contains("selectedSources") {
            notePrompts.append(user)
            content = #"{"markdown":"没有可支持的标画","references":[]}"#
        } else {
            memoryExtractionRequests += 1
            content = #"{"memory":""}"#
        }
        let json = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        return (
            try JSONSerialization.data(withJSONObject: json),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        let (_, user) = try prompt(request)
        prompts.append(user)
        let answer: String
        if user.contains("CobaltMarker") {
            answer = "The CobaltMarker applies [S1]."
        } else if user.contains("读者明确表达的习惯") && user.contains("I prefer concise answers") {
            answer = "Brief finding [S1]."
        } else {
            answer = "Seen only in the text [S1]."
        }
        let msg = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": answer]]]])
        try await onData(Data(("data: " + String(decoding: msg, as: UTF8.self) + "\n\n").utf8))
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { paused = $0 }
        }
        try await onData(
            Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func revokedPersonalMemoryCannotReturnThroughDependentDialogueOrDiscussionNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = RevocationTransport()
    let reader = try ReaderModel(root: root, client: .init(transport: api), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    let file = root.appendingPathComponent("current.pdf")
    try AttentionFixture.write(to: file)
    let id = try #require(await reader.importURLs([file]).first)
    let origin = ChatTurn(paperID: id, question: "旧记录", selection: "", answer: "", evidence: [])
    let memory = MemoryItem(text: "budget CobaltMarker", sourceID: origin.id)
    reader.state.chats.append(origin)
    reader.state.memories.append(memory)
    await reader.ask("What about budget?")
    await reader.ask("请继续解释。")
    let before = await api.prompts
    #expect(before.count == 2 && before.allSatisfy { $0.contains("CobaltMarker") })
    reader.updateMemory(id: memory.id, text: "budget without that assumption")
    await reader.ask("请回顾所给依据。")
    await reader.ask("把刚才的讨论记为笔记。")
    #expect(await api.prompts.last?.contains("CobaltMarker") == false)
    #expect(await api.notePrompts.last?.contains("CobaltMarker") == false)

    // Retract a fresh source after the first token is visible and before the response finishes.
    reader.updateMemory(id: memory.id, text: "budget CobaltMarker")
    await api.holdNextAnswer()
    let task = Task { await reader.ask("budget for the proposed comparison?") }
    for _ in 0..<200 {
        if await api.paused != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await api.paused != nil)
    #expect(reader.currentAssistantDraft?.answer.contains("CobaltMarker") == true)
    reader.deleteMemory(memory.id)
    #expect(reader.currentAssistantDraft == nil)
    await api.resume()
    await task.value
    #expect(!reader.state.chats.contains { $0.question == "budget for the proposed comparison?" })
}

@Test func chatBackgroundChecksReferencesAfterRestartAndKeepsWithdrawnWordsOutOfItsRecord() throws {
    var state = LibraryState()
    let paper = Paper(
        title: "Prior", digest: "fixture", originalPath: "prior.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: false)
    let origin = ChatTurn(paperID: paper.id, question: "Q", selection: "", answer: "", evidence: [])
    let memory = MemoryItem(text: "CobaltMarker", sourceID: origin.id)
    let note = ReadingNote(paperID: paper.id, contentVersion: "fixture", anchors: [], markdown: "private note")
    state.papers = [paper]
    state.chats = [origin]
    state.memories = [memory]
    state.readingNotes = [note]
    var source = ChatSourceVersions()
    source.include(note)
    source.include(memory)
    let encoded = try JSONEncoder().encode(source)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("CobaltMarker"))
    let decoded = try JSONDecoder().decode(ChatSourceVersions.self, from: encoded)
    #expect(decoded.isCurrent(in: state, excluding: []))
    #expect(!decoded.isCurrent(in: state, excluding: [paper.id]))
    state.readingNotes[0].modifiedAt.addTimeInterval(1)
    #expect(!decoded.isCurrent(in: state, excluding: []))
    state.readingNotes = [note]
    state.chats.removeAll()
    #expect(!decoded.isCurrent(in: state, excluding: []))
}

@Test func legacyLinkedAgentNotesRequireVerifiableOriginalsAndKeepUnlinkedHumanNotesSearchable() async throws {
    let paper = Paper(
        title: "Fixture", digest: "abc", originalPath: "file.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    let observed = ReadingNote(paperID: paper.id, contentVersion: "one", anchors: [], markdown: "同预算重复测量。")
    var linked = ReadingNote(paperID: paper.id, contentVersion: "one", anchors: [], markdown: "有可定位的对照。")
    linked.citations = [.init(note: observed, digest: paper.digest, quote: observed.markdown)]
    var indirect = ReadingNote(paperID: paper.id, contentVersion: "one", anchors: [], markdown: "第二次讨论。")
    indirect.citations = [.init(note: linked, digest: paper.digest, quote: linked.markdown)]
    let unknown = ReadingNote(paperID: paper.id, contentVersion: "one", anchors: [], markdown: "来源未知。")
    var report = ChatTurn(paperID: paper.id, question: "精读", selection: "", answer: "", evidence: [])
    report.backgroundSources = nil
    report.readingNoteID = unknown.id
    report.closeReadingNoteIDs = [linked.id, indirect.id]
    var state = LibraryState()
    state.papers = [paper]
    state.chats = [report]
    state.readingNotes = [observed, linked, indirect, unknown]
    let index = ReadingNoteMemoryIndex()
    let hits = try await index.search(
        query: "", state: state, pending: [], excluding: nil, paperID: nil, limit: 8, includeArchived: false)
    #expect(Set(hits.compactMap(\.readingNoteID)) == [observed.id, linked.id, indirect.id])
    let versions = try #require(ChatSourceVersions.recalledNote(indirect, in: state, excluding: [])?.backgroundSources)
    state.readingNotes[0].modifiedAt.addTimeInterval(2)
    #expect(!versions.isCurrent(in: state, excluding: []))
    let fresh = try await index.search(
        query: "", state: state, pending: [], excluding: nil, paperID: nil, limit: 8, includeArchived: false)
    #expect(fresh.compactMap(\.readingNoteID) == [observed.id])
    #expect(
        try await index.search(
            query: "", state: state, pending: [], excluding: nil, paperID: nil, limit: 8, includeArchived: true
        ).count == 4)
}

@Test @MainActor func paperQuestionWithExplicitNoMemorySkipsExtractionAndRejectsTheWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = RevocationTransport()
    let reader = try ReaderModel(root: root, client: .init(transport: api), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    let file = root.appendingPathComponent("current.pdf")
    try AttentionFixture.write(to: file)
    _ = try #require(await reader.importURLs([file]).first)
    let question = "Calibration still looks promising to me. Don't remember this. What does the passage measure?"
    await reader.ask(question)
    #expect(await api.prompts.count == 1)
    #expect(await api.memoryExtractionRequests == 0)
    let turn = try #require(reader.state.chats.last)
    #expect(turn.question == question && !turn.answer.isEmpty)
    #expect(ResearchMemory.candidate("Tracks calibration", turn: turn, state: reader.state) == nil)
    #expect(reader.state.memories.isEmpty)
}

@Test @MainActor func readerPreferenceLibraryToPaperHonorsTemporaryOverrideAndRestoresDefault() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = RevocationTransport()
    let reader = try ReaderModel(root: root, client: .init(transport: api), credentials: WorkflowCredentials())
    await reader.load()
    var settings = reader.modelSettings
    settings.model = "fixture"
    try reader.saveSettings(settings, key: nil)
    let file = root.appendingPathComponent("current.pdf")
    try AttentionFixture.write(to: file)
    let paperID = try #require(await reader.importURLs([file]).first)
    let agent = LibraryAgent(reader: reader)
    agent.send("I prefer concise answers.")
    for _ in 0..<150 where agent.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    #expect(agent.turns.last?.answer == "已记住这条偏好。")
    let item = try #require(reader.state.memories.first)

    await reader.ask("What is measured?")
    let regular = try #require(reader.state.chats.last)
    #expect(regular.answer == "Brief finding [S1]." && regular.suppliedPreferenceIDs == [item.id])
    await reader.ask("这次详细解释，同一个实验测量了什么？")
    let temporary = try #require(reader.state.chats.last)
    #expect(temporary.answer == "Seen only in the text [S1]." && temporary.suppliedPreferenceIDs == [])
    #expect(temporary.evidence.first?.paperID == paperID && regular.evidence.first?.paperID == paperID)
    await reader.ask("What is the comparison?")
    #expect(reader.state.chats.last?.suppliedPreferenceIDs == [item.id])
    #expect(reader.state.chats.last?.answer == regular.answer)
    #expect(await api.memoryExtractionRequests == 0)
}

@Test @MainActor func readerPreferenceBothAssistantsSendTheSleepEditionAndImmediatelyHonorWithdrawal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = RevocationTransport()
    let reader = try ReaderModel(root: root, client: .init(transport: transport), credentials: WorkflowCredentials())
    await reader.load()
    var config = reader.modelSettings
    config.model = "fixture"
    _ = try reader.saveSettings(config, key: nil)
    let file = root.appendingPathComponent("current.pdf")
    try AttentionFixture.write(to: file)
    _ = try #require(await reader.importURLs([file]).first)
    func question(_ text: String) throws -> MemoryItem {
        try ResearchQuestionProposal(question: text, readerTurnID: UUID(), readerMessage: text, quote: text).item
    }
    let a = try question("训练预算相同时优势还存在吗？")
    let b = try question("匹配训练预算能否改变排名？")
    let summary = "预算核对涉及训练时长和样本量两项条件。"
    reader.state.memories = [a, b]
    await reader.save()
    let client = ScriptedLibraryModel { _, _ in .init(role: "assistant", content: "已核对。") }
    let agent = LibraryAgent(reader: reader, client: client)
    agent.send("训练预算需要核对哪些条件？")
    for _ in 0..<200 where agent.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    let unmerged = try #require(await client.requests.last?.last?.content)
    #expect(unmerged.contains("训练预算相同时优势还存在吗") && !unmerged.contains(summary))
    let sleepStore = MemorySleepStore(store: reader.store)
    _ = try await sleepStore.run { _ in
        #"{"groups":[{"kind":"related","members":["\#(a.id)","\#(b.id)"],"summary":"\#(summary)"}]}"#
    }
    await reader.memorySleep.restore()
    func sendBoth() async throws -> [String] {
        await reader.ask("训练预算需要核对哪些条件？")
        agent.send("训练预算需要核对哪些条件？")
        for _ in 0..<200 where agent.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        return [try #require(await transport.prompts.last), try #require(await client.requests.last?.last?.content)]
    }
    let before = try await sendBoth()
    for request in before {
        #expect(request.contains(summary))
        #expect(!request.contains("训练预算相同时优势还存在吗"))
        #expect(!request.contains("匹配训练预算能否改变排名"))
    }
    reader.deleteMemory(a.id)
    for request in try await sendBoth() { #expect(!request.contains(summary)) }
}

/// Only the generated mini-study below and synthetic language preferences enter the configured model.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_PREFERENCE_LIVE"] == "1"))
@MainActor func liveReaderPreferencePreservesNumericalEvidenceAcrossLanguageAndTemporaryOverride() async throws {
    let key = try #require(ProcessInfo.processInfo.environment["PAGEWISE_TEST_PREFERENCE_KEY"])
    let prompt = "Which two accuracy percentages did the trial report? Include both numbers and a citation."
    for (preference, temporary, chinese) in [
        ("以后默认用中文回答。", "", true),
        ("以后默认用英文回答。", "", false),
        ("以后默认用中文回答。", "这次用英文回答。", false),
    ] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        var config = ModelSettings()
        config.baseURL = "https://api.deepseek.com"
        config.model = "deepseek-flash"
        _ = try reader.saveSettings(config, key: key)
        let paper = Paper(
            title: "Synthetic equal-time comparison", digest: "synthetic", originalPath: "fixture.pdf", pageCount: 1,
            blocks: [
                TextBlock(
                    sourcePage: 0,
                    text:
                        "Both groups ran for one hour. The accuracy was 61% for A and 74% for B. The sample counts were not reported."
                )
            ],
            warnings: [], canReflow: true)
        reader.state.papers = [paper]
        reader.select(paper.id)
        let agent = LibraryAgent(reader: reader)
        agent.send(preference)
        for _ in 0..<200 where agent.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try #require(reader.state.memories.contains(where: { $0.isResponsePreference && !$0.deleted }))
        await reader.ask(temporary + prompt)
        let turn = try #require(reader.state.chats.last)
        #expect(turn.question == temporary + prompt)
        #expect(turn.answer.contains("61") && turn.answer.contains("74") && turn.answer.contains("[S1]"))
        #expect((turn.answer.range(of: #"\p{Han}"#, options: .regularExpression) != nil) == chinese)
        print(
            "LIVE_PREFERENCE_PROFILE", chinese ? "Chinese" : "English", temporary.isEmpty ? "default" : "override",
            turn.answer)
    }
}
