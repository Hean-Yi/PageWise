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
    var pendingSearch: [String: CheckedContinuation<[PaperCandidate], Never>] = [:]
    var pendingDownload: CheckedContinuation<Void, Never>?
    var downloads = 0
    var failSearch = false
    var failDownload = false
    var returnedURL: URL?
    init(source: URL? = nil, holdSearch: Bool = false, holdDownload: Bool = false) {
        self.source = source
        self.holdSearch = holdSearch
        self.holdDownload = holdDownload
    }
    func search(_ query: String) async throws -> [PaperCandidate] {
        if failSearch { throw ReaderError.message("离线查找失败") }
        if holdSearch { return await withCheckedContinuation { pendingSearch[query] = $0 } }
        return [onlineFixtureCandidate()]
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
    func setFailures(search: Bool = false, download: Bool = false) {
        failSearch = search
        failDownload = download
    }
}

@MainActor private func onlineModel() async throws -> ReaderModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try ReaderModel(root: root)
    await model.load()
    return model
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
    await discovery.setFailures(search: true)
    search.query = "fixture"
    search.search()
    await search.searchTask?.value
    #expect(search.error == "离线查找失败")
    await discovery.setFailures(download: true)
    search.search()
    await search.searchTask?.value
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
