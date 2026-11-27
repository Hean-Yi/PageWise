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

private struct FailingAssistantTransport: HTTPTransport {
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        throw ReaderError.message("模拟模型服务暂时不可用")
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ReaderError.message("模拟模型服务暂时不可用")
    }
}

@Test @MainActor func isModelReadyForRequestsTracksKeySaveAndRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = WorkflowCredentials()
    credentials.values = [:]
    let model = try ReaderModel(root: root, credentials: credentials)
    await model.load()
    // Default model preset may be populated, but without a key requests must not be considered ready.
    #expect(!model.isModelReadyForRequests)

    var draft = model.modelSettings
    draft.baseURL = "https://example.invalid/v1"
    draft.model = "ready-check-model"
    try model.saveSettings(draft, key: "secret-fixture")
    #expect(model.isModelReadyForRequests)

    try model.saveSettings(draft, key: "", removeKey: true)
    #expect(!model.isModelReadyForRequests)

    // Persisted credential removal survives restart without prompting Keychain at launch.
    let reopened = try ReaderModel(root: root, credentials: credentials)
    await reopened.load()
    #expect(!reopened.isModelReadyForRequests)

    // Local .env / validation key counts as ready even with empty Keychain.
    let localModel = try ReaderModel(
        root: root, credentials: credentials,
        translationValidation: .init(settings: draft, key: "local-env-key"))
    await localModel.load()
    #expect(localModel.isModelReadyForRequests)
}

@Test @MainActor func paperAssistantRecordsInlineFailureWithOriginalQuestionForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = WorkflowCredentials()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: FailingAssistantTransport()), credentials: credentials)
    await model.load()
    var settings = model.modelSettings
    settings.baseURL = "https://example.invalid/v1"
    settings.model = "failing-model"
    try model.saveSettings(settings, key: "fixture-key")
    let paper = Paper(
        title: "Inline Error Paper", digest: "inline-err", originalPath: "paper.pdf", pageCount: 1,
        blocks: [.init(sourcePage: 0, text: "Sample text.")], warnings: [], canReflow: true)
    model.state.papers = [paper]
    model.select(paper.id)

    await model.ask("核心贡献是什么？")
    let failure = try #require(model.lastAssistantFailure)
    #expect(failure.paperID == paper.id)
    #expect(failure.question == "核心贡献是什么？")
    #expect(failure.message.contains("模拟模型服务暂时不可用"))
    #expect(model.message == nil)
}
