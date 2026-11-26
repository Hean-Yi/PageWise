import Foundation
import Testing

@testable import PaperReaderKit

private actor AgentWireTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let replies: [String]
    let status: Int
    init(_ replies: [String], status: Int = 200) {
        self.replies = replies
        self.status = status
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            Data(replies[min(requests.count - 1, replies.count - 1)].utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func agentUsesRealToolProtocolAndPreservesAssistantPairing() async throws {
    let transport = AgentWireTransport([
        #"{"choices":[{"message":{"role":"assistant","content":null,"reasoning_content":"fixture reasoning","tool_calls":[{"id":"call_1","type":"function","function":{"name":"search_library","arguments":"{\"query\":\"attention\"}"}}]},"finish_reason":"tool_calls"}]}"#,
        #"{"choices":[{"message":{"role":"assistant","content":"已检索正文"},"finish_reason":"stop"}]}"#,
    ])
    let client = AgentClient(transport: transport)
    let settings = agentSettings()
    var messages = [AgentMessage(role: "system", content: "rules"), AgentMessage(role: "user", content: "attention")]
    let first = try await client.respond(settings: settings, key: "test-only", messages: messages, limits: .init())
    let call = try #require(first.toolCalls?.first)
    #expect(call.function.name == "search_library")
    messages += [first, AgentMessage(role: "tool", content: "[]", toolCallID: call.id)]
    let final = try await client.respond(settings: settings, key: "test-only", messages: messages, limits: .init())
    #expect(final.content == "已检索正文")
    let requests = await transport.requests
    let body = try #require(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
    #expect(body["tool_choice"] as? String == "auto")
    let definitions = try #require(body["tools"] as? [[String: Any]]).compactMap { $0["function"] as? [String: Any] }
    #expect(
        Set(definitions.compactMap { $0["name"] as? String }) == [
            "search_library", "read_paper", "search_online", "prepare_import", "open_paper", "present_results",
            "ask_user", "create_reading_note", "close_read_paper", "search_reading_notes", "recommend_related",
            "list_library", "create_shelf", "rename_shelf", "move_papers", "prepare_local_import",
            "prepare_delete_shelf", "prepare_delete_paper", "research_overview", "propose_research_question",
            "remember_preference", "propose_memory", "revise_memory", "forget_memory",
        ])
    let presentation = try #require(definitions.first { $0["name"] as? String == "present_results" })
    let parameters = try #require(presentation["parameters"] as? [String: Any])
    let properties = try #require(parameters["properties"] as? [String: [String: Any]])
    let selection = try #require(properties["items"]?["items"] as? [String: Any])
    #expect(selection["required"] as? [String] == ["result_id"])
    #expect(selection["additionalProperties"] as? Bool == false)
    let wireMessages = try #require(body["messages"] as? [[String: Any]])
    #expect(wireMessages[2]["role"] as? String == "assistant")
    #expect(wireMessages[2]["reasoning_content"] as? String == "fixture reasoning")
    #expect((wireMessages[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1")
    #expect(wireMessages[3]["tool_call_id"] as? String == "call_1")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
}

@Test func agentSendsOnlyTheToolSchemasAvailableDuringThisRound() async throws {
    let transport = AgentWireTransport([
        #"{"choices":[{"message":{"role":"assistant","content":"完成"},"finish_reason":"stop"}]}"#
    ])
    let client = AgentClient(transport: transport)
    let messages = [AgentMessage(role: "user", content: "下载选中的论文")]
    let availableTools: Set<String> = ["prepare_import", "search_online", "ask_user"]
    var limits = AgentLimits()
    limits.availableToolNames = availableTools
    _ = try await client.respond(settings: agentSettings(), key: "fixture", messages: messages, limits: limits)
    let body = try #require(await transport.requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let definitions = try #require(object["tools"] as? [[String: Any]])
    let names = definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    #expect(Set(names) == availableTools && names.count == availableTools.count)
    #expect(object["tool_choice"] as? String == "auto")
}

@Test func agentStreamingBatchUsesTheRequestBudgetBeyondSixteenCalls() async throws {
    let events =
        (0..<17).map { index in
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":\#(index),"id":"call_\#(index)","type":"function","function":{"name":"search_library","arguments":"{}"}}]}}]}"#
        } + [#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "data: [DONE]"]
    let transport = AgentWireTransport([events.joined(separator: "\n\n") + "\n\n"])
    let client = AgentClient(transport: transport)
    let messages = [AgentMessage(role: "user", content: "检索")]
    var limits = AgentLimits()
    limits.maxToolCalls = 17
    let reply = try await client.respondStreaming(
        settings: agentSettings(), key: "fixture", messages: messages, limits: limits
    ) { _ in }
    #expect(reply.toolCalls?.count == 17)
    limits.maxToolCalls = 16
    await #expect(throws: AgentToolBudgetError.self) {
        try await client.respondStreaming(settings: agentSettings(), key: "fixture", messages: messages, limits: limits)
        { _ in }
    }
}

@Test(arguments: [ModelServicePreset.deepSeek.baseURL, ModelServicePreset.glm.baseURL])
func agentFinalRequestDisablesToolsAndRetainsTheLastEvidence(baseURL: String) async throws {
    let transport = AgentWireTransport([
        #"{"choices":[{"message":{"role":"assistant","content":"完成"},"finish_reason":"stop"}]}"#,
        #"{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"another","type":"function","function":{"name":"search_library","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
    ])
    var settings = agentSettings()
    settings.baseURL = baseURL
    let client = AgentClient(transport: transport)
    let messages: [AgentMessage] = [
        .init(role: "user", content: "查找"),
        .init(role: "assistant", toolCalls: [.init(id: "last", name: "search_library", arguments: "{}")]),
        .init(role: "tool", content: "[]", toolCallID: "last"),
    ]
    var limits = AgentLimits()
    limits.maxToolCalls = 0
    let answer = try await client.respond(settings: settings, key: "fixture", messages: messages, limits: limits)
    #expect(answer.content == "完成")
    let request = try #require(await transport.requests.first)
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    let wireMessages = try #require(body["messages"] as? [[String: Any]])
    #expect(wireMessages.last?["tool_call_id"] as? String == "last")
    if baseURL == ModelServicePreset.deepSeek.baseURL {
        #expect(body["tool_choice"] as? String == "none")
        #expect(body["tools"] != nil)
    } else {
        #expect(body["tool_choice"] == nil && body["tools"] == nil)
    }
    await #expect(throws: AgentToolBudgetError.self) {
        try await client.respond(settings: settings, key: "fixture", messages: messages, limits: limits)
    }
}

