import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

private func onlineFixtureCandidate(_ number: Int = 1) -> PaperCandidate {
    let identifier = "2401.0000\(number)"
    return PaperCandidate(
        id: "https://arxiv.org/abs/\(identifier)", title: "Original Fixture \(number)", authors: "Local author",
        year: "2024", pdfURL: URL(string: "https://arxiv.org/pdf/\(identifier)")!)
}

private actor InlineDiscoveryFixture: PaperDiscovery {
    let source: URL?
    let holdSearch: Bool
    let holdDownload: Bool
    let searchResults: [PaperCandidate]
    var pendingSearch: [String: CheckedContinuation<[PaperCandidate], Never>] = [:]
    var pendingDownload: CheckedContinuation<Void, Never>?
    var downloads = 0
    var searchFailure: ArxivQueryError?
    var failDownload = false
    var returnedURL: URL?
    init(
        source: URL? = nil, holdSearch: Bool = false, holdDownload: Bool = false,
        searchResults: [PaperCandidate] = [onlineFixtureCandidate()]
    ) {
        self.source = source
        self.holdSearch = holdSearch
        self.holdDownload = holdDownload
        self.searchResults = searchResults
    }
    func search(_ query: String) async throws -> [PaperCandidate] {
        if let searchFailure { throw searchFailure }
        if holdSearch { return await withCheckedContinuation { pendingSearch[query] = $0 } }
        return searchResults
    }
    func download(_ candidate: PaperCandidate) async throws -> URL {
        downloads += 1
        if failDownload { throw ReaderError.message("离线下载失败") }
        if holdDownload { await withCheckedContinuation { pendingDownload = $0 } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        if let source {
            try FileManager.default.copyItem(at: source, to: url)
        } else {
            try Data("invalid fixture".utf8).write(to: url)
        }
        returnedURL = url
        return url
    }
    func releaseSearch(_ query: String, number: Int) {
        pendingSearch.removeValue(forKey: query)?.resume(returning: [onlineFixtureCandidate(number)])
    }
    func releaseDownload() {
        pendingDownload?.resume()
        pendingDownload = nil
    }
    func setFailures(search: ArxivQueryError? = nil, download: Bool = false) {
        searchFailure = search
        failDownload = download
    }
}

@MainActor private func onlineModel() async throws -> ReaderModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await model.load()
    return model
}

@MainActor @Test func onlineRepeatedSubmitKeepsOneRequestAndReportsSuccessfulZeroMatches() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let search = OnlinePaperSearch(reader: model, discovery: InlineDiscoveryFixture(searchResults: []))
    search.open(shelfID: nil)
    search.query = "fixture"
    search.search()
    let task = try #require(search.searchTask)
    search.query = " fixture "
    #expect(!search.canSearch)
    search.search()
    #expect(search.searchTask == task)
    await task.value
    #expect(search.results.isEmpty)
    #expect(search.error == nil)
    #expect(search.searched)
}

@Test(arguments: [
    (ArxivQueryError.http(status: 429, retryAfter: nil), true), (.http(status: 503, retryAfter: nil), true),
    (.network(.notConnectedToInternet), false), (.invalidQuery, false), (.http(status: 403, retryAfter: nil), false),
])
@MainActor func onlineWebFallbackUsesTheFailedTitleOnlyWhenTheServiceIsBusy(
    _ failure: ArxivQueryError, _ offersWebSearch: Bool
) async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let discovery = InlineDiscoveryFixture()
    await discovery.setFailures(search: failure)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    let title = "C++ & 中文 #1?searchtype=all"
    search.query = title
    search.search()
    await search.searchTask?.value
    search.query = "a newer draft"
    #expect((search.webSearchURL != nil) == offersWebSearch)
    if offersWebSearch {
        let url = try #require(search.webSearchURL)
        let page = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(page.scheme == "https" && page.host == "arxiv.org" && page.path == "/search/")
        #expect(page.queryItems == [.init(name: "query", value: title), .init(name: "searchtype", value: "title")])
        #expect(page.percentEncodedQuery?.contains("%2B%2B") == true)
        #expect(page.fragment == nil)
    }
    await discovery.setFailures()
    search.search()
    await search.searchTask?.value
    #expect(search.webSearchURL == nil)
}

