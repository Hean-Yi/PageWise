import Foundation
import SwiftSoup
import Testing

@testable import PaperReaderKit

private actor ReflowCapture {
    var plans: [AIReflowPlan] = []
    var drafts: [String] = []
    var blocks: [BilingualBlock] = []
    var sourceIDs: [[UUID]] = []
    var planSaved = false
    func plan(_ plan: AIReflowPlan) {
        plans.append(plan)
        planSaved = true
    }
    func draft(_ text: String) { drafts.append(text) }
    func block(_ block: BilingualBlock, _ ids: [UUID]) {
        #expect(planSaved)
        blocks.append(block)
        sourceIDs.append(ids)
    }
}

private struct ReflowFixture {
    let evidence: AIReflowEvidence
    let requestID = UUID()
    let windowID: UUID
    let capture = ReflowCapture()
    let stream: AIReflowStream
    init(_ sources: [TextBlock], accepted: AIReflowPlan? = nil, committed: Set<UUID> = []) throws {
        evidence = try AIReflowEvidence(sources)
        windowID = accepted?.windowID ?? UUID()
        let capture = capture
        stream = try AIReflowStream(
            evidence: evidence, requestID: requestID, windowID: windowID, configurationDigest: "test",
            acceptedPlan: accepted, committed: committed,
            onPlan: { await capture.plan($0) }, onDraft: { _, text in await capture.draft(text) },
            onBlock: { await capture.block($0, $1) })
    }
    func blocks(merge: Bool = false) -> [[String: Any]] {
        let groups = merge ? [evidence.sources] : evidence.sources.map { [$0] }
        return groups.enumerated().map { index, group in
            [
                "block_index": index, "kind": group.first!.kind.rawValue,
                "source_segments": group.map {
                    ["source_id": $0.block.id.uuidString, "start_utf16": 0, "end_utf16": $0.block.text.utf16.count]
                        as [String: Any]
                },
                "object_refs": group.flatMap(\.objectIDs),
            ]
        }
    }
    func line(_ sequence: Int, _ type: String, _ payload: [String: Any] = [:]) throws -> String {
        var event: [String: Any] = [
            "v": 1, "request_id": requestID.uuidString, "window_id": windowID.uuidString, "seq": sequence, "type": type,
        ]
        event.merge(payload) { _, new in new }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }
    func plan(_ blocks: [[String: Any]]? = nil) throws -> String {
        try line(0, "window_plan", ["blocks": blocks ?? self.blocks(), "dispositions": [], "carry": []])
    }
}

@Test func aiReflowCommitsBeforeWholeStreamAndPreservesAllOriginalEvidence() async throws {
    let first = TextBlock(sourcePage: 0, text: "A precise claim.")
    let second = TextBlock(sourcePage: 1, text: "A separate limitation.")
    let f = try ReflowFixture([first, second])
    var output = try f.plan()
    output += try f.line(1, "block_start", ["block_index": 0])
    output += try f.line(2, "translation_delta", ["block_index": 0, "parts": [["type": "text", "text": "准确结论。"]]])
    try await f.stream.consume(output)
    #expect(await f.capture.drafts == ["准确结论。"])
    #expect(await f.capture.blocks.isEmpty)
    output += try f.line(3, "block_end", ["block_index": 0])
    try await f.stream.consume(output)
    #expect(await f.capture.blocks.count == 1)
    #expect(await f.capture.blocks.first?.block.text == first.text)
    await #expect(throws: (any Error).self) { try await f.stream.finish() }
    output += try f.line(4, "block_start", ["block_index": 1])
    output += try f.line(5, "translation_delta", ["block_index": 1, "parts": [["type": "text", "text": "独立限制。"]]])
    output += try f.line(6, "block_end", ["block_index": 1])
    output += try f.line(7, "window_end", ["block_count": 2])
    try await f.stream.consume(output)
    try await f.stream.finish()
    #expect(await f.capture.sourceIDs == [[first.id], [second.id]])
}