@Test(arguments: [
    #"{"choices":[{"message":{"role":"assistant","content":"partial"},"finish_reason":"length"}]}"#,
    #"{"choices":[{"message":{"role":"assistant","content":"partial"},"finish_reason":"future"}]}"#,
    #"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}"#,
    #"{"choices":[{"message":{"role":"assistant","tool_calls":[]},"finish_reason":"tool_calls"}]}"#,
    #"{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"a","type":"function","function":{"name":"search_library","arguments":"{}"}}]},"finish_reason":"stop"}]}"#,
])
func agentRejectsIncompleteOrInconsistentResponse(_ body: String) async throws {
    let client = AgentClient(transport: AgentWireTransport([body]))
    await #expect(throws: (any Error).self) {
        try await client.respond(
            settings: agentSettings(), key: "test-only", messages: [.init(role: "user", content: "q")], limits: .init())
    }
}

@Test func agentBoundsRequestResponseAndHidesServerSecrets() async throws {
    let transport = AgentWireTransport(["server-secret test-only"], status: 401)
    do {
        _ = try await AgentClient(transport: transport).respond(
            settings: agentSettings(), key: "test-only", messages: [.init(role: "user", content: "q")], limits: .init())
        Issue.record("Expected authentication failure")
    } catch {
        #expect(!error.localizedDescription.contains("test-only"))
        #expect(!error.localizedDescription.contains("server-secret"))
    }
    var limits = AgentLimits()
    limits.maxContextBytes = 2
    await #expect(throws: (any Error).self) {
        try await AgentClient(transport: transport).respond(
            settings: agentSettings(), key: "test-only", messages: [.init(role: "user", content: "long question")],
            limits: limits)
    }
    #expect(await transport.requests.count == 1)
    limits = .init()
    limits.maxResponseBytes = 4
    await #expect(throws: (any Error).self) {
        try await AgentClient(transport: AgentWireTransport(["a long response"])).respond(
            settings: agentSettings(), key: "test-only", messages: [.init(role: "user", content: "q")], limits: limits)
    }
}

