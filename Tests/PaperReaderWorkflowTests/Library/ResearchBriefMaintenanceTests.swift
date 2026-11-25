import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

@MainActor @Test func researchBriefFollowsAnImportedPaperAndEditedSummaryAndRepairsOnForeground() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let maintenance = reader.researchBriefMaintenance
    await maintenance.worker?.value
    let shelf = try #require(await reader.createShelf(name: "Measurement"))
    let pdf = root.appendingPathComponent("source.pdf")
    try DemoPaper.write(to: pdf)
    let id = try #require(await reader.importURLs([pdf], selectAfterImport: true, shelfID: shelf).first)
    let paper = try #require(reader.paper)
    #expect(paper.id == id)
    var note = ReadingNote(
        paperID: id, contentVersion: paper.digest + ":original-0", anchors: [],
        markdown: "One instrument measured noise.")
    note.placement = .documentEnd
    note.backgroundSources = .init()
    reader.state.readingNotes.append(note)
    #expect(await reader.save())
    await maintenance.worker?.value
    let before = try await reader.researchBrief(matching: "instrument")
    #expect(
        before.topics.contains {
            $0.label == "Measurement" && $0.sources.contains { $0.noteID == note.id && $0.noteOrigin == "aiDiscussion" }
        })
    #expect(reader.isResearchBriefCurrent(before))
    let revision = try #require(await reader.store.committedResearchState()?.1)
    let corrupt = Data("damaged".utf8)
    #expect(try await reader.store.publishResearchCheckpoint(corrupt, revision: revision))
    reader.setActive(false)
    let future = Date().addingTimeInterval(7 * 3600)
    maintenance.tick(now: future)
    #expect(maintenance.worker == nil)
    #expect(reader.updateDocumentSummary(id: note.id, markdown: "Spectrum calibration corrected the baseline."))
    #expect(!reader.isResearchBriefCurrent(before))  // Check revocation before the edit reaches disk.
    await reader.flushReadingNotes()
    #expect(maintenance.worker == nil)
    #expect(try await reader.store.readResearchCheckpoint() == corrupt)
    maintenance.setActive(true, now: future)
    await maintenance.worker?.value
    #expect(try await reader.store.readResearchCheckpoint() != corrupt)
    #expect(!before.isCurrent(in: reader.state, excluding: []))
    let changed = try await reader.researchBrief(matching: "calibration")
    #expect(
        changed.topics.flatMap(\.sources).contains { $0.noteID == note.id && $0.excerpt?.contains("corrected") == true }
    )
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    await reopened.researchBriefMaintenance.worker?.value
    let kept = try await reopened.researchBrief(matching: "spectrum")
    #expect(kept.topics.flatMap(\.sources).contains { $0.noteID == note.id })
}

@MainActor @Test func researchBriefMaintenanceSkipsHotPositionAndTranslationSavesInALargeLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let prose = String(repeating: "Synthetic block. ", count: 64)
    state.papers = (0..<48).map { index in
        let blocks = (0..<80).map { TextBlock(sourcePage: $0, text: prose) }
        return Paper(
            title: "Laboratory series \(index)", digest: "d-\(index)", originalPath: "unused.pdf",
            pageCount: 80, blocks: blocks, warnings: [], canReflow: false)
    }
    #expect(try await store.save(state).researchSourcesChanged)
    let maintenance = ResearchBriefMaintenance(store: store, notes: ReadingNoteMemoryIndex())
    let start = Date()
    maintenance.sourcesChanged(now: start)
    await maintenance.worker?.value
    let original = try #require(try await store.readResearchCheckpoint())
    let measured = ContinuousClock.now
    for i in 0..<24 {
        let key = state.papers[i].id.uuidString
        state.workspace[key] = PaperWorkspace()
        state.workspace[key]?.isFavorite = i.isMultiple(of: 2)
        state.papers[i].translations["fixture"] = "\(i)"
        let change = try await store.save(state)
        #expect(!change.researchSourcesChanged)
        maintenance.tick(now: start.addingTimeInterval(Double(i * 60)))
        #expect(maintenance.worker == nil)
    }
    print(
        "research brief: 48 papers / 3840 blocks / 24 mixed workspace-translation commits and minute ticks: \(measured.duration(to: .now)), zero scheduled workers"
    )
    #expect(try await store.readResearchCheckpoint() == original)
    state.papers[0].title = "Updated title"
    #expect(try await store.save(state).researchSourcesChanged)
}
