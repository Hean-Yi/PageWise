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
        #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"search_library","arguments":"{\"query\":\"attention\"}"}}]},"finish_reason":"tool_calls"}]}"#,
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
    #expect((body["tools"] as? [[String: Any]])?.count == 5)
    let wireMessages = try #require(body["messages"] as? [[String: Any]])
    #expect(wireMessages[2]["role"] as? String == "assistant")
    #expect((wireMessages[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1")
    #expect(wireMessages[3]["tool_call_id"] as? String == "call_1")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
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
    ("prepare_import", "{\"candidate_id\":\"x\",\"path\":\"/tmp/a\"}"),
])
func agentArgumentsRejectUnknownExtraAndInvalidTypes(_ tool: String, _ json: String) {
    #expect(throws: (any Error).self) { try AgentToolArguments.parse(name: tool, json: json, limits: .init()) }
}

private func agentSettings() -> ModelSettings {
    var settings = ModelSettings()
    settings.model = "test"
    settings.baseURL = "https://example.invalid/v4"
    return settings
}
