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
