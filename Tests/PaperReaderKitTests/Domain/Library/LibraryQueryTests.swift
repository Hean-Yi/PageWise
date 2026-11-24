import Foundation
import Testing

@testable import PaperReaderKit

@Test func libraryQueryCombinesCollectionAndTitleTerms() {
    let first = queryPaper("Attention for Retrieval", added: 1)
    let second = queryPaper("ATTENTION for Vision", added: 2)
    let third = queryPaper("Efficient Retrieval", added: 3)
    var state = LibraryState()
    state.papers = [first, second, third]
    var reading = PaperWorkspace()
    reading.status = .reading
    reading.isFavorite = true
    state.workspace[first.id.uuidString] = reading
    var finished = PaperWorkspace()
    finished.status = .finished
    state.workspace[second.id.uuidString] = finished

    #expect(LibraryQuery.papers(in: state, query: " attention RETRIEVAL ").map(\.id) == [first.id])
    #expect(LibraryQuery.papers(in: state, collection: .favorites, query: "vision").isEmpty)
    #expect(LibraryQuery.papers(in: state, collection: .reading).map(\.id) == [first.id])
    #expect(LibraryQuery.papers(in: state, collection: .finished).map(\.id) == [second.id])
    #expect(LibraryQuery.papers(in: state, query: "  ").count == 3)
}

@Test func recentLibrarySortUsesActualOpensWithDeterministicFallback() {
    let first = queryPaper("Alpha", added: 1)
    let second = queryPaper("Beta", added: 2)
    let third = queryPaper("Gamma", added: 3)
    var state = LibraryState()
    state.papers = [second, third, first]
    var opened = PaperWorkspace()
    opened.lastOpenedAt = Date(timeIntervalSince1970: 10)
    state.workspace[first.id.uuidString] = opened

    #expect(LibraryQuery.papers(in: state).map(\.id) == [first.id, third.id, second.id])
    #expect(LibraryQuery.papers(in: state, sort: .added).map(\.id) == [third.id, second.id, first.id])
    #expect(LibraryQuery.papers(in: state, sort: .title).map(\.id) == [first.id, second.id, third.id])
}

@Test func librarySearchCandidatesIncludeMatchingTitlesOnEveryShelfAndInUnfiledPapers() throws {
    let papers = ["Memory Atlas", "Memory Atlas", "Atlas of Memory", "Memory Methods"].enumerated().map {
        queryPaper($0.element, added: TimeInterval($0.offset))
    }
    let methods = try Shelf(name: "Methods")
    let systems = try Shelf(name: "Systems")
    var state = LibraryState()
    state.papers = papers
    try state.apply(.create(methods))
    try state.apply(.create(systems))
    try state.apply(.move(paperID: papers[0].id, shelfID: methods.id))
    try state.apply(.move(paperID: papers[1].id, shelfID: systems.id))
    state.workspace[papers[0].id.uuidString] = PaperWorkspace(isFavorite: true)
    state.workspace[papers[1].id.uuidString] = PaperWorkspace(status: .finished)

    let hits = LibraryQuery.searchCandidates(in: state, query: "  atlas  MEMORY ").map(\.id)
    #expect(Set(hits) == Set(papers.prefix(3).map(\.id)))
    #expect(hits.count == 3)
    #expect(LibraryQuery.searchCandidates(in: state, query: " \n\t").isEmpty)
    #expect(LibraryQuery.searchCandidates(in: state, query: "vision").isEmpty)
}

@Test(arguments: LibrarySort.allCases)
func allLibrarySortsKeepUnfinishedFirstAndPreserveOrderWithinEachGroup(sort: LibrarySort) throws {
    let entries: [(String, TimeInterval, TimeInterval?, PaperReadingStatus, String?)] = [
        ("Zebra", 1, 20, .reading, "original-0"),
        ("Alpha", 5, 10, .unread, "original-1"),
        ("Alpha", 5, 10, .reading, nil),
        ("Able", 10, 40, .finished, "original-0"),
        ("Zulu", 6, 30, .reading, "original-1"),
        ("Able", 10, 40, .finished, nil),
    ]
    var state = LibraryState()
    for (index, entry) in entries.enumerated() {
        var paper = queryPaper(entry.0, added: entry.1)
        paper.id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)))
        state.papers.append(paper)
        state.workspace[paper.id.uuidString] = PaperWorkspace(
            isFavorite: true, status: entry.3, lastOpenedAt: entry.2.map(Date.init(timeIntervalSince1970:)),
            position: entry.4.map { ReaderPosition(mode: "original", pageKey: $0, pageIndex: 99) })
    }
    let expected: [Int]
    switch sort {
    case .recent: expected = [0, 1, 2, 3, 5, 4]
    case .added, .title, .manual: expected = [1, 2, 0, 3, 5, 4]
    }
    let papers = state.papers
    state.papers.reverse()
    #expect(LibraryQuery.papers(in: state, sort: sort).map(\.id) == expected.map { papers[$0].id })
}

@Test(arguments: LibraryCollection.allCases)
func libraryCollectionMembershipMatchesQueriesForLegacyCompletionAndFavorites(collection: LibraryCollection) {
    let automatic = queryPaper("Legacy completion", added: 3)
    let manual = queryPaper("Manual completion", added: 4)
    let reading = queryPaper("Still reading", added: 1)
    let unread = queryPaper("Marked unread", added: 2)
    let unknown = queryPaper("Unknown position", added: 5)
    let finalPage = ReaderPosition(mode: "original", pageKey: "original-1", pageIndex: 0)
    var state = LibraryState()
    state.papers = [automatic, manual, reading, unread, unknown]
    state.workspace[automatic.id.uuidString] = PaperWorkspace(
        isFavorite: true, status: .reading, position: finalPage)
    state.workspace[manual.id.uuidString] = PaperWorkspace(status: .finished)
    state.workspace[reading.id.uuidString] = PaperWorkspace(isFavorite: true, status: .reading)
    state.workspace[unread.id.uuidString] = PaperWorkspace(isFavorite: true, status: .unread, position: finalPage)
    state.workspace[unknown.id.uuidString] = PaperWorkspace(
        status: .reading, position: ReaderPosition(mode: "original", pageKey: "missing", pageIndex: 1))
    let expected: Set<UUID>
    switch collection {
    case .all: expected = Set(state.papers.map(\.id))
    case .reading: expected = [reading.id, unknown.id]
    case .finished: expected = [automatic.id, manual.id]
    case .favorites: expected = [automatic.id, reading.id, unread.id]
    }
    let matching = state.papers.filter {
        collection.includes(state.workspace[$0.id.uuidString] ?? PaperWorkspace(), for: $0)
    }
    #expect(Set(matching.map(\.id)) == expected)
    #expect(Set(LibraryQuery.papers(in: state, collection: collection).map(\.id)) == expected)
    #expect(LibraryQuery.papers(in: state, collection: collection).count == matching.count)
    #expect(state.workspace[automatic.id.uuidString]?.status == .reading)
}

private func queryPaper(_ title: String, added: TimeInterval) -> Paper {
    var paper = Paper(
        title: title, digest: title, originalPath: "fixture.pdf", pageCount: 2,
        blocks: [], warnings: [], canReflow: false)
    paper.addedAt = Date(timeIntervalSince1970: added)
    return paper
}
