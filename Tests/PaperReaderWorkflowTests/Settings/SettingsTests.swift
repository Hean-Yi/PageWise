import Foundation
import PaperReaderKit
import PaperReaderUI
import Testing

private actor ConnectionTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            Data(#"{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
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
