import Foundation
import Testing

@testable import PaperReaderKit

private actor StreamCapture {
    var text: [String] = []
    var completed: [String] = []
    func partial(_ value: String) { text.append(value) }
    func paragraph(_ value: String) { completed.append(value) }
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

@Test func paragraphBoundaryPublishesBeforeRestOfStreamAndProtectsMath() async throws {
    let capture = StreamCapture()
    var first = TextBlock(sourcePage: 0, text: "First x")
    first.richContent = RichContent(
        html: "<p>First <math><mi>x</mi></math></p>", translationInput: "First [[MATH_1]]",
        mathematics: ["[[MATH_1]]": "<math><mi>x</mi></math>"], mathDescriptions: [:])
    let second = TextBlock(sourcePage: 0, text: "Second")
    let stream = ParagraphTranslationStream(
        blocks: [first, second], onDraft: { _, text in await capture.partial(text) },
        onParagraph: { _, text in await capture.paragraph(text) })
    try await stream.consume("<BEGIN_0>第一 [[MATH_1]]<END_0><BEGIN_1>第")
    #expect(await capture.completed == ["第一 [[MATH_1]]"])
    #expect(await capture.text.last == "第")
    await #expect(throws: (any Error).self) { try await stream.finish() }
    try await stream.consume("<BEGIN_0>第一 [[MATH_1]]<END_0><BEGIN_1>第二<END_1>")
    try await stream.finish()
    #expect(await capture.completed == ["第一 [[MATH_1]]", "第二"])
    let invalid = ParagraphTranslationStream(
        blocks: [first], onDraft: { _, _ in }, onParagraph: { _, _ in Issue.record("Invalid math was published") })
    await #expect(throws: (any Error).self) { try await invalid.consume("<BEGIN_0>公式丢失<END_0>") }
}

@Test func streamingToolArgumentsAreJoinedBeforeExecution() async throws {
    let decoder = ChatCompletionStreamDecoder(allowTools: true) { _ in }
    let events = [
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-a","type":"function","function":{"name":"search_library","arguments":"{\"query\":"}}]}}]}"#,
        #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"attention\"}"}}]},"finish_reason":"tool_calls"}]}"#,
    ]
    try await decoder.consume(Data(("data: " + events[0] + "\n\n").utf8))
    await #expect(throws: (any Error).self) { try await decoder.finishMessage() }
    try await decoder.consume(Data(("data: " + events[1] + "\n\ndata: [DONE]\n\n").utf8))
    let (message, reason) = try await decoder.finishMessage()
    #expect(reason == "tool_calls")
    #expect(message.toolCalls?.first?.function.arguments == #"{"query":"attention"}"#)
}

@Test func outputLimitIsExplicitAndKeepsAlreadyPublishedParagraphs() async throws {
    let capture = StreamCapture()
    let parser = ParagraphTranslationStream(
        blocks: [TextBlock(sourcePage: 0, text: "First"), TextBlock(sourcePage: 0, text: "Second")],
        onDraft: { _, text in await capture.partial(text) }, onParagraph: { _, text in await capture.paragraph(text) })
    let decoder = ChatCompletionStreamDecoder { try await parser.consume($0) }
    try await decoder.consume(
        Data(#"data: {"choices":[{"delta":{"content":"<BEGIN_0>第一段<END_0><BEGIN_1>未完成"}}]}"#.utf8) + Data("\n\n".utf8))
    await #expect(throws: ModelStreamFailure.outputLimit) {
        try await decoder.consume(
            Data(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#.utf8) + Data("\n\n".utf8))
    }
    #expect(await capture.completed == ["第一段"])
}