@Test func aiReflowMergesContiguousSourcesAndRebasesProtectedFormulaObjects() async throws {
    let formulaA = "<math><mi>x</mi></math>"
    let formulaB = "<math><mi>y</mi></math>"
    var first = TextBlock(sourcePage: 0, text: "We use x")
    first.richContent = RichContent(
        html: "<p>We use \(formulaA)</p>", translationInput: "We use [[MATH_1]]", mathematics: ["[[MATH_1]]": formulaA],
        mathDescriptions: ["[[MATH_1]]": "x"])
    var second = TextBlock(sourcePage: 1, text: "and y to estimate.")
    second.richContent = RichContent(
        html: "<p>and \(formulaB) to estimate.</p>", translationInput: "and [[MATH_1]] to estimate.",
        mathematics: ["[[MATH_1]]": formulaB], mathDescriptions: ["[[MATH_1]]": "y"])
    let f = try ReflowFixture([first, second])
    let refs = f.evidence.sources.flatMap(\.objectIDs)
    var output = try f.plan(f.blocks(merge: true))
    output += try f.line(1, "block_start", ["block_index": 0])
    output += try f.line(
        2, "translation_delta",
        [
            "block_index": 0,
            "parts": [
                ["type": "text", "text": "使用"], ["type": "object_ref", "object_id": refs[0]],
                ["type": "text", "text": "与"], ["type": "object_ref", "object_id": refs[1]],
                ["type": "text", "text": "估计。"],
            ],
        ])
    output += try f.line(3, "block_end", ["block_index": 0])
    output += try f.line(4, "window_end", ["block_count": 1])
    // Simulate arbitrary character/JSON/escape boundaries, including incomplete records.
    var accumulated = ""
    for character in output {
        accumulated.append(character)
        try await f.stream.consume(accumulated)
    }
    try await f.stream.finish()
    let result = try #require(await f.capture.blocks.first)
    #expect(result.block.text == "We use x and y to estimate.")
    #expect(result.block.sourcePage == -1)
    let provenance = try #require(result.block.reflowProvenance)
    #expect(provenance.map(\.sourceID) == [first.id, second.id])
    #expect(provenance.map(\.sourcePage) == [0, 1])
    #expect(provenance.map(\.startUTF16) == [0, 0])
    #expect(provenance.map(\.endUTF16) == [first.text.utf16.count, second.text.utf16.count])
    let restored = try JSONDecoder().decode(TextBlock.self, from: JSONEncoder().encode(result.block))
    #expect(restored == result.block)
    #expect(restored.reflowProvenance == provenance)
    #expect(result.translation == "使用[[MATH_1]]与[[MATH_2]]估计。")
    #expect(result.block.richContent?.mathematics == ["[[MATH_1]]": formulaA, "[[MATH_2]]": formulaB])
    #expect(result.block.richContent?.html == first.richContent!.html + "\n" + second.richContent!.html)
    #expect(await f.capture.sourceIDs == [[first.id, second.id]])
}

@Test func aiReflowRejectsMissingDuplicatedReorderedAndPartialSourcesBeforePlanSave() async throws {
    let sources = [TextBlock(sourcePage: 0, text: "Alpha 😀."), TextBlock(sourcePage: 1, text: "Beta.")]
    for variant in 0..<6 {
        let f = try ReflowFixture(sources)
        var blocks = f.blocks()
        switch variant {
        case 0: blocks.removeLast()
        case 1: blocks[1]["source_segments"] = blocks[0]["source_segments"]
        case 2:
            let segments = blocks[0]["source_segments"]
            blocks[0]["source_segments"] = blocks[1]["source_segments"]
            blocks[1]["source_segments"] = segments
        case 3:
            blocks[0]["source_segments"] = [["source_id": sources[0].id.uuidString, "start_utf16": 0, "end_utf16": 7]]
        case 4:
            blocks[0]["source_segments"] = [
                ["source_id": UUID().uuidString, "start_utf16": 0, "end_utf16": sources[0].text.utf16.count]
            ]
        default: blocks[0]["object_refs"] = ["invented-object"]
        }
        await #expect(throws: (any Error).self) { try await f.stream.consume(f.plan(blocks)) }
        #expect(await f.capture.plans.isEmpty)
        #expect(await f.capture.blocks.isEmpty)
    }
}

