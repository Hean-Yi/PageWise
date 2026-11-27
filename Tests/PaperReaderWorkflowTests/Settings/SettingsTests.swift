import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

private actor ConnectionTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        requests.append(request)
        try await onData(
            Data(
                "data: {\"choices\":[{\"delta\":{\"content\":\"Answer [S1]\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                    .utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            Data(#"{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test @MainActor func sidebarUsesTheTranslationAccountAndFollowsSavedServiceChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var approved = ModelSettings()
    approved.baseURL = "https://api.deepseek.com"
    approved.model = "deepseek-flash"
    let credentials = WorkflowCredentials()
    credentials.values = [:]
    let transport = ConnectionTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: credentials,
        translationValidation: .init(settings: approved, key: "local-fixture"))
    await model.load()
    let paper = Paper(
        title: "Shared service", digest: "fixture", originalPath: "paper.pdf", pageCount: 1,
        blocks: [.init(sourcePage: 0, text: "A source paragraph.")], warnings: [], canReflow: true)
    model.state.papers = [paper]
    model.select(paper.id)
    let agent = LibraryAgent(reader: model, client: AgentClient(transport: transport))

    #expect(model.modelSettings == approved)
    var next = approved
    next.baseURL = "https://example.invalid/v1"
    next.model = "second-fixture-model"
    for (settings, key) in [(approved, "local-fixture"), (next, "saved-fixture")] {
        if settings == next {
            #expect(!model.usesLocalModelKey(for: next))
            await #expect(throws: (any Error).self) { try await model.testModelConnection(next, key: "") }
            try model.saveSettings(next, key: key)
        }
        let start = await transport.requests.count
        await model.ask("What does the source say?")
        #expect(await transport.requests.count == start + 1)
        // Memory proposals now travel through declarative tool calls inside the main turn, so no
        // extra trailing extraction request is sent.
        await model.ask("I am studying whether the comparison uses equal training budgets.")
        #expect(await transport.requests.count == start + 2)
        await model.summarize()
        agent.send("Library question")
        for _ in 0..<500 where agent.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let requests = await transport.requests.dropFirst(start)
        #expect(requests.count == 4)
        #expect(model.state.chats.last?.answer == "Answer [S1]")
        #expect(model.paper?.summary == "OK")
        #expect(agent.turns.last?.answer == "Answer [S1]")
        let endpoint = try settings.endpointURL()
        for request in requests {
            #expect(request.url == endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["model"] as? String == settings.model)
        }
        if settings == approved { #expect(credentials.values.isEmpty) }
    }
}

@Test @MainActor func connectionTestUsesDraftWithoutSavingOrSendingLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ConnectionTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    let original = model.modelSettings
    var draft = original
    draft.baseURL = "https://example.invalid/v1/chat/completions"
    draft.model = "custom-model"
    model.state.papers = [
        Paper(
            title: "private-title", digest: "test", originalPath: "test.pdf", pageCount: 1,
            blocks: [TextBlock(sourcePage: 0, text: "private-content")], warnings: [], canReflow: true)
    ]
    try await model.testModelConnection(draft, key: "test-draft")
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://example.invalid/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-draft")
    let body = String(decoding: request.httpBody!, as: UTF8.self)
    #expect(body.contains("custom-model"))
    #expect(!body.contains("private-"))
    #expect(model.modelSettings == original)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("model-settings.json").path))
    await #expect(throws: (any Error).self) { try await model.testModelConnection(draft, key: "") }
    #expect(await transport.requests.count == 1)
}

@Test @MainActor func failedSettingsSaveKeepsActiveConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = WorkflowCredentials()
    let model = try ReaderModel(root: root, credentials: credentials)
    let original = model.modelSettings
    var draft = original
    draft.model = "new-model"
    try FileManager.default.removeItem(at: root)
    try Data().write(to: root)
    #expect(throws: (any Error).self) { try model.saveSettings(draft, key: "new-key") }
    #expect(model.modelSettings == original)
    #expect(credentials.values == ["model-key": "test-only"])
}

@Test @MainActor func successfulSettingsSaveRestoresAfterRestartWithoutPlaintextKey() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = WorkflowCredentials()
    let model = try ReaderModel(root: root, credentials: credentials)
    var draft = model.modelSettings
    draft.baseURL = "https://example.invalid/v1/"
    draft.model = " new-model "
    try model.saveSettings(draft, key: "new-key")
    let reopened = try ReaderModel(root: root, credentials: credentials)
    #expect(reopened.modelSettings.model == "new-model")
    #expect(reopened.modelSettings.baseURL == "https://example.invalid/v1")
    #expect(try await reopened.hasSavedAPIKey())
    let json = try String(contentsOf: root.appendingPathComponent("model-settings.json"), encoding: .utf8)
    #expect(!json.contains("new-key"))
}
