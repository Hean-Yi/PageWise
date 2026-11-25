import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@MainActor @Test func successiveMemoryDecisionsSurviveOverlappingTopicsAndExplicitRetirement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReaderModel(root: root)
    await reader.load()
    func plan(_ text: String, at seconds: Double) throws -> MemoryItem {
        var record = try ResearchQuestionProposal(
            question: text, readerTurnID: UUID(), readerMessage: text, quote: text
        ).item
        record.createdAt = Date(timeIntervalSinceReferenceDate: seconds)
        return record
    }
    let a = try plan("最初计划比较十个数据集？", at: 0)
    let b = try plan("调整计划只比较四个数据集？", at: 1)
    let topic = try plan("比较数据集时需要控制计算预算？", at: 2)
    let c = try plan("最终计划比较两个数据集？", at: 3)
    let store = MemorySleepStore(store: reader.store)
    reader.state.memories = [a, b]
    await reader.save()
    _ = try await store.run { _ in
        #"{"groups":[{"kind":"superseded","members":["\#(a.id)","\#(b.id)"],"current":"\#(b.id)","summary":"调整了数据集规模。"}]}"#
    }
    reader.state.memories.append(topic)
    await reader.save()
    let related = try await store.run { _ in
        #"{"groups":[{"kind":"related","members":["\#(b.id)","\#(topic.id)"],"summary":"四个数据集的预算控制。"}]}"#
    }
    #expect(related.connections.count == 2)
    await reader.memorySleep.restore()
    let middle = try await reader.effectiveSleepMemory(question: "计划", paperID: nil, recalled: [a])
    #expect(middle.entries.map(\.text) == [b.text])
    reader.state.memories.append(c)
    await reader.save()
    _ = try await store.run { _ in
        #"{"groups":[{"kind":"superseded","members":["\#(b.id)","\#(c.id)"],"current":"\#(c.id)","summary":"最终缩小比较规模。"}]}"#
    }
    let reopened = try ReaderModel(root: root)
    await reopened.load()
    let terminal = try await reopened.effectiveSleepMemory(question: "计划", paperID: nil, recalled: [a, b])
    #expect(terminal.entries.map(\.text) == [c.text])
    #expect(terminal.originals.isEmpty)
    #expect(Set(terminal.sources.map(\.id)) == [a.id, b.id, topic.id, c.id])

    reader.state.memories.append(try plan("另外一项预算调整需要确认？", at: 4))
    await reader.save()
    _ = try await store.run { _ in
        #"{"groups":[],"retire":[["\#(a.id)","\#(b.id)"]]}"#
    }
    await reader.memorySleep.restore()
    let retired = try await reader.effectiveSleepMemory(question: "未命中", paperID: nil, recalled: [a])
    #expect(retired.originals.map(\.id) == [a.id])
}

@Test func sleepRequestRejectsChangesToItsTransitiveInputs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    var state = try await store.load()
    let originals = try (1...12).map { index in
        let text = "需要核对第\(index)组样本的预算假设？"
        var item = try ResearchQuestionProposal(question: text, readerTurnID: UUID(), readerMessage: text, quote: text)
            .item
        item.createdAt = Date(timeIntervalSinceReferenceDate: Double(index))
        return item
    }
    state.memories = originals
    try await store.save(state)
    let sleep = MemorySleepStore(store: store)
    let recent = Array(originals.suffix(2))
    _ = try await sleep.run { _ in
        #"{"groups":[{"kind":"related","members":["\#(recent[0].id)","\#(recent[1].id)"],"summary":"按样本核对预算。"}]}"#
    }
    let next = "需要核对另一组样本的预算假设？"
    state.memories.append(
        try ResearchQuestionProposal(question: next, readerTurnID: UUID(), readerMessage: next, quote: next).item)
    try await store.save(state)
    let snapshot = state
    _ = try await sleep.run { input in
        #expect(input.json.contains("按样本核对预算"))
        #expect(input.isCurrent(in: snapshot))
        // Only eight previous anchors enter the new request. The earlier batch also saw
        // these older records, so its visible summary carries their dependencies.
        let absent = try #require(originals.first { !input.json.contains($0.id.uuidString) })
        let position = try #require(snapshot.memories.firstIndex { $0.id == absent.id })
        var corrected = snapshot
        corrected.memories[position].correct(to: "这项样本预算有误。")
        #expect(!input.isCurrent(in: corrected))
        var withdrawn = snapshot
        withdrawn.memories[position].forget()
        #expect(!input.isCurrent(in: withdrawn))
        return #"{"groups":[]}"#
    }
}