@Test func aiReflowPreservesSharedTableWithoutTranslationAndRejectsObjectLoss() async throws {
    var source = TextBlock(sourcePage: 2, text: "Observed 7")
    let html = "<table><tr><td>Observed</td><td>7</td></tr></table>"
    source.richContent = RichContent(html: html, translationInput: "", mathematics: [:], mathDescriptions: [:])
    let f = try ReflowFixture([source])
    var output = try f.plan()
    output += try f.line(1, "block_start", ["block_index": 0])
    output += try f.line(2, "block_end", ["block_index": 0])
    output += try f.line(3, "window_end", ["block_count": 1])
    try await f.stream.consume(output)
    try await f.stream.finish()
    #expect(await f.capture.blocks.first?.block.richContent?.html == html)
    #expect(await f.capture.blocks.first?.translation == nil)
    let invalid = try ReflowFixture([source])
    var blocks = invalid.blocks()
    blocks[0]["object_refs"] = []
    await #expect(throws: (any Error).self) { try await invalid.stream.consume(invalid.plan(blocks)) }
}

@Test func aiReflowResumeUsesAcceptedIDsAndSkipsOnlyCommittedPrefix() async throws {
    let sources = [TextBlock(sourcePage: 0, text: "First."), TextBlock(sourcePage: 1, text: "Second.")]
    let f = try ReflowFixture(sources)
    try await f.stream.consume(f.plan())
    let accepted = try #require(await f.capture.plans.first)
    let encoded = try JSONEncoder().encode(accepted)
    let saved = try JSONDecoder().decode(AIReflowPlan.self, from: encoded)
    let resumed = try ReflowFixture(sources, accepted: saved, committed: [saved.blocks[0].id])
    var output = try resumed.plan(ModelClient.wireBlocks(saved))
    output += try resumed.line(1, "block_start", ["block_index": 1])
    output += try resumed.line(2, "translation_delta", ["block_index": 1, "parts": [["type": "text", "text": "第二。"]]])
    output += try resumed.line(3, "block_end", ["block_index": 1])
    output += try resumed.line(4, "window_end", ["block_count": 2])
    try await resumed.stream.consume(output)
    try await resumed.stream.finish()
    #expect(await resumed.capture.plans == [saved])
    #expect(await resumed.capture.blocks.map(\.block.id) == [saved.blocks[1].id])
    #expect(throws: (any Error).self) { try ReflowFixture(sources, accepted: saved, committed: [saved.blocks[1].id]) }
    var changed = sources
    changed[0].text = "Changed."
    #expect(throws: (any Error).self) { try ReflowFixture(changed, accepted: saved) }
    let duplicate = try ReflowFixture(sources, accepted: saved, committed: [saved.blocks[0].id])
    await #expect(throws: (any Error).self) {
        try await duplicate.stream.consume(duplicate.plan() + duplicate.line(1, "block_start", ["block_index": 0]))
    }
}

@Test func aiReflowRejectsProtocolViolationsAndNeverCommitsEmptyOrUnclosedTranslation() async throws {
    let source = TextBlock(sourcePage: 0, text: "Body.")
    for variant in 0..<11 {
        let f = try ReflowFixture([source])
        let output: String
        switch variant {
        case 0:
            output = try f.line(
                0, "window_plan", ["blocks": f.blocks(), "dispositions": [], "carry": [], "extra": true])
        case 1: output = try f.line(0, "block_start", ["block_index": 0])
        case 2: output = try f.plan() + f.line(2, "block_start", ["block_index": 0])
        case 3:
            output =
                try f.plan() + f.line(1, "block_start", ["block_index": 0]) + f.line(2, "block_end", ["block_index": 0])
        case 4: output = try f.plan() + f.line(1, "window_end", ["block_count": 1])
        case 5: output = try f.line(0, "window_plan", ["blocks": f.blocks(), "dispositions": [], "carry": [], "v": 2])
        case 6:
            output = try f.line(
                0, "window_plan",
                ["blocks": f.blocks(), "dispositions": [], "carry": [], "request_id": UUID().uuidString])
        case 7:
            output =
                try f.plan() + f.line(1, "block_start", ["block_index": 0])
                + f.line(
                    2, "translation_delta",
                    ["block_index": 0, "parts": [["type": "text", "text": String(repeating: "文", count: 129)]]])
        case 8:
            output =
                try f.plan() + f.line(1, "block_start", ["block_index": 0])
                + f.line(
                    2, "translation_delta",
                    ["block_index": 0, "parts": [["type": "object_ref", "object_id": "unknown"]]])
        case 9:
            output =
                try f.plan() + f.line(1, "block_start", ["block_index": 0])
                + f.line(
                    2, "translation_delta",
                    ["block_index": 0, "parts": [["type": "text", "text": "bad\u{0000}control"]]])
        default:
            output = try f.line(0, "window_plan", ["blocks": f.blocks(), "dispositions": [], "carry": [], "seq": true])
        }
        await #expect(throws: (any Error).self) { try await f.stream.consume(output) }
        #expect(await f.capture.blocks.isEmpty)
    }
    let truncated = try ReflowFixture([source])
    try await truncated.stream.consume(truncated.plan() + "{\"v\":1")
    await #expect(throws: (any Error).self) { try await truncated.stream.finish() }
}

