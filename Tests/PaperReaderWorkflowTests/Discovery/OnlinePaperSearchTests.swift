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

@Test(arguments: [
    ("$β$-OPSD", "β-OPSD"),
    (#"$\beta$-OPSD"#, "β-OPSD"),
    (#"A \(β\) and $$y$$"#, "A β and y"),
    (#"$ β $ and $$ \beta $$ and \[\beta\]"#, "β and β and β"),
    (#"Keep $x^2$, $\unknown$, and $abc$"#, #"Keep $x^2$, $\unknown$, and $abc$"#),
    (#"Costs $10 and $20; literal \$z$; then $x$"#, #"Costs $10 and $20; literal \$z$; then x"#),
    (#"Unclosed $β and \(\beta"#, #"Unclosed $β and \(\beta"#),
])
func onlineResultTitleDisplaysUnambiguousSymbolsAndRetainsRawMetadata(raw: String, expected: String) {
    var candidate = onlineFixtureCandidate()
    candidate.title = raw
    #expect(candidate.displayTitle == expected)
    #expect(candidate.title == raw && candidate.landingURL?.absoluteString == candidate.id)
}

private actor InlineDiscoveryFixture: PaperDiscovery {
    let source: URL?
    let holdSearch: Bool
    let holdDownload: Bool
    let resolvedFullText: PaperCandidate?
    let searchResults: [PaperCandidate]
    let initialResults: [PaperCandidate]?
    var pendingSearch: [String: CheckedContinuation<[PaperCandidate], Never>] = [:]
    var pendingDownload: CheckedContinuation<Void, Never>?
    var downloads = 0
    var searchFailure: ArxivQueryError?
    var failDownload = false
    var returnedURL: URL?
    init(
        source: URL? = nil, holdSearch: Bool = false, holdDownload: Bool = false,
        searchResults: [PaperCandidate] = [onlineFixtureCandidate()], initialResults: [PaperCandidate]? = nil,
        resolvedFullText: PaperCandidate? = nil
    ) {
        self.source = source
        self.holdSearch = holdSearch
        self.holdDownload = holdDownload
        self.searchResults = searchResults
        self.initialResults = initialResults
        self.resolvedFullText = resolvedFullText
    }
    func discover(
        _ query: String, scope: PaperSearchScope, limit: Int, onUpdate: @Sendable (OnlineDiscoveryResult) async -> Void
    ) async throws -> OnlineDiscoveryResult {
        if let initialResults { await onUpdate(.init(candidates: initialResults)) }
        return .init(candidates: try await search(query))
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
    func downloadPublication(_ candidate: PaperCandidate) async throws -> DownloadedPublication {
        let file = try await download(candidate)
        if let resolvedFullText, resolvedFullText.id == candidate.id {
            return .init(pdfURL: file, candidate: resolvedFullText)
        }
        return .init(pdfURL: file, candidate: candidate)
    }
    func releaseSearch(_ query: String, number: Int) {
        pendingSearch.removeValue(forKey: query)?.resume(returning: [onlineFixtureCandidate(number)])
    }
    func releaseSearch(_ query: String, results: [PaperCandidate]) {
        pendingSearch.removeValue(forKey: query)?.resume(returning: results)
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
    search.query = " new "
    search.search()
    while await discovery.pendingSearch["new"] == nil { await Task.yield() }
    search.query = "unsubmitted edit"
    await discovery.releaseSearch("new", number: 2)
    await search.searchTask?.value
    await discovery.releaseSearch("old", number: 1)
    await oldTask?.value
    #expect(search.results.map(\.id) == [onlineFixtureCandidate(2).id])
    #expect(search.resultQuery == "new")
    search.query = ""
    #expect(search.resultQuery == "new")
    search.query = "closed"
    search.search()
    let closingTask = search.searchTask
    while await discovery.pendingSearch["closed"] == nil { await Task.yield() }
    search.close()
    await discovery.releaseSearch("closed", number: 3)
    await closingTask?.value
    #expect(!search.isExpanded)
    #expect(search.results.isEmpty)
    #expect(search.resultQuery == nil)
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
    var candidate = onlineFixtureCandidate()
    candidate.title = #"$\beta$-OPSD Fixture"#
    let discovery = InlineDiscoveryFixture(source: source, holdDownload: true, searchResults: [candidate])
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: first)
    search.query = "OPSD"
    search.search()
    await search.searchTask?.value
    #expect(await discovery.downloads == 0)
    search.confirmImport(candidate)
    while await discovery.pendingDownload == nil { await Task.yield() }
    search.open(shelfID: second)
    #expect(search.targetShelfID == second)
    #expect(search.importProgress.contains("First"))
    #expect(search.results.map(\.id) == [candidate.id])
    await discovery.releaseDownload()
    await search.importTask?.value
    let id = try #require(search.imported[candidate.id])
    #expect(model.state.shelfID(for: id) == first)
    #expect(model.selectedPaperID == nil)
    #expect(search.isExpanded && search.targetShelfID == second)
    #expect(search.importedPaperID(for: candidate) == nil)
    search.open(shelfID: first)
    #expect(search.importedPaperID(for: candidate) == id)
    search.confirmImport(candidate)
    #expect(await discovery.downloads == 1)
    let restarted = try ReaderModel(root: model.root)
    await restarted.load()
    #expect(restarted.state.shelfID(for: id) == first)
    let saved = try #require(restarted.state.papers.first { $0.id == id })
    #expect(saved.title == candidate.title)
    let displayed = saved.displayTitle
    #expect(displayed == "β-OPSD Fixture" && displayed == candidate.displayTitle)
    #expect(SearchTermMatches.ranges(in: displayed, query: "OPSD").map { String(displayed[$0]) } == ["OPSD"])
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
        #expect(!search.isExpanded)
        search.open(shelfID: nil)
        #expect(search.isExpanded && search.targetShelfID == nil)
    }
    let task = search.importTask
    await discovery.releaseDownload()
    await task?.value
    #expect(model.state.papers.isEmpty)
    #expect(model.state.paperShelfIDs.isEmpty)
    #expect((search.importErrors[onlineFixtureCandidate().id] != nil) == deleteTarget)
    #expect(search.isExpanded)
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

@MainActor @Test func onlineShelfChangeKeepsThePendingSearchAndNewQueryStillSupersedesIt() async throws {
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
    #expect(search.isSearching && search.searchTask == firstTask)
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
        if originalID == nil {
            search.query = "fixture"
            search.search()
            await search.searchTask?.value
        }
        #expect(search.results.map(\.id) == [onlineFixtureCandidate().id])
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

@MainActor @Test func onlineSameTitleWithDifferentSourceAndPDFShowsTheConflictOnThatCandidate() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let source = model.root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: source)
    let first = onlineFixtureCandidate()
    var second = onlineFixtureCandidate(2)
    second.title = first.title
    let discovery = InlineDiscoveryFixture(source: source, searchResults: [first, second])
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: nil)
    search.query = first.title
    search.search()
    await search.searchTask?.value
    search.confirmImport(first)
    await search.importTask?.value
    let original = try #require(search.importedPaperID(for: first))
    let bytes = try Data(contentsOf: source)
    try (bytes + Data("\n% distinct publication\n".utf8)).write(to: source)
    #expect(search.importedPaperID(for: second) == nil)
    search.confirmImport(second)
    await search.importTask?.value
    #expect(model.state.papers.map(\.id) == [original])
    #expect(search.importErrors[second.id]?.contains("同名论文") == true)
    #expect(search.importErrors[first.id] == nil && search.importedPaperID(for: second) == nil)
}

@MainActor @Test func onlineAutomaticDownloadResolvesTheSelectedVersionAndPreservesItsOrigin() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let source = model.root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: source)
    let metadata = PaperCandidate(
        id: "https://doi.org/10.1234/test", title: "Metadata", authors: "", year: "", source: .crossref)
    let publication = PaperCandidate(
        id: "https://doi.org/10.18653/v1/2025.acl-long.12", title: "Publisher fixture", authors: "", year: "2025",
        source: .crossref)
    var preprint = onlineFixtureCandidate()
    preprint.alternateVersions = [publication]
    var resolved = metadata
    resolved.pdfURL = URL(string: "https://link.springer.com/content/pdf/10.1234/test.pdf")
    let discovery = InlineDiscoveryFixture(
        source: source, searchResults: [metadata, preprint], resolvedFullText: resolved)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: nil)
    search.query = "fixture"
    search.search()
    await search.searchTask?.value
    #expect(search.results.count == 2)
    #expect(search.results.first?.landingURL?.host == "doi.org")
    #expect(await discovery.downloads == 0 && !metadata.canDownload && metadata.canAttemptDownload)
    search.confirmImport(metadata)
    search.confirmImport(metadata)
    await search.importTask?.value
    let resolvedID = try #require(search.importedPaperID(for: metadata))
    #expect(await discovery.downloads == 1)
    #expect(model.state.papers.first?.onlineSource?.candidateID == metadata.id)
    // Use different file contents for the next edition so SHA-256 deduplication does not merge them.
    let bytes = try Data(contentsOf: source)
    try (bytes + Data("\n% different edition\n".utf8)).write(to: source)
    search.confirmImport(publication)
    await search.importTask?.value
    let paper = try #require(model.state.papers.first)
    #expect(paper.title == publication.title && paper.id != resolvedID)
    #expect(await discovery.downloads == 2)
    #expect(paper.onlineSource?.candidateID == publication.id)
    #expect(paper.onlineSource?.originalPDFOnly == true)
    #expect(!paper.canReflow && paper.usesSourceReflow)
    model.select(paper.id)
    #expect(model.openBilingualReading(translatingDocument: true))
    #expect(model.message == paper.onlineSource?.notice)
    #expect(!model.pdfBilingual.isOpen && model.translating.isEmpty)
    let restarted = try ReaderModel(root: model.root)
    await restarted.load()
    #expect(restarted.state.papers.first(where: { $0.id == paper.id })?.onlineSource == paper.onlineSource)
}

@MainActor @Test func publisherFileSelectionImportsTheRegisteredVersionIntoTheTargetShelfAndOpensItAfterRestart()
    async throws
{
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let pdf = model.root.appendingPathComponent("reader-copy.pdf")
    try DemoPaper.write(to: pdf)
    let first = try #require(await model.createShelf(name: "First"))
    let second = try #require(await model.createShelf(name: "Second"))
    let publication = PaperCandidate(
        id: "https://doi.org/10.1234/edition", title: "Published edition", authors: "Ada", year: "2025",
        source: .crossref)
    var preprint = onlineFixtureCandidate()
    preprint.alternateVersions = [publication]
    let discovery = InlineDiscoveryFixture(searchResults: [preprint])
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    var submitted = publication
    submitted.title = "Untrusted callback title"
    search.open(shelfID: first)
    search.query = "edition"
    search.search()
    await search.searchTask?.value
    #expect(!search.choosePDF(for: preprint))
    search.importSelectedPDF(pdf)
    #expect(search.importTask == nil)
    #expect(search.choosePDF(for: submitted))
    search.open(shelfID: second)
    #expect(search.targetShelfID == second)
    search.importSelectedPDF(pdf)
    await search.importTask?.value
    let id = try #require(search.imported[publication.id])
    #expect(search.importedPaperID(for: publication) == nil)
    #expect(search.importedPaperID(for: preprint) == nil)
    #expect(model.selectedPaperID == nil)
    #expect(model.state.papers.first?.title == publication.title)
    #expect(model.state.shelfID(for: id) == first)
    #expect(FileManager.default.fileExists(atPath: pdf.path))
    search.importSelectedPDF(pdf)
    #expect(search.importTask == nil)

    let restarted = try ReaderModel(root: model.root, credentials: WorkflowCredentials())
    await restarted.load()
    let restoredSearch = OnlinePaperSearch(reader: restarted, discovery: discovery)
    restoredSearch.open(shelfID: first)
    restoredSearch.query = "edition"
    restoredSearch.search()
    await restoredSearch.searchTask?.value
    #expect(restoredSearch.importedPaperID(for: publication) == id)
    restoredSearch.openImported(publication)
    #expect(restarted.selectedPaperID == id)
    restoredSearch.open(shelfID: second)
    restoredSearch.search()
    await restoredSearch.searchTask?.value
    #expect(restoredSearch.importedPaperID(for: publication) == nil)
    #expect(restoredSearch.choosePDF(for: publication))
    restoredSearch.importSelectedPDF(pdf)
    await restoredSearch.importTask?.value
    #expect(restoredSearch.importedPaperID(for: publication) == id)
    #expect(restarted.state.papers.count == 1 && restarted.state.shelfID(for: id) == second)
    #expect(await discovery.downloads == 0)
}

@MainActor @Test func publisherFileSelectionCanCancelAndRetryWithoutLateWritesOrDownloads() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let pdf = model.root.appendingPathComponent("reader-copy.pdf")
    try DemoPaper.write(to: pdf)
    let candidate = PaperCandidate(
        id: "https://doi.org/10.1234/edition", title: "Selected publication", authors: "", year: "", source: .crossref)
    let discovery = InlineDiscoveryFixture(searchResults: [candidate])
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: nil)
    search.query = "edition"
    search.search()
    await search.searchTask?.value
    #expect(search.choosePDF(for: candidate))
    search.cancelFileSelection()
    search.importSelectedPDF(pdf)
    search.fileSelectionFailed(ReaderError.message("旧文件选择器"))
    #expect(search.importTask == nil && search.importErrors.isEmpty && model.state.papers.isEmpty)
    #expect(search.choosePDF(for: candidate))
    search.importSelectedPDF(pdf)
    search.close()
    await search.importTask?.value
    #expect(!search.isExpanded)
    #expect(search.imported.isEmpty && model.state.papers.isEmpty)
    search.importSelectedPDF(pdf)
    #expect(search.importTask == nil)

    search.open(shelfID: nil)
    #expect(search.choosePDF(for: candidate))
    search.importSelectedPDF(model.root.appendingPathComponent("missing.pdf"))
    await search.importTask?.value
    #expect(search.importErrors[candidate.id] != nil && search.imported.isEmpty)
    #expect(search.choosePDF(for: candidate))
    search.importSelectedPDF(pdf)
    await search.importTask?.value
    #expect(search.importErrors[candidate.id] == nil && search.importedPaperID(for: candidate) != nil)
    #expect(await discovery.downloads == 0)
}