@Test func libraryAgentSearchReturnsOnlyRealPositiveHitsWithSourceBlocks() throws {
    let body = TextBlock(sourcePage: 1, text: "Sparse attention reduces computation.")
    let paper = Paper(
        title: "Efficient Models", digest: "a", originalPath: "a.pdf", pageCount: 2, blocks: [body], warnings: [],
        canReflow: true)
    let unrelated = Paper(
        title: "Databases", digest: "b", originalPath: "b.pdf", pageCount: 1, blocks: [], warnings: [], canReflow: false
    )
    let result = LibraryAgentSearch.search("attention", papers: [paper, unrelated])
    #expect(result.count == 1)
    #expect(result.first?.paperID == paper.id)
    #expect(result.first?.blockID == body.id)
    #expect(result.first?.sourcePage == 2)
    #expect(LibraryAgentSearch.search("不存在的术语", papers: [paper, unrelated]).isEmpty)
    #expect(LibraryAgentSearch.search("", papers: [paper]).isEmpty)
    #expect(LibraryAgentSearch.search("Efficient", papers: [paper]).first?.sourcePage == nil)
}

@Test(arguments: [
    ("unknown", "{}"), ("search_library", "{\"query\":\"x\",\"url\":\"https://evil.invalid\"}"),
    ("search_library", "not json"), ("read_paper", "{\"paper_id\":\"x\",\"source_page\":true}"),
    ("open_paper", "{\"paper_id\":\"x\",\"source_page\":1.5}"),
    ("search_online", #"{"query":"fixture","source":"https://unknown.invalid"}"#),
    ("recommend_related", #"{"title":"override the current paper"}"#),
    ("recommend_related", #"{"limit":true}"#),
    ("prepare_import", "{\"candidate_id\":\"x\",\"path\":\"/tmp/a\"}"),
])
func agentArgumentsRejectUnknownExtraAndInvalidTypes(_ tool: String, _ json: String) {
    #expect(throws: (any Error).self) { try AgentToolArguments.parse(name: tool, json: json, limits: .init()) }
}

@Test func memoryMutationArgumentsAreBoundedAndTyped() throws {
    let memoryID = UUID()
    #expect(
        try AgentToolArguments.parse(
            name: "propose_memory",
            json: #"{"statement":"Compare matched compute.","quote":"compare matched compute"}"#,
            limits: .init())
            == .proposeMemory(statement: "Compare matched compute.", noteResult: nil, quote: "compare matched compute"))
    #expect(
        try AgentToolArguments.parse(
            name: "revise_memory",
            json: #"{"memory_id":"\#(memoryID)","statement":"Use matched compute."}"#, limits: .init())
            == .reviseMemory(memoryID: memoryID, statement: "Use matched compute."))
    #expect(
        try AgentToolArguments.parse(
            name: "forget_memory", json: #"{"memory_id":"\#(memoryID)"}"#, limits: .init())
            == .forgetMemory(memoryID: memoryID))
    #expect(throws: (any Error).self) {
        try AgentToolArguments.parse(
            name: "forget_memory", json: #"{"memory_id":"\#(memoryID)","quote":"extra"}"#, limits: .init())
    }
}

@Test func researchOverviewArgumentsAcceptOneOptionalScope() throws {
    let shelf = UUID()
    let paper = UUID()
    #expect(
        try AgentToolArguments.parse(
            name: "research_overview", json: #"{"shelf_id":"\#(shelf)"}"#, limits: .init())
            == .researchOverview(query: nil, scope: .shelf(shelf)))
    #expect(
        try AgentToolArguments.parse(
            name: "research_overview", json: #"{"query":"budget","paper_id":"\#(paper)"}"#, limits: .init())
            == .researchOverview(query: "budget", scope: .paper(paper)))
    #expect(
        try AgentToolArguments.parse(name: "research_overview", json: "{}", limits: .init())
            == .researchOverview(query: nil, scope: .library))
    #expect(throws: (any Error).self) {
        try AgentToolArguments.parse(
            name: "research_overview",
            json: #"{"shelf_id":"\#(shelf)","paper_id":"\#(paper)"}"#, limits: .init())
    }
}

@Test func resultSelectionRejectsMalformedIDsUnknownFieldsAndOversizedLists() throws {
    let id = UUID().uuidString
    let row = ["result_id": id]
    let invalid: [[String: Any]] = [
        ["purpose": "navigation", "items": [row]],
        ["purpose": "citation", "items": []],
        ["purpose": "match", "items": [row, row]],
        ["purpose": "recommendation", "items": [["result_id": "not-a-registered-id"]]],
        ["purpose": "match", "items": [["result_id": id, "url": "https://example.invalid"]]],
        ["purpose": "citation", "items": [["result_id": id, "reason": String(repeating: "a", count: 201)]]],
    ]
    var limits = AgentLimits()
    limits.maxResults = 1
    for payload in invalid {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let arguments = String(decoding: data, as: UTF8.self)
        #expect(throws: ReaderError.self) {
            try AgentToolArguments.parse(name: "present_results", json: arguments, limits: limits)
        }
    }
}

