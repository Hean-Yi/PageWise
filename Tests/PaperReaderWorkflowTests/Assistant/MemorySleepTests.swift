import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

private func sleepSource(_ statement: String) throws -> MemoryItem {
    try ResearchQuestionProposal(question: statement, readerTurnID: UUID(), readerMessage: statement, quote: statement)
        .item
}

@Test @MainActor func sleepEditionActivatesForRecallSurvivesRestartAndDropsRevokedDependencies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let a = try sleepSource("等计算预算的情况下两个模型谁表现更好？")
    let b = try sleepSource("匹配训练时长后，方法优势还存在吗？")
    reader.state.memories = [a, b]
    await reader.save()
    let store = MemorySleepStore(store: reader.store)
    let edition = try await store.run { _ in
        #"{"groups":[{"kind":"related","members":["\#(a.id)","\#(b.id)"],"summary":"预算公平性要结合训练耗时核对。"}]}"#
    }
    #expect(edition.connections.count == 1)
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    let active = try await reopened.effectiveSleepMemory(question: "训练预算如何核对？", paperID: nil, recalled: [a, b])
    #expect(active.text.contains("预算公平性要结合训练耗时核对"))
    #expect(!active.text.contains(a.text))
    #expect(Set(active.sources.map(\.id)) == [a.id, b.id])
    reopened.deleteMemory(a.id)
    let remaining = try await reopened.effectiveSleepMemory(question: "训练预算如何核对？", paperID: nil, recalled: [b])
    #expect(!remaining.text.contains("预算公平性要结合训练耗时核对"))
    #expect(remaining.text.contains(b.text))
    await reopened.save()
}

@Test @MainActor func sleepRejectsInvalidModelOperationsAndStalePublication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let a = try sleepSource("目前项目使用的数据是否完全一致？")
    let b = try sleepSource("另一个分组对照的结果是否稳定？")
    reader.state.memories = [a, b]
    await reader.save()
    let store = MemorySleepStore(store: reader.store)
    let invalid = try await store.run { _ in
        #"{"groups":[{"kind":"related","members":["\#(a.id)","\#(UUID())"],"summary":"不允许的关联"}]}"#
    }
    #expect(invalid.connections.isEmpty)
    #expect(invalid.hasPendingReview)
    let exhausted = try await MemorySleepStore(store: reader.store).run { _ in "malformed JSON" }
    #expect(!exhausted.hasPendingReview)
    _ = try await store.run { _ in
        Issue.record("An unchanged rejected input exceeded its single retry.")
        return #"{"groups":[]}"#
    }
    reader.updateMemory(id: a.id, text: "数据集的版本一致吗？")
    await reader.save()
    let revised = try await store.run { _ in #"{"groups":[{"kind":"refine","members":[],"summary":"缺少来源"}]}"# }
    #expect(revised.hasPendingReview)
    let noChange = try await store.run { _ in #"{"groups":[]}"# }
    #expect(!noChange.hasPendingReview)
    reader.state.memories.append(try sleepSource("重新训练的方差大吗？"))
    await reader.save()
    await #expect(throws: (any Error).self) {
        try await store.run { _ in
            await MainActor.run { reader.deleteMemory(b.id) }
            await reader.save()
            return #"{"groups":[]}"#
        }
    }
}

@Test @MainActor func subsequentSleepCanSupersedeAndDissolveAMaintainedMemory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let old = try sleepSource("原计划比较的十组训练预算有何差别？")
    var newest = try sleepSource("计划改为比较两组训练预算，两组有何差别？")
    newest.createdAt = old.createdAt.addingTimeInterval(60)
    reader.state.memories = [old, newest]
    await reader.save()
    let store = MemorySleepStore(store: reader.store)
    let newID = newest.id
    let superseded = try await store.run { _ in
        #"{"groups":[{"kind":"superseded","members":["\#(old.id)","\#(newID)"],"current":"\#(newID)","summary":"采用新的两组方案。"}]}"#
    }
    await reader.memorySleep.restore()
    let selected = try await reader.effectiveSleepMemory(question: "训练预算", paperID: nil, recalled: [old])
    #expect(selected.text.contains(newest.text))
    #expect(!selected.text.contains(old.text))
    var receipt = ChatSourceVersions()
    receipt.include(old)
    #expect(!reader.canReplayResearchMemory(receipt))
    receipt.sleepRevision = superseded.revision
    #expect(reader.canReplayResearchMemory(receipt))
    reader.state.memories.append(try sleepSource("两个研究是否使用不同的数据集？"))
    await reader.save()
    let dissolved = try await store.run { input in
        #expect(input.json.contains("采用新的两组方案"))
        return #"{"groups":[],"retire":[["\#(old.id)","\#(newID)"]]}"#
    }
    #expect(dissolved.connections.isEmpty)
    #expect(dissolved.revision != superseded.revision)
    await reader.memorySleep.restore()
    #expect(!reader.canReplayResearchMemory(receipt))
    let restored = try await reader.effectiveSleepMemory(question: "训练预算", paperID: nil, recalled: [old, newest])
    #expect(restored.originals.map(\.id) == [old.id, newID])
    _ = try await store.run { _ in
        Issue.record("An unchanged library was sent to the model a second time.")
        return #"{"groups":[]}"#
    }
}

