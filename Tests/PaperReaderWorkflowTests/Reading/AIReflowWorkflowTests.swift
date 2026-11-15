import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

private actor JointReflowTransport: HTTPTransport {
    var calls = 0
    var interruptOnce: Bool
    init(interruptOnce: Bool = false) { self.interruptOnce = interruptOnce }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        calls += 1
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let input =
            try JSONSerialization.jsonObject(with: Data((messages[1]["content"] as! String).utf8)) as! [String: Any]
        let sources = input["sources"] as! [[String: Any]]
        let blocks =
            input["accepted_plan"] as? [[String: Any]]
            ?? sources.enumerated().map { index, source in
                [
                    "block_index": index, "kind": source["kind"]!,
                    "source_segments": [
                        ["source_id": source["source_id"]!, "start_utf16": 0, "end_utf16": source["end_utf16"]!]
                    ], "object_refs": [],
                ] as [String: Any]
            }
        var events: [[String: Any]] = [["type": "window_plan", "blocks": blocks, "dispositions": [], "carry": []]]
        let committed = Set(input["committed_block_indices"] as! [Int])
        for index in blocks.indices where !committed.contains(index) {
            events += [
                ["type": "block_start", "block_index": index],
                [
                    "type": "translation_delta", "block_index": index,
                    "parts": [["type": "text", "text": "这是完整的测试译文，保留原文含义。"]],
                ],
                ["type": "block_end", "block_index": index],
            ]
        }
        events.append(["type": "window_end", "block_count": blocks.count])
        for (seq, event) in events.enumerated() {
            var event = event
            event["seq"] = seq
            event["v"] = 1
            event["request_id"] = input["request_id"]!
            event["window_id"] = input["window_id"]!
            let content = String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)! + "\n"
            let packet = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
            try await onData(Data("data: ".utf8) + packet + Data("\n\n".utf8))
            if interruptOnce && event["type"] as? String == "block_end" {
                interruptOnce = false
                throw URLError(.networkConnectionLost)
            }
        }
        try await onData(
            Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func importingPDFAndReadingOriginalNeverStartsReflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let original = try Data(contentsOf: pdf)
    let transport = JointReflowTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let imported = await model.importURLs([pdf])
    #expect(imported.count == 1)
    let paper = try #require(model.paper)
    #expect(paper.blocks.isEmpty && paper.htmlReading == nil && paper.reflowJob == nil)
    #expect(paper.deferredReflow == true)
    #expect(model.readingChoicePresented)
    model.readOriginal()
    #expect(!model.readingChoicePresented && model.mode == "original")
    #expect(await transport.calls == 0)
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == original)
}

@Test @MainActor func jointReflowResumesCommittedPrefixWithoutDuplicatingOrChangingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = JointReflowTransport(interruptOnce: true)
    let credentials = WorkflowCredentials()
    let model = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await model.load()
    var settings = model.modelSettings
    settings.baseURL = "https://example.invalid/v1"
    settings.model = "fixture"
    try model.saveSettings(settings, key: "test-only")
    var paper = Paper(
        title: "Original fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: true)
    paper.reflowJob = ReflowJob(sources: [
        TextBlock(sourcePage: 0, text: "The first complete source paragraph."),
        TextBlock(sourcePage: 0, text: "The second complete source paragraph."),
    ])
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    try await waitForReflow(model, id: paper.id)
    let first = try #require(model.paper)
    #expect(first.blocks.count == 1)
    #expect(first.reflowJob?.acceptedPlan != nil)
    #expect(first.reflowJob?.failure != nil)
    let firstID = first.blocks[0].id
    let firstTranslation = first.translations[firstID.uuidString]
    let initialHTML = try String(
        contentsOf: root.appendingPathComponent(try #require(first.htmlReading).relativePath), encoding: .utf8)
    let reopened = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await reopened.load()
    reopened.select(paper.id)
    reopened.startAIReflow()
    try await waitForReflow(reopened, id: paper.id)
    let completed = try #require(reopened.paper)
    #expect(completed.reflowJob?.finished == true)
    #expect(completed.blocks.count == 2 && completed.blocks[0].id == firstID)
    #expect(completed.translations[firstID.uuidString] == firstTranslation)
    #expect(Set(completed.blocks.map(\.id)).count == 2)
    let finalHTML = try String(
        contentsOf: root.appendingPathComponent(try #require(completed.htmlReading).relativePath), encoding: .utf8)
    let sectionStart = try #require(initialHTML.range(of: "<section id="))
    let sectionEnd = try #require(
        initialHTML.range(of: "</section>", range: sectionStart.lowerBound..<initialHTML.endIndex))
    let sealedSection = String(initialHTML[sectionStart.lowerBound..<sectionEnd.upperBound])
    #expect(finalHTML.contains(sealedSection))
    #expect(await transport.calls == 2)
    #expect(reopened.showingReflowLoading)
    reopened.reportReflowReadiness(
        paperID: paper.id, bodyCount: 2, bodyHeight: 800, viewportHeight: 500, resourcesReady: true)
    for _ in 0..<100 where reopened.showingReflowLoading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!reopened.showingReflowLoading)
}

@MainActor private func waitForReflow(_ model: ReaderModel, id: UUID) async throws {
    for _ in 0..<300 {
        if !model.translating.contains(id) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Reflow task did not terminate")
}
