import Foundation
import Testing

@testable import PaperReaderKit

private actor StreamCapture {
    var text: [String] = []
    func partial(_ value: String) { text.append(value) }
}

@Test func streamDecodesSplitUTF8AndNeverAcceptsTruncatedResponse() async throws {
    let capture = StreamCapture()
    let decoder = ChatCompletionStreamDecoder { await capture.partial($0) }
    let events = "data: {\"choices\":[{\"delta\":{\"content\":\"中文\"},\"finish_reason\":null}]}\r\n\r\n"
    for byte in events.utf8 { try await decoder.consume(Data([byte])) }
    #expect(await capture.text == ["中文"])
    await #expect(throws: (any Error).self) { try await decoder.finish() }
    try await decoder.consume(
        Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
    #expect(try await decoder.finish() == "中文")
}

@Test func streamingToolArgumentsAreJoinedBeforeExecution() async throws {
    let decoder = ChatCompletionStreamDecoder(maxToolCalls: 1) { _ in }
    let events = [
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-a","type":"function","extra_content":{"google":{"thought_signature":"saved-signature"}},"function":{"name":"search_library","arguments":"{\"query\":"}}]}}]}"#,
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"attention\"}"}}]},"finish_reason":"tool_calls"}]}"#,
    ]
    try await decoder.consume(Data(("data: " + events[0] + "\n\n").utf8))
    await #expect(throws: (any Error).self) { try await decoder.finishMessage() }
    try await decoder.consume(Data(("data: " + events[1] + "\n\ndata: [DONE]\n\n").utf8))
    let (message, reason) = try await decoder.finishMessage()
    #expect(reason == "tool_calls")
    let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    let tool = try #require((roundTrip["tool_calls"] as? [[String: Any]])?.first)
    let extra = try #require(tool["extra_content"] as? [String: [String: String]])
    #expect(extra["google"]?["thought_signature"] == "saved-signature")
    #expect(message.toolCalls?.first?.function.arguments == #"{"query":"attention"}"#)
}

private struct AgentErrorTransport: HTTPTransport {
    let body: String?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let body else { throw URLError(.timedOut) }
        return (
            Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func failedAgentCompletionsDistinguishNetworkFailuresFromModelResponses() async throws {
    var settings = ModelSettings()
    settings.baseURL = ModelServicePreset.deepSeek.baseURL
    settings.model = ModelServicePreset.deepSeek.defaultModel
    let cases: [(data: String?, stream: Bool, expected: String)] = [
        (nil, true, "网络请求未完成"),
        ("data: not-json\n\n", true, "格式不兼容"),
        ("data: [DONE]\n\n", true, "流式响应中断"),
        ("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n", true, "输出长度上限"),
        ("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n", true, "过滤"),
        (#"{"choices":[{"message":{"role":"assistant"},"finish_reason":"length"}]}"#, false, "输出长度上限"),
    ]
    for sample in cases {
        let agent = AgentClient(transport: AgentErrorTransport(body: sample.data))
        let messages = [AgentMessage(role: "user", content: "fixture")]
        do {
            if sample.stream {
                _ = try await agent.respondStreaming(
                    settings: settings, key: "fixture", messages: messages, limits: .init()
                ) { _ in }
            } else {
                _ = try await agent.respond(settings: settings, key: "fixture", messages: messages, limits: .init())
            }
            Issue.record("Expected the incomplete response to fail")
        } catch let error as ReaderError {
            #expect(error.localizedDescription.contains(sample.expected))
        }
    }
}