private struct OnlineToolReplyEcho: AgentCompleting {
    func respond(settings: ModelSettings, key: String, messages: [AgentMessage], limits: AgentLimits) async throws
        -> AgentMessage
    {
        if let tool = messages.last(where: { $0.toolCallID == "find" }) {
            return .init(role: "assistant", content: tool.content)
        }
        return .init(
            role: "assistant", toolCalls: [.init(id: "find", name: "search_online", arguments: #"{"query":"fixture"}"#)]
        )
    }
}

@Test(arguments: [ArxivQueryError.invalidQuery, .http(status: 429, retryAfter: nil), .network(.timedOut)])
@MainActor func onlineAgentReportsFailureAndWhetherAnotherQueryMightWork(_ failure: ArxivQueryError) async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    var settings = model.modelSettings
    settings.model = "fixture-model"
    try model.saveSettings(settings, key: nil)
    let discovery = InlineDiscoveryFixture()
    await discovery.setFailures(search: failure)
    let agent = LibraryAgent(reader: model, client: OnlineToolReplyEcho(), discovery: discovery)
    agent.send("在线查找 fixture")
    let deadline = ContinuousClock.now + .seconds(5)
    while agent.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let turn = try #require(agent.turns.first)
    #expect(turn.error == nil)
    #expect(turn.activities.first?.status == .failed)
    #expect(turn.activities.first?.message == failure.localizedDescription)
    let payload = try #require(try JSONSerialization.jsonObject(with: Data(turn.answer.utf8)) as? [String: Any])
    #expect(payload["ok"] as? Bool == false)
    #expect(payload["message"] as? String == failure.localizedDescription)
    #expect(payload["can_refine_query"] as? Bool == failure.canRefineQuery)
}

@MainActor @Test func onlineLateSearchCannotReplaceNewerResultsOrReopenClosedArea() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let discovery = InlineDiscoveryFixture(holdSearch: true)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: nil)
    search.query = "old"
    search.search()
    let oldTask = search.searchTask
    while await discovery.pendingSearch["old"] == nil { await Task.yield() }
    search.query = "new"
    search.search()
    while await discovery.pendingSearch["new"] == nil { await Task.yield() }
    await discovery.releaseSearch("new", number: 2)
    await search.searchTask?.value
    await discovery.releaseSearch("old", number: 1)
    await oldTask?.value
    #expect(search.results.map(\.id) == [onlineFixtureCandidate(2).id])
    search.query = "closed"
    search.search()
    let closingTask = search.searchTask
    while await discovery.pendingSearch["closed"] == nil { await Task.yield() }
    search.close()
    await discovery.releaseSearch("closed", number: 3)
    await closingTask?.value
    #expect(!search.isExpanded)
    #expect(search.results.isEmpty)
    #expect(!search.searched)
    #expect(!search.isSearching)
    #expect(search.error == nil)
}

@MainActor @Test func onlineImportRequiresConfirmationKeepsContextAndPersistsMembership() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let first = try #require(await model.createShelf(name: "First"))
    let second = try #require(await model.createShelf(name: "Second"))
    let source = model.root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: source)
    let discovery = InlineDiscoveryFixture(source: source, holdDownload: true)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: first)
    search.query = "Original Fixture 1"
    search.search()
    await search.searchTask?.value
    #expect(await discovery.downloads == 0)
    search.confirmImport(onlineFixtureCandidate())
    while await discovery.pendingDownload == nil { await Task.yield() }
    search.open(shelfID: second)
    #expect(search.targetShelfID == first)
    #expect(search.contextNotice != nil)
    await discovery.releaseDownload()
    await search.importTask?.value
    let id = try #require(search.imported[onlineFixtureCandidate().id])
    #expect(model.state.shelfID(for: id) == first)
    #expect(model.selectedPaperID == nil)
    #expect(search.isExpanded)
    search.confirmImport(onlineFixtureCandidate())
    #expect(await discovery.downloads == 1)
    let restarted = try ReaderModel(root: model.root)
    await restarted.load()
    #expect(restarted.state.shelfID(for: id) == first)
}

