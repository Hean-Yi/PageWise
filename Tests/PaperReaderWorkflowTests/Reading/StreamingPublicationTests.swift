import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

private actor PausedParagraphTransport: HTTPTransport {
    var waiting = false
    var requests = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ReaderError.message("Unexpected non-stream request")
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        requests += 1
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["stream"] as? Bool == true)
        let input = (body["messages"] as! [[String: String]]).last!["content"]!
        let count = input.components(separatedBy: "<BEGIN_").count - 1
        #expect(count == 2)
        func event(_ text: String, finish: Bool = false) throws -> Data {
            let object: [String: Any] = [
                "choices": [["delta": ["content": text], "finish_reason": finish ? "stop" : NSNull()]]
            ]
            return Data(
                ("data: " + String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n\n")
                    .utf8)
        }
        try await onData(event("<BEGIN_0>第一段<END_0><BEGIN_1>第二"))
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
        try await onData(event("段<END_1>", finish: true))
        try await onData(Data("data: [DONE]\n\n".utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func oneConnectionPublishesFirstParagraphWhileSecondIsStillStreaming() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = PausedParagraphTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let first = TextBlock(sourcePage: 0, text: "First original paragraph")
    let second = TextBlock(sourcePage: 0, text: "Second original paragraph")
    let paper = Paper(
        title: "Original fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [first, second], warnings: [], canReflow: true)
    model.state.papers = [paper]
    #expect(await model.save())
    model.select(paper.id)
    var settings = model.modelSettings
    settings.model = "test"
    try model.saveSettings(settings, key: nil)
    model.startTranslation()
    for _ in 0..<200 {
        if await transport.waiting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.waiting)
    #expect(model.paper?.translatedBlockCount == 1)
    #expect(model.translationDraft?.text == "第二")
    #expect(model.translating.contains(paper.id))
    model.setActive(false, suspendTranslation: false)
    #expect(model.translating.contains(paper.id))
    #expect(model.translationPauseReason == nil)
    let firstArtifact = try #require(model.paper?.htmlReading)
    let firstHTML = try String(contentsOf: root.appendingPathComponent(firstArtifact.relativePath), encoding: .utf8)
    #expect(firstHTML.contains("第一段"))
    #expect(!firstHTML.contains("第二段"))
    #expect(firstHTML.contains("Second original paragraph"))
    #expect(firstHTML.contains("译文待加载"))
    #expect(firstArtifact.sections.count == 2)
    let persisted = try await LibraryStore(directory: root).load()
    #expect(persisted.papers[0].translatedBlockCount == 1)
    await transport.release()
    for _ in 0..<200 {
        if model.translating.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.paper?.translatedBlockCount == 2)
    #expect(model.translationDraft == nil)
    #expect(await transport.requests == 1)
}

private actor LengthLimitedTransport: HTTPTransport {
    var inputs: [String] = []
    var budgets: [Int] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ReaderError.message("Unexpected non-stream request")
    }
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        inputs.append((body["messages"] as! [[String: String]]).last!["content"]!)
        budgets.append(body["max_tokens"] as! Int)
        let content = inputs.count == 1 ? "<BEGIN_0>第一段<END_0><BEGIN_1>未完成" : "<BEGIN_0>第二段<END_0>"
        let event: [String: Any] = [
            "choices": [["delta": ["content": content], "finish_reason": inputs.count == 1 ? "length" : "stop"]]
        ]
        try await onData(
            Data(
                ("data: " + String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
                    + "\n\ndata: [DONE]\n\n").utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func lengthLimitRetriesOnlyUnfinishedTextWithBoundedLargerBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = LengthLimitedTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let paper = Paper(
        title: "Fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "FIRST_ONLY"), TextBlock(sourcePage: 0, text: "SECOND_ONLY")],
        warnings: [], canReflow: true)
    model.state.papers = [paper]
    #expect(await model.save())
    model.select(paper.id)
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    model.startTranslation()
    for _ in 0..<300 {
        if model.translating.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.paper?.translatedBlockCount == 2)
    let inputs = await transport.inputs
    #expect(inputs.count == 2)
    #expect(!inputs[1].contains("FIRST_ONLY"))
    #expect(inputs[1].contains("SECOND_ONLY"))
    #expect(await transport.budgets == [8192, 16384])
    #expect(model.translationPauseReason == nil)
}

@MainActor private final class PendingCredentials: ModelCredentialStore {
    var waiting = false
    var continuation: CheckedContinuation<String, Never>?
    func load(account: String) throws -> String {
        Issue.record("Synchronous credential read on UI path")
        return ""
    }
    func save(_ value: String, account: String) throws {}
    func loadForRequest(account: String) async throws -> String {
        let value = await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
        try Task.checkCancellation()
        return value
    }
}

@Test @MainActor func credentialAuthorizationWaitDoesNotBlockUIAndCancelledReadNeverSendsRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = PendingCredentials()
    let transport = LengthLimitedTransport()
    let model = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await model.load()
    let paper = Paper(
        title: "Fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Evidence")], warnings: [], canReflow: true)
    model.state.papers = [paper]
    model.select(paper.id)
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    model.startTranslation()
    for _ in 0..<100 {
        if credentials.waiting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(credentials.waiting)
    model.touch()
    model.pauseTranslation()
    credentials.continuation?.resume(returning: "fixture-key")
    credentials.continuation = nil
    for _ in 0..<100 {
        if model.translating.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.inputs.isEmpty)
    #expect(model.paper?.translatedBlockCount == 0)
}