private func agentSettings() -> ModelSettings {
    var settings = ModelSettings()
    settings.model = "test"
    settings.baseURL = "https://example.invalid/v4"
    return settings
}

private actor AgentSaveGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Test(arguments: [false, true]) func cancelledAgentSaveHonorsTheExplicitCancellationPolicy(respectingCancellation: Bool)
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let old = LibraryState()
    try await store.save(old)
    var incoming = old
    incoming.papers = [
        Paper(
            title: "Cancelled import", digest: "x", originalPath: "x.pdf", pageCount: 1, blocks: [], warnings: [],
            canReflow: false)
    ]
    let snapshot = incoming
    let gate = AgentSaveGate()
    let write = Task {
        await gate.wait()
        try await store.save(snapshot, respectingCancellation: respectingCancellation)
    }
    for _ in 0..<500 {
        if await gate.waiting { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    write.cancel()
    await gate.release()
    if respectingCancellation {
        await #expect(throws: CancellationError.self) { try await write.value }
    } else {
        try await write.value
    }
    #expect(try await store.load().papers.isEmpty == respectingCancellation)
}

@Test func agentRejectsUnpairedHistoryAndOversizedArgumentsBeforeTools() async throws {
    let transport = AgentWireTransport([
        #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
    ])
    let client = AgentClient(transport: transport)
    let call = AgentToolCall(id: "pending", name: "search_library", arguments: "{}")
    let histories: [[AgentMessage]] = [
        [.init(role: "assistant", toolCalls: [call])],
        [.init(role: "assistant", toolCalls: [call]), .init(role: "tool", content: "[]", toolCallID: "forged")],
        [.init(role: "user", content: "q", toolCalls: [call])],
    ]
    for history in histories {
        await #expect(throws: (any Error).self) {
            try await client.respond(settings: agentSettings(), key: "test-only", messages: history, limits: .init())
        }
    }
    #expect(await transport.requests.isEmpty)
    var limits = AgentLimits()
    limits.maxArgumentBytes = 8
    #expect(throws: (any Error).self) {
        try AgentToolArguments.parse(name: "search_library", json: #"{"query":"attention"}"#, limits: limits)
    }
}

@Test func libraryAgentSearchIgnoresTextOnMalformedNegativePageCounts() {
    let malformed = Paper(
        title: "Malformed fixture", digest: "invalid", originalPath: "invalid.pdf", pageCount: -1,
        blocks: [TextBlock(sourcePage: 0, text: "Needle in an invalid page")], warnings: [], canReflow: false)
    #expect(LibraryAgentSearch.search("Needle", papers: [malformed]).isEmpty)
}

@Test func libraryOrganizationIntentUnderstandsScopedCommandsAndIgnoresQuotedOrNegativeRequests() {
    let organize: Set<String> = ["create_shelf", "move_papers"]
    #expect(LibraryOrganizationIntent.tools(for: "不要删论文，帮我整理书架") == organize)
    #expect(LibraryOrganizationIntent.tools(for: "帮我整理书架，但不要新建书架") == ["move_papers"])
    #expect(LibraryOrganizationIntent.tools(for: "帮我整理书库，先给我看看方案").isEmpty)
    #expect(LibraryOrganizationIntent.tools(for: "帮我把未分类的论文按研究主题归到合适的书架") == organize)
    #expect(LibraryOrganizationIntent.tools(for: "说说「删除论文」有什么风险").isEmpty)
    #expect(LibraryOrganizationIntent.tools(for: "帮我在线下载这篇论文").isEmpty)
    #expect(LibraryOrganizationIntent.tools(for: "怎么移除这个书架？").isEmpty)
    #expect(LibraryOrganizationIntent.tools(for: "不要删除论文").isEmpty)
    #expect(LibraryOrganizationIntent.tools(for: "把这篇论文从研究书架中移除") == ["move_papers"])
    #expect(LibraryOrganizationIntent.tools(for: "删除研究书架") == ["prepare_delete_shelf"])
    #expect(LibraryOrganizationIntent.tools(for: "删除这篇论文") == ["prepare_delete_paper"])
    #expect(LibraryOrganizationIntent.tools(for: "恢复已经删除的论文").isEmpty)
    #expect(LibraryOrganizationIntent.tools(for: "请永久删除这篇论文") == ["prepare_delete_paper"])
    #expect(LibraryOrganizationIntent.tools(for: "如果它们重复，请删除论文").isEmpty)
}

