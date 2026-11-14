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
