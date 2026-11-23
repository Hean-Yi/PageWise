import Foundation
import PaperReaderKit
import Testing

@Test func noteMemoryRanksObservationsAndReturnsTheMatchingChunkFromLongMarkdown() async throws {
    let index = ReadingNoteMemoryIndex()
    let paper = UUID()
    let other = UUID()
    let anchor = NoteAnchor(key: "original-0", target: "pdf", text: "Only in the paper: zebrafish", start: 0, end: 30)
    let note = ReadingNote(
        paperID: paper, contentVersion: "v", anchors: [anchor],
        markdown: String(repeating: "本轮实验按年龄分组。", count: 135) + "\nThe latency penalty comes from disk reads.")
    var titleHit = ReadingNote(paperID: other, contentVersion: "v", anchors: [anchor], markdown: "只比较两次运行的结果。")
    titleHit.modifiedAt = note.modifiedAt.addingTimeInterval(10)
    let titles = [paper: "Systems", other: "Latency"]
    func search(_ query: String, excluding: UUID? = nil) async throws -> [Evidence] {
        try await index.search(query: query, notes: [note, titleHit], paperTitles: titles, excluding: excluding)
    }
    let result = try await search("latency")
    #expect(result.map(\.readingNoteID) == [note.id, titleHit.id])
    #expect(result[0].text.contains("disk reads") && result[0].text.count <= 900)
    #expect(try await search("zebrafish").isEmpty)
    #expect(try await search("latency", excluding: other).map(\.readingNoteID) == [note.id])
    #expect(try await search("").map(\.readingNoteID) == [titleHit.id, note.id])
    #expect(
        try await index.search(query: "", notes: [note, titleHit], paperTitles: [other: "Renamed"]).map(\.readingNoteID)
            == [titleHit.id])
    #expect(try await index.search(query: "latency", notes: [note, titleHit], paperTitles: [other: "Renamed"]).isEmpty)
}

@Test func noteMemoryStripsQuotedLinkLabelsAcrossEditsAndDeletesAndTokenizesMixedScripts() async throws {
    let index = ReadingNoteMemoryIndex()
    let paper = UUID()
    let other = UUID()
    var original = ReadingNote(paperID: other, contentVersion: "v", anchors: [], markdown: "用空白对照排查混杂。")
    let destination = LocalPassageCitation(note: original, digest: "d", quote: original.markdown)
    let link = destination.markdown(label: #"用空白对照排查混杂 [旧笔记] 和 \ 转义。"#)
    let standalone = ReadingNote(paperID: paper, contentVersion: "v", anchors: [], markdown: link)
    let inline = ReadingNote(paperID: paper, contentVersion: "v", anchors: [], markdown: "复核测量仪器。" + link + "保留温控记录。")
    let titles = [paper: "Field log", other: "Protocol"]
    let query = "我在其他论文的笔记里是如何排查混杂的？ Understanding Attention"
    #expect(Retriever.tokens(query).isSuperset(of: ["排查", "混杂", "understanding", "attention"]))
    #expect(ReadingNoteMemoryIndex.searchableBody(standalone.markdown).isEmpty)
    #expect(ReadingNoteMemoryIndex.searchableBody(inline.markdown) == "复核测量仪器。 保留温控记录。")
    func search(_ query: String, _ current: ReadingNote) async throws -> [Evidence] {
        try await index.search(query: query, notes: [standalone, inline, current], paperTitles: titles)
    }
    #expect(try await search(query, original).map(\.readingNoteID) == [original.id])
    original.markdown = "修订为双盲评估。"
    #expect(try await search(query, original).isEmpty)
    #expect(try await search("双盲", original).map(\.readingNoteID) == [original.id])
    original.deletedAt = Date()
    #expect(try await search("双盲", original).isEmpty)
    #expect(try await search("温控", original).map(\.readingNoteID) == [inline.id])
    #expect(try await search("", original).map(\.readingNoteID) == [inline.id])
}
