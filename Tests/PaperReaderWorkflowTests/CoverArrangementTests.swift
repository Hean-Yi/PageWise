import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@MainActor @Test func coverPreviewUsesStationarySlotsAndCancellationNeverChangesLibrary() {
    let state = arrangementFixture()
    let ids = state.papers.map(\.id)
    let drag = CoverArrangement()
    drag.begin(ids[0], visible: ids, state: state, unfinishedFirst: true)
    drag.hover(ids[0], at: ids[2])
    #expect(drag.preview == [ids[1], ids[2], ids[0], ids[3]])
    #expect(drag.offset(for: ids[0]) == 2)
    // Repeated native updates over the same stationary slot cannot oscillate.
    for _ in 0..<10 { drag.hover(ids[0], at: ids[2]) }
    #expect(drag.preview == [ids[1], ids[2], ids[0], ids[3]])
    drag.hover(UUID(), at: ids[1])
    drag.hover(ids[0], at: UUID())
    #expect(drag.preview == [ids[1], ids[2], ids[0], ids[3]])
    drag.end()
    #expect(drag.sourceID == nil)
    #expect(drag.preview.isEmpty)
    #expect(drag.offset(for: ids[0]) == 0)
    #expect(state.manualPaperIDs.isEmpty)
}

@MainActor @Test func coverPreviewRejectsCrossingFinishedGroupAndCanReturnToOriginalSlot() {
    var state = arrangementFixture()
    let ids = state.papers.map(\.id)
    state.workspace[ids[3].uuidString] = PaperWorkspace(status: .finished)
    let drag = CoverArrangement()
    drag.begin(ids[0], visible: ids, state: state, unfinishedFirst: true)
    #expect(!drag.accepts(ids[0], at: ids[3]))
    drag.hover(ids[0], at: ids[3])
    #expect(drag.preview == ids)
    drag.hover(ids[0], at: ids[2])
    drag.hover(ids[0], at: ids[0])
    #expect(drag.preview == ids)
}

@MainActor @Test func dropReservationSurvivesNativeEndAndPersistsAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var initial = arrangementFixture()
    initial.preferredSort = .title
    try await store.save(initial)
    let model = try ReaderModel(root: root)
    await model.load()
    let ids = initial.papers.map(\.id)
    let drag = CoverArrangement()
    drag.begin(ids[0], visible: ids, state: model.state, unfinishedFirst: true)
    drag.hover(ids[0], at: ids[2])
    #expect(drag.reserveDrop())
    #expect(!drag.reserveDrop())
    drag.end()  // AppKit / UIKit ends before the scheduled Task reaches commit.
    #expect(drag.sourceID == ids[0])
    #expect(model.state.manualPaperIDs.isEmpty)
    #expect(await drag.commit(model: model))
    #expect(drag.sourceID == nil)
    #expect(model.state.manualPaperIDs == [ids[1], ids[2], ids[0], ids[3]])
    let restarted = try ReaderModel(root: root)
    await restarted.load()
    #expect(restarted.state.manualPaperIDs == model.state.manualPaperIDs)
    #expect(restarted.state.preferredSort == .manual)
    #expect(await restarted.selectLibrarySort(.added))
    let restored = try await store.load()
    #expect(restored.preferredSort == .added)
    #expect(restored.manualPaperIDs == model.state.manualPaperIDs)
}

@MainActor @Test func failedOrCancelledOrderSaveKeepsPublishedOrderAndResetsPreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var initial = arrangementFixture()
    initial.preferredSort = .title
    try await store.save(initial)
    let model = try ReaderModel(root: root)
    await model.load()
    let ids = initial.papers.map(\.id)
    let cancelled = Task { @MainActor in
        await model.arrangePapers(original: ids, reordered: ids.reversed(), unfinishedFirst: true)
    }
    cancelled.cancel()
    #expect(!(await cancelled.value))
    #expect(model.state.manualPaperIDs.isEmpty)
    let savedRoot = root.appendingPathExtension("saved")
    try FileManager.default.moveItem(at: root, to: savedRoot)
    defer { try? FileManager.default.moveItem(at: savedRoot, to: root) }
    let drag = CoverArrangement()
    drag.begin(ids[0], visible: ids, state: model.state, unfinishedFirst: true)
    drag.hover(ids[0], at: ids[2])
    #expect(drag.reserveDrop())
    #expect(!(await drag.commit(model: model)))
    #expect(model.state.manualPaperIDs.isEmpty)
    #expect(model.state.preferredSort == .title)
    #expect(drag.sourceID == nil)
    #expect(drag.preview.isEmpty)
}

private func arrangementFixture() -> LibraryState {
    var state = LibraryState()
    state.papers = ["A", "B", "C", "D"].map {
        Paper(
            title: $0, digest: $0, originalPath: "fixture.pdf", pageCount: 2, blocks: [], warnings: [], canReflow: false
        )
    }
    return state
}
