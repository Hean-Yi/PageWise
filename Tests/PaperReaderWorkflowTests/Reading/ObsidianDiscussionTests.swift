import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

private enum ObsidianDiscussionOutcome: CaseIterable, Sendable {
    case saved, truncated, cancelled, noDirectory
}

private actor ObsidianDiscussionTransport: HTTPTransport {
    let outcome: ObsidianDiscussionOutcome
    private(set) var inputs: [String] = []

    init(_ outcome: ObsidianDiscussionOutcome) { self.outcome = outcome }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        struct Body: Decodable {
            struct Message: Decodable { let content: String }
            let messages: [Message]
        }
        let payload = try JSONDecoder().decode(Body.self, from: request.httpBody ?? Data())
        inputs.append(try #require(payload.messages.last?.content))
        if outcome == .cancelled { throw CancellationError() }
        let url = try #require(request.url)
        let response: [String: Any] = [
            "choices": [
                ["message": ["content": "已核对讨论的证据。"], "finish_reason": outcome == .truncated ? "length" : "stop"]
            ]
        ]
        return (
            try JSONSerialization.data(withJSONObject: response),
            try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        )
    }

    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        throw ReaderError.message("意外的流式请求。")
    }
}

@Test(arguments: ObsidianDiscussionOutcome.allCases) @MainActor
private func obsidianDiscussionRequiresOptInAndPublishesOnlyCompleteResults(
    _ outcome: ObsidianDiscussionOutcome
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let api = ObsidianDiscussionTransport(outcome)
    let model = try ReaderModel(root: root, client: ModelClient(transport: api), credentials: WorkflowCredentials())
    await model.load()
    var config = model.modelSettings
    config.model = "fixture"
    try model.saveSettings(config, key: nil)
    let paper = Paper(
        title: "Discussion fixture", digest: "fixture", originalPath: "fixture.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    try #require(await model.save(adding: paper))
    var report = ChatTurn(paperID: paper.id, question: "非讨论记录", selection: "", answer: "精读分析范围", evidence: [])
    report.closeReadingVersion = paper.digest
    let first = ChatTurn(
        paperID: paper.id, question: "首轮读者问题", selection: "", answer: String(repeating: "x", count: 21_000),
        evidence: [])
    let last = ChatTurn(paperID: paper.id, question: "末轮读者问题", selection: "", answer: "独立的读者猜测", evidence: [])
    model.state.chats = [first, report, last]
    let folder = root.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(await !model.hasObsidianDirectory())
    if outcome != .noDirectory {
        try #require(await model.selectVault(folder))
        #expect(await model.hasObsidianDirectory())
    }
    let published = await model.saveToObsidian(paperID: paper.id, includeDiscussion: true)
    let inputs = await api.inputs
    #expect(inputs.count == (outcome == .noDirectory ? 0 : 1))
    if let transcript = inputs.first {
        #expect(transcript.contains(first.question) && transcript.contains(last.answer))
        #expect(!transcript.contains(report.answer))
    }
    let saved = try #require(try await model.store.load().papers.first)
    #expect(!model.busyAI && model.obsidianExportPaperID == nil)
    if outcome == .saved {
        try #require(published && saved.savedDiscussion == "已核对讨论的证据。")
        let file = folder.appendingPathComponent(try #require(saved.notePath))
        let before = try String(contentsOf: file, encoding: .utf8)
        #expect(before.components(separatedBy: saved.savedDiscussion).count == 2)
        try #require(await model.saveToObsidian(paperID: paper.id))
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
        #expect(await api.inputs.count == 1)
    } else {
        #expect(!published && saved.notePath == nil && saved.savedDiscussion.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