private actor ReflowRequestTransport: HTTPTransport {
    var requestBody: Data?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestBody = request.httpBody
        let body =
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        return (
            Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func aiReflowThinkingPolicyIsScopedToVerifiedModelEndpointAndRequest() async throws {
    for variant in 0..<5 {
        let transport = ReflowRequestTransport()
        let client = ModelClient(transport: transport)
        var settings = ModelSettings()
        settings.model = variant == 2 ? "glm-unverified" : "glm-5.3-flash"
        if variant == 1 { settings.baseURL = "https://compatible.example/api/paas/v4" }
        if variant == 3 { settings.baseURL = "https://open.bigmodel.cn/other/v4" }
        if variant == 4 {
            _ = try await client.completeStream(settings: settings, key: "fixture-key", system: "test", user: "test") {
                _ in
            }
        } else {
            _ = try await client.completeStream(
                settings: settings, key: "fixture-key", maxOutputTokens: 512, system: "test", user: "test",
                reflowImages: []
            ) { _ in }
        }
        let data = try #require(await transport.requestBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if variant == 0 {
            #expect((body["thinking"] as? [String: String]) == ["type": "disabled"])
        } else {
            #expect(body["thinking"] == nil)
        }
        if variant == 4 {
            #expect(body["response_format"] == nil)
        } else {
            #expect((body["response_format"] as? [String: String]) == ["type": "json_object"])
        }
        #expect(String(decoding: data, as: UTF8.self).contains("fixture-key") == false)
    }
}

@Test func aiReflowImageInputIsLocalBoundedAndTiedToSource() async throws {
    let transport = ReflowRequestTransport()
    let client = ModelClient(transport: transport)
    var settings = ModelSettings()
    settings.model = "fixture-vision-model"
    let source = TextBlock(sourcePage: 0, text: "Local evidence.")
    let image = AIReflowImage(sourceID: source.id, data: Data([137, 80, 78, 71]), mimeType: "image/png")
    _ = try await client.completeStream(
        settings: settings, key: "fixture-key", maxOutputTokens: 512, system: "test", user: "evidence",
        reflowImages: [image]
    ) { _ in }
    let data = try #require(await transport.requestBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let parts = try #require(messages[1]["content"] as? [[String: Any]])
    #expect((parts[1]["text"] as? String)?.contains(source.id.uuidString) == true)
    #expect((parts[2]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,iVBORw==")
    await #expect(throws: (any Error).self) {
        try await client.reflowAndTranslate(
            sources: [source], title: "Test", settings: settings, key: "fixture-key",
            images: [AIReflowImage(sourceID: UUID(), data: image.data, mimeType: image.mimeType)], onPlan: { _ in },
            onDraft: { _, _ in }, onBlock: { _, _ in })
    }
}

