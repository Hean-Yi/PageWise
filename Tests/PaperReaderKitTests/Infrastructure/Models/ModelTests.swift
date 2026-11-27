import Foundation
import Testing

@testable import PaperReaderKit

private struct ReplyTransport: HTTPTransport {
    let status: Int
    let body: String
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        #expect(request.url?.path == "/v4/chat/completions")
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func modelRejectsTruncatedTranslation() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let client = ModelClient(
        transport: ReplyTransport(
            status: 200, body: #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#))
    await #expect(throws: (any Error).self) {
        try await client.complete(settings: settings, key: "test-only", system: "translate", user: "input")
    }
}

@Test func modelRejectsHTTPAuthError() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let client = ModelClient(transport: ReplyTransport(status: 401, body: "secret must never be shown"))
    do {
        _ = try await client.complete(settings: settings, key: "test-only", system: "test", user: "input")
        Issue.record("Expected failure")
    } catch { #expect(!error.localizedDescription.contains("secret")) }
}

@Test func modelReturnsCompleteResponse() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let client = ModelClient(
        transport: ReplyTransport(
            status: 200, body: #"{"choices":[{"message":{"content":"完整译文"},"finish_reason":"stop"}]}"#))
    let result = try await client.complete(settings: settings, key: "test-only", system: "translate", user: "input")
    #expect(result == "完整译文")
}

@Test func modelExtractsJSONFromReasoningAndMarkdownFences() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let content = """
        <think>内部推理里也有一个 { 花括号</think>
        ```json
        {"memory":"核对预算后再比较方法"}
        ```
        """
    let body = String(
        decoding: try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content], "finish_reason": "stop"]]
        ]), as: UTF8.self)
    let client = ModelClient(transport: ReplyTransport(status: 200, body: body))
    let result = try await client.complete(
        settings: settings, key: "test-only", system: "extract", user: "input", jsonOutput: true)
    struct Extracted: Decodable { let memory: String }
    #expect(try JSONDecoder().decode(Extracted.self, from: Data(result.utf8)).memory == "核对预算后再比较方法")
}

@Test func modelIgnoresFencedJSONDraftInsideThinkBlockAndExtractsFinalJSON() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let content = """
        <think>
        先草拟一个错误示例：
        ```json
        {"memory":"草稿不应被提取"}
        ```
        </think>
        ```json
        {"memory":"正式结果"}
        ```
        """
    let body = String(
        decoding: try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content], "finish_reason": "stop"]]
        ]), as: UTF8.self)
    let client = ModelClient(transport: ReplyTransport(status: 200, body: body))
    let result = try await client.complete(
        settings: settings, key: "test-only", system: "extract", user: "input", jsonOutput: true)
    struct Extracted: Decodable { let memory: String }
    #expect(try JSONDecoder().decode(Extracted.self, from: Data(result.utf8)).memory == "正式结果")
}

private actor SequencedTransport: HTTPTransport {
    private var responses: [(status: Int, body: String, retryAfter: String?)]
    private(set) var calls = 0
    init(_ responses: [(status: Int, body: String, retryAfter: String?)]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        let next = responses.removeFirst()
        var headers: [String: String] = [:]
        if let retryAfter = next.retryAfter { headers["Retry-After"] = retryAfter }
        return (
            Data(next.body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: headers)!
        )
    }

    func callCount() -> Int { calls }
}

@Test func modelRetriesTransientStatusBeforeSucceeding() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let transport = SequencedTransport([
        (503, "unavailable", "0"),
        (200, #"{"choices":[{"message":{"content":"完整译文"},"finish_reason":"stop"}]}"#, nil),
    ])
    let client = ModelClient(transport: transport)
    let result = try await client.complete(settings: settings, key: "test-only", system: "translate", user: "input")
    #expect(result == "完整译文")
    #expect(await transport.callCount() == 2)
}

@Test func modelDoesNotRetryAnAuthenticationFailure() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let transport = SequencedTransport([(401, "denied", nil)])
    let client = ModelClient(transport: transport)
    await #expect(throws: (any Error).self) {
        try await client.complete(settings: settings, key: "test-only", system: "translate", user: "input")
    }
    #expect(await transport.callCount() == 1)
}

@Test func modelStopsAfterBoundedTransientRetries() async throws {
    var settings = ModelSettings()
    settings.baseURL = "https://example.invalid/v4"
    settings.model = "test"
    let transport = SequencedTransport([
        (503, "unavailable", "0"), (503, "unavailable", "0"), (503, "unavailable", "0"),
    ])
    let client = ModelClient(transport: transport)
    await #expect(throws: (any Error).self) {
        try await client.complete(
            settings: settings, key: "test-only", system: "translate", user: "input", maxTransientRetries: 1)
    }
    #expect(await transport.callCount() == 2)
}