@Test func libraryOrganizationParserRejectsPathsAmbiguousDestinationsAndRepeatedIDs() throws {
    let id = UUID()
    for (name, json) in [
        ("prepare_local_import", #"{"destination":"unfiled","path":"/some/file.pdf"}"#),
        ("move_papers", #"{"paper_ids":["\#(id)","\#(id)"],"destination":"unfiled"}"#),
        ("list_library", #"{"scope":"shelf"}"#),
        ("list_library", #"{"scope":"papers","offset":true}"#),
        ("list_library", #"{"scope":"trash"}"#),
        ("restore_paper", #"{"paper_id":"\#(id)"}"#),
        ("delete_paper", #"{"paper_id":"\#(id)"}"#),
        ("prepare_delete_paper", #"{"paper_id":"\#(id)","confirmed":true}"#),
        ("list_library", #"{"scope":"papers","shelf_id":"\#(id)"}"#),
        ("prepare_delete_shelf", #"{"shelf_id":"book title"}"#),
    ] {
        #expect(throws: (any Error).self) { try AgentToolArguments.parse(name: name, json: json, limits: .init()) }
    }
}

@Test func libraryAgentIndexTracksEditsDeletionTieOrderAndCancellation() async throws {
    let index = LibraryAgentSearchIndex()
    let first = TextBlock(sourcePage: 0, text: "RESEARCHING sparse data")
    let next = TextBlock(sourcePage: 1, text: "Sparse reSéarchers")
    var paper = Paper(
        title: "A fixture", digest: "sample", originalPath: "sample.pdf", pageCount: 2,
        blocks: [first, next], warnings: [], canReflow: false)
    let initial = try await index.search("search sparse", papers: [paper])
    #expect(initial.first?.blockID == first.id)
    paper.blocks[0].text = "Another passage"
    #expect(try await index.search("search sparse", papers: [paper]).first?.blockID == next.id)
    paper.pageCount = 1
    #expect(try await index.search("search", papers: [paper]).isEmpty)
    #expect(try await index.search("fixture", papers: []).isEmpty)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await index.search("fixture", papers: [paper])
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

private actor TransientFailureTransport: HTTPTransport {
    private(set) var attempts = 0
    let failures: Int
    let status: Int
    let body: String
    init(failures: Int, status: Int, body: String) {
        self.failures = failures
        self.status = status
        self.body = body
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        if attempts <= failures {
            if status == 429 {
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil,
                        headerFields: ["Retry-After": "0.1"])!
                )
            }
            throw URLError(.timedOut)
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func agentRetriesATransientNetworkFailureOnlyBeforeStreamingStarted() async throws {
    let body = #"{"choices":[{"message":{"role":"assistant","content":"重试后完成"},"finish_reason":"stop"}]}"#
    let transport = TransientFailureTransport(failures: 1, status: 0, body: body)
    var limits = AgentLimits()
    limits.maxTransientRetries = 2
    let reply = try await AgentClient(transport: transport).respond(
        settings: agentSettings(), key: "fixture", messages: [.init(role: "user", content: "q")], limits: limits)
    #expect(reply.content == "重试后完成")
    #expect(await transport.attempts == 2)
}

@Test func agentRetriesRateLimitingWithRetryAfterBeforeExecution() async throws {
    let body = #"{"choices":[{"message":{"role":"assistant","content":"限流后完成"},"finish_reason":"stop"}]}"#
    let transport = TransientFailureTransport(failures: 1, status: 429, body: body)
    var limits = AgentLimits()
    limits.maxTransientRetries = 2
    let reply = try await AgentClient(transport: transport).respond(
        settings: agentSettings(), key: "fixture", messages: [.init(role: "user", content: "q")], limits: limits)
    #expect(reply.content == "限流后完成")
    #expect(await transport.attempts == 2)
}

@Test func onlyReadOnlyToolBatchesRunConcurrently() {
    #expect(
        AgentToolConcurrency.canRunConcurrently([
            .init(id: "a", name: "search_library", arguments: "{}"),
            .init(id: "b", name: "read_paper", arguments: "{}"),
        ]))
    #expect(
        !AgentToolConcurrency.canRunConcurrently([
            .init(id: "a", name: "search_library", arguments: "{}"),
            .init(id: "b", name: "move_papers", arguments: "{}"),
        ]))
    #expect(
        !AgentToolConcurrency.canRunConcurrently([
            .init(id: "a", name: "search_library", arguments: "{}")
        ]))
}
