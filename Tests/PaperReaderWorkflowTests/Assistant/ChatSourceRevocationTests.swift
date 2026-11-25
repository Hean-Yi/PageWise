import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

private actor RevocationTransport: HTTPTransport {
    var prompts: [String] = []
    var notePrompts: [String] = []
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
        return (messages.first?["content"] as? String ?? "", messages.last?["content"] as? String ?? "")
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (system, user) = try prompt(request)
        let content: String
        if system.contains("selectedSources") {
            notePrompts.append(user)
            content = #"{"markdown":"没有可支持的标画","references":[]}"#
        } else {
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
        let answer = user.contains("CobaltMarker") ? "The CobaltMarker applies [S1]." : "Seen only in the text [S1]."
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