@Test func aiReflowRejectsOmittedRepeatedFormulaAndDoesNotPublishAfterPlanSaveFailure() async throws {
    var source = TextBlock(sourcePage: 0, text: "Use x.")
    source.richContent = RichContent(
        html: "<p>Use <math><mi>x</mi></math>.</p>", translationInput: "Use [[MATH_1]].",
        mathematics: ["[[MATH_1]]": "<math><mi>x</mi></math>"], mathDescriptions: [:])
    for repeated in [false, true] {
        let f = try ReflowFixture([source])
        let object = try #require(f.evidence.sources.first?.objectIDs.first)
        let parts: [[String: String]] =
            repeated
            ? [["type": "object_ref", "object_id": object], ["type": "object_ref", "object_id": object]]
            : [["type": "text", "text": "使用。"]]
        let output =
            try f.plan() + f.line(1, "block_start", ["block_index": 0])
            + f.line(2, "translation_delta", ["block_index": 0, "parts": parts])
            + f.line(3, "block_end", ["block_index": 0])
        await #expect(throws: (any Error).self) { try await f.stream.consume(output) }
        #expect(await f.capture.blocks.isEmpty)
    }
    let f = try ReflowFixture([source])
    let failing = try AIReflowStream(
        evidence: f.evidence, requestID: f.requestID, windowID: f.windowID, configurationDigest: "test",
        acceptedPlan: nil, committed: [], onPlan: { _ in throw ReaderError.message("fixture disk failure") },
        onDraft: { _, _ in Issue.record("Draft before plan save") },
        onBlock: { _, _ in Issue.record("Block before plan save") })
    await #expect(throws: (any Error).self) {
        try await failing.consume(f.plan() + f.line(1, "block_start", ["block_index": 0]))
    }
}

@Test func aiReflowAcceptsCombiningScalarAndZWJSplitsWithoutLosingText() async throws {
    let f = try ReflowFixture([TextBlock(sourcePage: 0, text: "A composed character and an emoji.")])
    var output = try f.plan() + f.line(1, "block_start", ["block_index": 0])
    let record = try f.line(
        2, "translation_delta", ["block_index": 0, "parts": [["type": "text", "text": "__unicode_split__"]]])
    let pieces = record.components(separatedBy: "__unicode_split__")
    #expect(pieces.count == 2)
    output += pieces[0]
    // Each callback contains valid Unicode, but its final grapheme may grow in the next callback.
    for fragment in ["e", "\u{0301}", " ", "👩", "\u{200D}", "💻"] {
        output += fragment
        try await f.stream.consume(output)
        #expect(await f.capture.drafts.isEmpty)
    }
    output += pieces[1]
    try await f.stream.consume(output)
    let expected = "e\u{0301} 👩\u{200D}💻"
    let draft = try #require(await f.capture.drafts.first)
    #expect(Array(draft.utf8) == Array(expected.utf8))
    output += try f.line(3, "block_end", ["block_index": 0])
    output += try f.line(4, "window_end", ["block_count": 1])
    try await f.stream.consume(output)
    try await f.stream.finish()
    let published = try #require(await f.capture.blocks.first?.translation)
    #expect(Array(published.utf8) == Array(expected.utf8))
}

@Test func aiReflowRejectsCanonicalEquivalentRewriteOfReceivedBytes() async throws {
    let f = try ReflowFixture([TextBlock(sourcePage: 0, text: "Original evidence.")])
    let prefix = try f.plan() + f.line(1, "block_start", ["block_index": 0])
    let record = try f.line(
        2, "translation_delta", ["block_index": 0, "parts": [["type": "text", "text": "__unicode_split__"]]])
    let recordPrefix = record.components(separatedBy: "__unicode_split__")[0]
    try await f.stream.consume(prefix + recordPrefix + "é")
    await #expect(throws: (any Error).self) {
        try await f.stream.consume(prefix + recordPrefix + "e\u{0301}")
    }
    #expect(await f.capture.blocks.isEmpty)
}

@Test func aiReflowRetainsSamePageProvenanceAndDecodesLegacyBlocks() async throws {
    let sources = [TextBlock(sourcePage: 3, text: "First 😀"), TextBlock(sourcePage: 3, text: "continuation.")]
    let f = try ReflowFixture(sources)
    try await f.stream.consume(f.plan(f.blocks(merge: true)))
    let plan = try #require(await f.capture.plans.first)
    let block = try f.evidence.assemble(plan.blocks[0]).0
    #expect(block.sourcePage == 3)
    #expect(block.reflowProvenance?.map(\.sourcePage) == [3, 3])
    #expect(block.reflowProvenance?.map(\.sourceID) == sources.map(\.id))
    #expect(block.reflowProvenance?.first?.endUTF16 == sources[0].text.utf16.count)
    let legacyData = try JSONSerialization.data(withJSONObject: [
        "id": sources[0].id.uuidString, "sourcePage": 3, "text": sources[0].text,
    ])
    let legacy = try JSONDecoder().decode(TextBlock.self, from: legacyData)
    #expect(legacy.reflowProvenance == nil)
    #expect(legacy.sourcePage == 3)
}

