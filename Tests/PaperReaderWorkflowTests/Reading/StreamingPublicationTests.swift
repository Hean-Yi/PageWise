import Foundation
import PaperReaderKit
import PaperReaderUI
import Testing

private actor NoRequestTransport: HTTPTransport {
    var calls = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        throw URLError(.unsupportedURL)
    }
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
    let transport = NoRequestTransport()
    let model = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await model.load()
    var paper = Paper(
        title: "Fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Evidence")], warnings: [], canReflow: true)
    paper.reflowJob = ReflowJob(sources: paper.blocks)
    paper.reflowJob?.evidenceRoute = "html"
    model.state.papers = [paper]
    model.select(paper.id)
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    model.startAIReflow()
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
    #expect(await transport.calls == 0)
    #expect(model.paper?.translatedBlockCount == 0)
}