@MainActor @Test(arguments: [false, true]) func publisherFileSelectionKeepsTheEditionWhenLaterIndexesRerankIt(
    gainsDownload: Bool
) async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let pdf = model.root.appendingPathComponent("reader-copy.pdf")
    try DemoPaper.write(to: pdf)
    let chosen = PaperCandidate(
        id: "https://doi.org/10.1234/edition", title: "Early title", authors: "", year: "", source: .crossref)
    let discovery = InlineDiscoveryFixture(source: pdf, holdSearch: true, initialResults: [chosen])
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: nil)
    search.query = "edition"
    search.search()
    while await discovery.pendingSearch["edition"] == nil { await Task.yield() }
    #expect(search.choosePDF(for: chosen))
    var final = onlineFixtureCandidate()
    var updated = chosen
    if gainsDownload {
        updated.title = "Later record"
        updated.pdfURL = URL(string: "https://link.springer.com/content/pdf/10.1234/edition.pdf")
        #expect(updated.canDownload)
        final.alternateVersions = [updated]
    }
    await discovery.releaseSearch("edition", results: [final])
    await search.searchTask?.value
    #expect(search.results.flatMap { [$0] + $0.alternateVersions }.contains { $0.id == chosen.id })
    search.importSelectedPDF(pdf)
    await search.importTask?.value
    let paper = try #require(model.state.papers.first)
    #expect(model.state.papers.count == 1 && paper.title == chosen.title && paper.onlineSource == nil)
    #expect(search.importedPaperID(for: chosen) == paper.id && search.importedPaperID(for: final) == nil)
    #expect(await discovery.downloads == 0)
    if gainsDownload {
        #expect(search.importedPaperID(for: updated) == nil)
        search.confirmImport(updated)
        await search.importTask?.value
        #expect(await discovery.downloads == 1)
        #expect(search.importedPaperID(for: updated) == paper.id)
        #expect(model.state.papers.first?.onlineSource?.candidateID == updated.id)
    }
}