@Test func aiReflowPreservesComparisonsAndRendersTagShapedTextLiterally() async throws {
    let source = TextBlock(sourcePage: 0, text: "Accuracy > 95%, error < 1%; a literal markup example.")
    let f = try ReflowFixture([source])
    var output = try f.plan() + f.line(1, "block_start", ["block_index": 0])
    let fragments = ["准确率 > 95%，误差 < 1%。示例 <im", "g src=x onerror=alert(1)>"]
    for (offset, fragment) in fragments.enumerated() {
        output += try f.line(
            offset + 2, "translation_delta", ["block_index": 0, "parts": [["type": "text", "text": fragment]]])
        try await f.stream.consume(output)
    }
    #expect(await f.capture.drafts.first == fragments[0])
    output += try f.line(4, "block_end", ["block_index": 0])
    output += try f.line(5, "window_end", ["block_count": 1])
    try await f.stream.consume(output)
    try await f.stream.finish()
    let pair = try #require(await f.capture.blocks.first)
    #expect(pair.translation == fragments.joined())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paper = Paper(
        title: "Comparison fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [pair.block], warnings: [], canReflow: true)
    let artifact = try await HTMLReadingStore().append([pair], to: nil, paper: paper, root: root)
    let html = try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8)
    let translated = try #require(SwiftSoup.parse(html).select(".translation").first())
    #expect(try translated.text() == fragments.joined())
    #expect(try translated.select("img,script").isEmpty())
    #expect(try translated.html().contains("&lt;img"))
}

@Test func aiReflowNormalizesOnlyMalformedModelJSONAndTypes() async throws {
    let source = TextBlock(sourcePage: 0, text: "Body.")
    for variant in 0..<5 {
        let f = try ReflowFixture([source])
        switch variant {
        case 0:
            await #expect(throws: AIReflowFailure.invalidStructure) { try await f.stream.consume("{broken\n") }
        case 1:
            try await f.stream.consume("{broken")
            await #expect(throws: AIReflowFailure.invalidStructure) { try await f.stream.finish() }
        case 2:
            let output = try f.line(
                0, "window_plan", ["blocks": f.blocks(), "dispositions": [], "carry": [], "seq": "0"])
            await #expect(throws: AIReflowFailure.invalidStructure) { try await f.stream.consume(output) }
        case 3:
            let output = try f.plan() + f.line(1, "block_start", ["block_index": "0"])
            await #expect(throws: AIReflowFailure.invalidStructure) { try await f.stream.consume(output) }
        default:
            try await f.stream.consume(f.plan())
            await #expect(throws: AIReflowFailure.invalidStructure) { try await f.stream.finish() }
        }
    }
    #expect(AIReflowFailure.invalidStructure.localizedDescription.contains("此前已完成的内容已保留"))
}

@Test func aiReflowPreservesCallbackDecodingAndCancellationErrors() async throws {
    let source = TextBlock(sourcePage: 0, text: "Body.")
    for boundary in 0..<3 {
        let f = try ReflowFixture([source])
        let callbackFailure = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "fixture storage failure"))
        let stream = try AIReflowStream(
            evidence: f.evidence, requestID: f.requestID, windowID: f.windowID, configurationDigest: "test",
            acceptedPlan: nil, committed: [],
            onPlan: { _ in if boundary == 0 { throw callbackFailure } },
            onDraft: { _, _ in if boundary == 1 { throw callbackFailure } },
            onBlock: { _, _ in if boundary == 2 { throw callbackFailure } })
        let output =
            try f.plan() + f.line(1, "block_start", ["block_index": 0])
            + f.line(2, "translation_delta", ["block_index": 0, "parts": [["type": "text", "text": "正文。"]]])
            + f.line(3, "block_end", ["block_index": 0])
        await #expect(throws: DecodingError.self) { try await stream.consume(output) }
    }
    let f = try ReflowFixture([source])
    let cancelled = try AIReflowStream(
        evidence: f.evidence, requestID: f.requestID, windowID: f.windowID, configurationDigest: "test",
        acceptedPlan: nil, committed: [], onPlan: { _ in throw CancellationError() },
        onDraft: { _, _ in }, onBlock: { _, _ in })
    await #expect(throws: CancellationError.self) { try await cancelled.consume(f.plan()) }
}