@MainActor @Test(arguments: [false, true]) func onlineCloseOrDeletedTargetCannotCommitLateDownload(deleteTarget: Bool)
    async throws
{
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let shelf = try #require(await model.createShelf(name: "Topic"))
    let source = model.root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: source)
    let discovery = InlineDiscoveryFixture(source: source, holdDownload: true)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: shelf)
    search.query = "fixture"
    search.search()
    await search.searchTask?.value
    search.confirmImport(onlineFixtureCandidate())
    while await discovery.pendingDownload == nil { await Task.yield() }
    if deleteTarget {
        #expect(await model.deleteShelf(shelf))
    } else {
        search.close()
        #expect(search.closing)
        #expect(search.isExpanded)
    }
    let task = search.importTask
    await discovery.releaseDownload()
    await task?.value
    #expect(model.state.papers.isEmpty)
    #expect(model.state.paperShelfIDs.isEmpty)
    #expect(search.importErrors[onlineFixtureCandidate().id] != nil)
    #expect(search.isExpanded == deleteTarget)
    let temporary = try #require(await discovery.returnedURL)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
}

@MainActor @Test func onlineFailuresRemainVisibleAndCanRetry() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let source = model.root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: source)
    let discovery = InlineDiscoveryFixture(source: source)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: nil)
    let limited = ArxivQueryError.http(status: 429, retryAfter: nil)
    await discovery.setFailures(search: limited)
    search.query = "fixture"
    search.search()
    await search.searchTask?.value
    #expect(search.error == limited.localizedDescription)
    #expect(!search.searched)
    #expect(search.canSearch)
    await discovery.setFailures(download: true)
    search.search()
    await search.searchTask?.value
    #expect(search.error == nil)
    #expect(search.searched)
    search.confirmImport(onlineFixtureCandidate())
    await search.importTask?.value
    #expect(search.importErrors[onlineFixtureCandidate().id] == "离线下载失败")
    #expect(search.results.count == 1)
    await discovery.setFailures()
    search.confirmImport(onlineFixtureCandidate())
    await search.importTask?.value
    #expect(search.imported[onlineFixtureCandidate().id] != nil)
    #expect(search.importErrors[onlineFixtureCandidate().id] == nil)
}

@MainActor @Test func onlineExplicitTargetSwitchCancelsOldQueryAndKeepsNewResults() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let first = try #require(await model.createShelf(name: "First"))
    let second = try #require(await model.createShelf(name: "Second"))
    let discovery = InlineDiscoveryFixture(holdSearch: true)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: first)
    search.query = "first"
    search.search()
    let firstTask = search.searchTask
    while await discovery.pendingSearch["first"] == nil { await Task.yield() }
    search.open(shelfID: second)
    #expect(search.isExpanded)
    #expect(search.targetShelfID == second)
    #expect(search.results.isEmpty)
    #expect(!search.isSearching)
    search.query = "second"
    search.search()
    while await discovery.pendingSearch["second"] == nil { await Task.yield() }
    await discovery.releaseSearch("second", number: 2)
    await search.searchTask?.value
    await discovery.releaseSearch("first", number: 1)
    await firstTask?.value
    #expect(search.results.map(\.id) == [onlineFixtureCandidate(2).id])
    #expect(search.targetShelfID == second)
}

@MainActor @Test func onlinePreviouslyImportedCandidateCanMoveToNewTargetWithoutDuplicating() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let first = try #require(await model.createShelf(name: "First"))
    let second = try #require(await model.createShelf(name: "Second"))
    let source = model.root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: source)
    let discovery = InlineDiscoveryFixture(source: source)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    var originalID: UUID?
    for target: UUID? in [first, second, nil] {
        search.open(shelfID: target)
        #expect(search.imported.isEmpty)
        #expect(search.results.isEmpty)
        search.query = "fixture"
        search.search()
        await search.searchTask?.value
        search.confirmImport(onlineFixtureCandidate())
        await search.importTask?.value
        let id = try #require(search.imported[onlineFixtureCandidate().id])
        if let originalID { #expect(id == originalID) } else { originalID = id }
        #expect(model.state.papers.count == 1)
        #expect(model.state.shelfID(for: id) == target)
        #expect(search.targetShelfID == target)
    }
    let restarted = try ReaderModel(root: model.root)
    await restarted.load()
    #expect(restarted.state.papers.count == 1)
    #expect(restarted.state.paperShelfIDs.isEmpty)
}