@Test @MainActor func sleepCannotSupersedeOrRefineAReaderCorrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    var edited = try sleepSource("哪一组预算改变了？")
    _ = edited.correct(to: "优先核对实际耗时。")
    let next = try sleepSource("下次要看误差还是预算？")
    let id = edited.id
    reader.state.memories = [edited, next]
    await reader.save()
    let stored = try await MemorySleepStore(store: reader.store).run { _ in
        #"{"groups":[{"kind":"superseded","members":["\#(id)","\#(next.id)"],"current":"\#(next.id)","summary":"取消人工更正"},{"kind":"refine","members":["\#(id)"],"summary":"覆盖耗时"}]}"#
    }
    #expect(stored.connections.isEmpty)
    #expect(try await reader.store.load().memories.first?.text == edited.text)
}

/// Opt-in, synthetic material only. Drive the same sleep timer and model path used by the app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_SLEEP_LIVE"] == "1"))
@MainActor func liveModelMaintainsMemoryDuringIdle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var config = ModelSettings()
    config.baseURL = "https://api.deepseek.com"
    config.model = "deepseek-flash"
    let key = try #require(ProcessInfo.processInfo.environment["PAGEWISE_TEST_SLEEP_KEY"])
    // The fixture never enters a device keychain.
    let credentials = WorkflowCredentials()
    let isolated = try ReaderModel(root: root, credentials: credentials)
    await isolated.load()
    _ = try isolated.saveSettings(config, key: key)
    let a = try sleepSource("控制计算预算后，蒸馏方法的优势还在吗？")
    let b = try sleepSource("匹配训练算力以后，自蒸馏是否仍能提高准确率？")
    isolated.state.memories = [a, b]
    await isolated.save()
    isolated.lastInteraction = Date().addingTimeInterval(-180)
    isolated.tick()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(160))
    while isolated.memorySleep.running && clock.now < deadline { try await Task.sleep(for: .milliseconds(250)) }
    let active = try await isolated.effectiveSleepMemory(question: "训练预算", paperID: nil, recalled: [a, b])
    #expect(isolated.memorySleep.edition.connections.contains { $0.summary?.isEmpty == false })
    #expect(!active.text.contains(a.text))
    print("LIVE_SLEEP", isolated.memorySleep.edition.connections.count, active.text)
    if let output = ProcessInfo.processInfo.environment["PAGEWISE_SYNTHETIC_SLEEP_LIBRARY"] {
        // Optional isolated GUI acceptance fixture. Copy only the synthetic SQLite library.
        try await isolated.store.compact()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("library.sqlite"),
            to: directory.appendingPathComponent("library.sqlite"))
    }
}

@Test @MainActor func effectiveMemoryRespectsShelfAndPaperScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    let paperA = Paper(
        title: "Scope A", digest: "scope-a", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    let paperB = Paper(
        title: "Scope B", digest: "scope-b", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: false)
    let shelfA = try Shelf(name: "Shelf A")
    let shelfB = try Shelf(name: "Shelf B")
    let noteA = ReadingNote(
        paperID: paperA.id, contentVersion: "v", anchors: [], markdown: "Scope observation alpha.")
    let noteB = ReadingNote(
        paperID: paperB.id, contentVersion: "v", anchors: [], markdown: "Scope observation beta.")
    let itemA = try ResearchQuestionProposal(
        question: "Does scope alpha matter?", quote: "Scope observation alpha.",
        registeredExcerpt: "Scope observation alpha.", note: noteA
    ).item
    let itemB = try ResearchQuestionProposal(
        question: "Does scope beta matter?", quote: "Scope observation beta.",
        registeredExcerpt: "Scope observation beta.", note: noteB
    ).item
    reader.state.papers = [paperA, paperB]
    reader.state.shelves = [shelfA, shelfB]
    reader.state.paperShelfIDs[paperA.id.uuidString] = shelfA.id
    reader.state.paperShelfIDs[paperB.id.uuidString] = shelfB.id
    reader.state.readingNotes = [noteA, noteB]
    reader.state.memories = [itemA, itemB]

    let paperScoped = try await reader.effectiveSleepMemory(
        question: "scope", paperID: nil, recalled: [itemA, itemB], scope: .paper(paperA.id))
    #expect(paperScoped.originals.map(\.id) == [itemA.id])
    let shelfScoped = try await reader.effectiveSleepMemory(
        question: "scope", paperID: nil, recalled: [itemA, itemB], scope: .shelf(shelfA.id))
    #expect(shelfScoped.originals.map(\.id) == [itemA.id])
    let libraryScoped = try await reader.effectiveSleepMemory(
        question: "scope", paperID: nil, recalled: [itemA, itemB], scope: .library)
    #expect(Set(libraryScoped.originals.map(\.id)) == [itemA.id, itemB.id])
}