@MainActor @Test func failedOpenDownloadOffersFileSelectionAndOpensTheImportedCopy() async throws {
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let pdf = model.root.appendingPathComponent("reader-copy.pdf")
    try DemoPaper.write(to: pdf)
    let candidate = PaperCandidate(
        id: "https://doi.org/10.18653/v1/2025.acl-long.12", title: "Open publication", authors: "", year: "2025",
        source: .crossref)
    let discovery = InlineDiscoveryFixture(source: pdf, searchResults: [candidate])
    await discovery.setFailures(download: true)
    let search = OnlinePaperSearch(reader: model, discovery: discovery)
    search.open(shelfID: nil)
    search.query = "edition"
    search.search()
    await search.searchTask?.value
    #expect(!search.choosePDF(for: candidate))
    search.confirmImport(candidate)
    await search.importTask?.value
    #expect(search.importErrors[candidate.id] != nil)
    #expect(search.choosePDF(for: candidate))
    search.importSelectedPDF(pdf)
    await search.importTask?.value
    let paper = try #require(model.state.papers.first)
    #expect(search.importErrors[candidate.id] == nil && search.importedPaperID(for: candidate) == paper.id)
    #expect(paper.onlineSource == nil)
    search.openImported(candidate)
    #expect(model.selectedPaperID == paper.id && model.state.papers.count == 1)
    #expect(await discovery.downloads == 1)
}

@MainActor @Test func identicalPublisherPDFGainsPinnedPreprintSourceWithoutLosingCitationOrDuplicatingPaper()
    async throws
{
    let model = try await onlineModel()
    defer { try? FileManager.default.removeItem(at: model.root) }
    let url = model.root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: url)
    let publisher = PaperCandidate(
        id: "https://doi.org/10.18653/v1/2025.acl-long.12", title: "Journal edition", authors: "", year: "2025",
        source: .crossref)
    let preprint = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Preprint title", authors: "", year: "2024",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1")!)
    let ids = await model.importURLs([url], metadata: publisher)
    let first = try #require(model.paper)
    let notice = try #require(first.onlineSource?.notice)
    #expect(await model.importURLs([url], metadata: preprint) == ids)
    let upgraded = try #require(model.paper)
    #expect(model.state.papers.count == 1 && upgraded.id == first.id)
    #expect(upgraded.sourceURL == publisher.id && upgraded.title == first.title)
    #expect(upgraded.canReflow && upgraded.onlineSource?.candidateID == preprint.id)
    #expect(!upgraded.warnings.contains(notice))
}