private struct OfflineReflowTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@Test func aiReflowDoesNotRelabelConfigurationOrNetworkFailures() async throws {
    let client = ModelClient(transport: OfflineReflowTransport())
    let source = TextBlock(sourcePage: 0, text: "Offline fixture.")
    await #expect(throws: ReaderError.self) {
        try await client.reflowAndTranslate(
            sources: [source], title: "Fixture", settings: ModelSettings(), key: "fixture-key",
            onPlan: { _ in }, onDraft: { _, _ in }, onBlock: { _, _ in })
    }
    var settings = ModelSettings()
    settings.model = "fixture-model"
    await #expect(throws: URLError.self) {
        try await client.reflowAndTranslate(
            sources: [source], title: "Fixture", settings: settings, key: "fixture-key",
            onPlan: { _ in }, onDraft: { _, _ in }, onBlock: { _, _ in })
    }
}

@Test func aiReflowNativeEnvelopePublishesBeforeClosureWithEscapedAndNestedJSON() async throws {
    let sources = [TextBlock(sourcePage: 0, text: "First."), TextBlock(sourcePage: 1, text: "Second.")]
    let f = try ReflowFixture(sources)
    let envelope = AIReflowEnvelopeStream(stream: f.stream)
    let translation = "比较 < 1；e\u{0301} 👩\u{200D}💻；{括号} [方括号] \"引号\" \\ 路径。"
    let records = try [
        f.plan(), f.line(1, "block_start", ["block_index": 0]),
        f.line(2, "translation_delta", ["block_index": 0, "parts": [["type": "text", "text": translation]]]),
        f.line(3, "block_end", ["block_index": 0]),
    ]
    let pretty = try records.map {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: JSONSerialization.jsonObject(with: Data($0.utf8)), options: .prettyPrinted),
            as: UTF8.self)
    }
    var output = ""
    // Includes arbitrary splits inside escapes, combining characters and an unfinished envelope.
    for scalar in ("{\n\"events\": [\n" + pretty.joined(separator: ",\n")).unicodeScalars {
        output.unicodeScalars.append(scalar)
        try await envelope.consume(output)
    }
    #expect(await f.capture.plans.count == 1)
    #expect(await f.capture.drafts.last == translation)
    #expect(await f.capture.blocks.count == 1)
    #expect(await f.capture.blocks.first?.translation == translation)
    await #expect(throws: AIReflowFailure.invalidStructure) { try await envelope.finish() }
    output += "," + (try f.line(4, "block_start", ["block_index": 1]))
    output +=
        "," + (try f.line(5, "translation_delta", ["block_index": 1, "parts": [["type": "text", "text": "第二。"]]]))
    output += "," + (try f.line(6, "block_end", ["block_index": 1]))
    output += "," + (try f.line(7, "window_end", ["block_count": 2])) + "]}\n"
    try await envelope.consume(output)
    try await envelope.finish()
    #expect(await f.capture.blocks.count == 2)
}

@Test func aiReflowNativeEnvelopeRejectsInvalidWrappersDuplicatesAndTruncation() async throws {
    for variant in 0..<12 {
        let f = try ReflowFixture([TextBlock(sourcePage: 0, text: "Body.")])
        let envelope = AIReflowEnvelopeStream(stream: f.stream)
        let plan = try f.plan()
        let output: String
        switch variant {
        case 0: output = "{}"
        case 1: output = "{\"wrong\":[]}"
        case 2: output = "{\"events\":[1]}"
        case 3: output = "{\"events\":[" + plan + ",]}"
        case 4: output = "{\"events\":[" + plan + "],\"extra\":true}"
        case 5: output = "{\"events\":[" + plan + "],\"events\":[]}"
        case 6: output = "{\"events\":[" + plan + "," + plan + "]}"
        case 7: output = "{\"events\":[" + plan + "]} trailing"
        case 8: output = "{\"events\":[" + plan + "]}{}"
        case 9: output = "{\"events\":[" + plan + ","
        case 10: output = "{\"events\":[{\"type\":\"window_plan\\"
        default: output = plan
        }
        await #expect(throws: AIReflowFailure.invalidStructure) {
            try await envelope.consume(output)
            try await envelope.finish()
        }
        #expect(await f.capture.blocks.isEmpty)
    }
}

