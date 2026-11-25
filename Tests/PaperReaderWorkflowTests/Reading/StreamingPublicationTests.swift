import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

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
    var other = Paper(
        title: "Other", digest: "other", originalPath: "other.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: true)
    other.reflowJob = paper.reflowJob
    model.state.papers = [paper, other]
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
    model.select(other.id)
    model.startAIReflow()
    model.pauseTranslation()
    #expect(!model.isReflowPlaying(other.id))
    #expect(model.isReflowPlaying(paper.id))
    await model.translationTasks[other.id]?.value
    model.select(paper.id)
    model.openRetainedReading(nil)
    let originalTask = try #require(model.translationTasks[paper.id])
    model.pauseTranslation()
    #expect(model.showingReflowLoading && !model.isReflowPlaying(paper.id))
    model.startAIReflow()
    #expect(model.translationTasks[paper.id] == originalTask)
    credentials.continuation?.resume(returning: "fixture-key")
    credentials.continuation = nil
    await originalTask.value
    #expect(model.translating.isEmpty && model.showingReflowLoading)
    #expect(model.translationPauseReason == nil && model.paper?.reflowJob?.failure == nil)
    #expect(await transport.calls == 0)
    #expect(model.paper?.translatedBlockCount == 0)
}

@Test(arguments: [false, true])
@MainActor func failedSourcePreparationKeepsTheReadersNewSelection(switchPaper: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = PendingCredentials()
    let transport = NoRequestTransport()
    let model = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await model.load()
    var source = Paper(
        title: "Source", digest: "source", originalPath: "original.pdf", pageCount: 2,
        blocks: [], warnings: [], canReflow: true)
    source.onlineSource = OnlinePaperSource(candidateID: "https://arxiv.org/abs/0000.00000v1")
    var other = Paper(
        title: "Published", digest: "other", originalPath: "other.pdf", pageCount: 2,
        blocks: [], warnings: [], canReflow: true)
    other.translatedPages = [PageArtifact(blockIDs: [], sourcePage: 0, relativePath: "published.pdf")]
    model.state.papers = [source, other]
    model.select(source.id)
    var settings = model.modelSettings
    settings.model = "test"
    try model.saveSettings(settings, key: nil)
    model.startAIReflow()
    let task = try #require(model.translationTasks[source.id])
    for _ in 0..<100 {
        if credentials.waiting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let pendingKey = try #require(credentials.continuation)
    if switchPaper {
        model.select(other.id)
        model.openRetainedReading(nil)
    } else {
        model.readOriginal()
        model.navigateToPage(1)
    }
    pendingKey.resume(returning: "")
    credentials.continuation = nil
    await task.value
    #expect(model.selectedPaperID == (switchPaper ? other.id : source.id))
    #expect(model.mode == (switchPaper ? "translated" : "original"))
    #expect(model.visiblePage == (switchPaper ? 0 : 1))
    #expect(model.message == nil)
    #expect(model.translationPauseReason == nil)
    #expect(model.reflowStages[source.id]?.contains("API Key") == true)
    #expect(await transport.calls == 0)
    await model.flushReadingPosition()
}
