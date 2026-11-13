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

private func queryPaper(_ title: String, added: TimeInterval) -> Paper {
    var paper = Paper(
        title: title, digest: title, originalPath: "fixture.pdf", pageCount: 2,
        blocks: [], warnings: [], canReflow: false)
    paper.addedAt = Date(timeIntervalSince1970: added)
    return paper
}