@Test func aiReflowNativeEnvelopeBoundsResponsesAndKeepsAcceptedResumeIDs() async throws {
    let source = TextBlock(sourcePage: 0, text: "Body.")
    let original = try ReflowFixture([source])
    try await original.stream.consume(original.plan())
    let accepted = try #require(await original.capture.plans.first)
    let resumed = try ReflowFixture([source], accepted: accepted, committed: [accepted.blocks[0].id])
    let envelope = AIReflowEnvelopeStream(stream: resumed.stream)
    let output =
        try "{\"events\":[" + resumed.plan(ModelClient.wireBlocks(accepted))
        + "," + resumed.line(1, "window_end", ["block_count": 1]) + "]}"
    try await envelope.consume(output)
    try await envelope.finish()
    #expect(await resumed.capture.plans == [accepted])
    #expect(await resumed.capture.blocks.isEmpty)
    for text in [
        "{\"events\":[{\"text\":\"" + String(repeating: "a", count: 65_536), String(repeating: " ", count: 2_000_001),
    ] {
        let f = try ReflowFixture([source])
        let limited = AIReflowEnvelopeStream(stream: f.stream)
        await #expect(throws: AIReflowFailure.invalidStructure) { try await limited.consume(text) }
    }
}

private actor NativeReflowTransport: HTTPTransport {
    var finishedEnvelope = false
    var requestedNativeJSON = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        requestedNativeJSON = (body["response_format"] as? [String: String]) == ["type": "json_object"]
        let messages = try #require(body["messages"] as? [[String: Any]])
        let inputText = try #require(messages.last?["content"] as? String)
        let input = try #require(JSONSerialization.jsonObject(with: Data(inputText.utf8)) as? [String: Any])
        let sources = try #require(input["sources"] as? [[String: Any]])
        let source = try #require(sources.first)
        func event(_ seq: Int, _ type: String, _ payload: [String: Any]) throws -> String {
            var value: [String: Any] = [
                "v": 1, "request_id": input["request_id"]!, "window_id": input["window_id"]!, "seq": seq, "type": type,
            ]
            value.merge(payload) { _, new in new }
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        func sse(_ content: String) throws -> Data {
            let payload: [String: Any] = ["choices": [["delta": ["content": content]]]]
            return Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: payload)) + Data("\n\n".utf8)
        }
        let segment: [String: Any] = [
            "source_id": source["source_id"]!, "start_utf16": 0, "end_utf16": source["end_utf16"]!,
        ]
        let block: [String: Any] = [
            "block_index": 0, "kind": source["kind"]!, "source_segments": [segment], "object_refs": [],
        ]
        let records = try [
            event(0, "window_plan", ["blocks": [block], "dispositions": [], "carry": []]),
            event(1, "block_start", ["block_index": 0]),
            event(2, "translation_delta", ["block_index": 0, "parts": [["type": "text", "text": "本地夹具。"]]]),
            event(3, "block_end", ["block_index": 0]),
        ]
        try await onData(sse("{\"events\":[" + records.joined(separator: ",")))
        try await onData(sse("," + event(4, "window_end", ["block_count": 1]) + "]}"))
        finishedEnvelope = true
        try await onData(
            Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test func aiReflowProductionClientUsesNativeJSONAndCommitsBeforeEnvelopeFinishes() async throws {
    let transport = NativeReflowTransport()
    let capture = ReflowCapture()
    var settings = ModelSettings()
    settings.model = "glm-5.3-flash"
    try await ModelClient(transport: transport).reflowAndTranslate(
        sources: [TextBlock(sourcePage: 0, text: "Local fixture.")], title: "Fixture", settings: settings,
        key: "fixture-key",
        onPlan: { await capture.plan($0) }, onDraft: { _, text in await capture.draft(text) },
        onBlock: { pair, ids in
            #expect(await transport.finishedEnvelope == false)
            await capture.block(pair, ids)
        })
    #expect(await transport.requestedNativeJSON)
    #expect(await capture.blocks.count == 1)
    #expect(await capture.blocks.first?.translation == "本地夹具。")
}
