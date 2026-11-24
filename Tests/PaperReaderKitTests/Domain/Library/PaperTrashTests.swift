import Foundation
import Testing

@testable import PaperReaderKit

@Test func paperTrashMigratesVersionTenAndRestoresRelativeOrderWhenSeveralPapersAreRemoved() throws {
    var state = LibraryState()
    state.papers = ["A", "B", "C"].map {
        Paper(
            title: $0, digest: $0, originalPath: "original.pdf", pageCount: 1, blocks: [], warnings: [],
            canReflow: false)
    }
    let order = state.papers.map(\.id)
    state.manualPaperIDs = order
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    legacy["version"] = 10
    legacy["trashedPapers"] = nil
    var migrated = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(migrated.version == LibraryState.currentVersion && migrated.trashedPapers.isEmpty)
    let date = Date()
    for index in [1, 0, 2] { try migrated.apply(.trash(order[index], at: date)) }
    for index in [1, 2, 0] { try migrated.apply(.restore(order[index], deletedAt: date)) }
    #expect(migrated.papers.map(\.id) == order && migrated.manualPaperIDs == order)
}
